#!/bin/bash
# ============================================================================
# Bootstrap a fresh AlmaLinux 9 (or RHEL/Rocky 9) host as an Ansible target.
#
# Run as root on a fresh install. Idempotent — safe to re-run.
#
# Usage:
#   bash scripts/bootstrap-host.sh "$(cat ~/.ssh/id_ed25519.pub)"
#
# Or pass the key directly:
#   bash scripts/bootstrap-host.sh "ssh-ed25519 AAAA... user@laptop"
#
# What it does:
#   1. Updates the system and installs prerequisites (Python for Ansible,
#      Podman, firewalld, SELinux tooling).
#   2. Sets the console keymap to German (configurable via NEW_KEYMAP).
#   3. Creates user `ds` with passwordless sudo.
#   4. Installs your SSH public key for `ds` BEFORE password auth is
#      disabled — without this you would be locked out.
#   5. Hardens sshd via /etc/ssh/sshd_config.d/ drop-in:
#        - port 2343
#        - disables root login
#        - disables password authentication
#   6. Opens port 2343 in firewalld and labels it ssh_port_t in SELinux.
#
# SELinux notes:
#   - AlmaLinux/RHEL 9 ships with SELinux Enforcing by default. The
#     script keeps it that way — no setenforce/setpermissive — and
#     prints a warning if the running mode is not Enforcing.
#   - The new SSH port (2343) gets `semanage port -a -t ssh_port_t -p tcp`
#     so sshd is allowed to bind it.
#   - `restorecon` is run on the files we write (authorized_keys and
#     the sshd drop-in) to ensure the labels match the policy
#     defaults (ssh_home_t / sshd_config_t). Cheap insurance against
#     "key auth silently fails" debugging on RHEL family.
#
# What it deliberately does NOT do:
#   - Close port 22 in the firewall. Test the new port first from a
#     SECOND terminal:
#       ssh -p 2343 ds@<this-host>
#     If that works, lock down by removing the old port:
#       sudo firewall-cmd --permanent --remove-service=ssh
#       sudo firewall-cmd --reload
#   - Install Ansible. The control machine runs Ansible; managed
#     hosts only need Python (already covered above).
#
# This is the symmetric counterpart to setup.sh:
#   - setup.sh   = control machine (runs Ansible against the inventory)
#   - this script = a managed host (Ansible target)
# ============================================================================

set -euo pipefail

# ---- Config ----------------------------------------------------------------
NEW_USER="ds"
NEW_SSH_PORT=2343
NEW_KEYMAP="de"   # console (TTY) keymap — see `localectl list-keymaps`

# ---- Args ------------------------------------------------------------------
SSH_PUBKEY="${1:-}"

if [[ -z "$SSH_PUBKEY" ]]; then
    cat <<'EOF' >&2
Error: SSH public key required.

Usage:
  bash scripts/bootstrap-host.sh "<ssh-public-key-string>"

Example:
  bash scripts/bootstrap-host.sh "$(cat ~/.ssh/id_ed25519.pub)"

The key is installed for the new user BEFORE password auth is disabled.
Without this, you would be locked out as soon as sshd is restarted.
EOF
    exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "Error: run as root (use sudo)." >&2
    exit 1
fi

# Sanity-check that the pubkey looks vaguely like one
if ! [[ "$SSH_PUBKEY" =~ ^(ssh-(rsa|ed25519|ecdsa-sha2-nistp[0-9]+)|sk-(ssh-ed25519|ecdsa-sha2-nistp[0-9]+))@?[a-z0-9-]*\ [A-Za-z0-9+/=]+ ]]; then
    echo "Error: SSH_PUBKEY argument does not look like a valid public key." >&2
    echo "Got: ${SSH_PUBKEY:0:60}..." >&2
    exit 1
fi

echo "=================================================================="
echo " Home-server host bootstrap"
echo "   user:           $NEW_USER  (passwordless sudo)"
echo "   ssh port:       $NEW_SSH_PORT"
echo "   keymap:         $NEW_KEYMAP"
echo "   pubkey:         ${SSH_PUBKEY:0:50}…"
echo "=================================================================="

# Sanity-check SELinux mode. We don't fix this — disabling SELinux is
# a deliberate choice and we don't want to silently change it — but a
# host running in Permissive (or Disabled) loses a lot of the security
# the rest of this script assumes.
if command -v getenforce >/dev/null 2>&1; then
    selinux_mode=$(getenforce 2>/dev/null || true)
    if [[ "$selinux_mode" != "Enforcing" ]]; then
        echo
        echo "  WARNING: SELinux is '$selinux_mode' (expected Enforcing)."
        echo "           This script will still work, but the system is"
        echo "           less protected. Re-enable with:"
        echo "             setenforce 1"
        echo "             sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config"
        echo
    fi
fi

# ---- 1. System update + prerequisites --------------------------------------
echo
echo "[1/8] Updating system and installing prerequisites…"
dnf -y update
dnf -y install \
    sudo openssh-server \
    python3 python3-pip \
    policycoreutils-python-utils \
    firewalld \
    podman

systemctl enable --now firewalld

# ---- 2. Console keymap -----------------------------------------------------
echo
echo "[2/8] Setting console keymap to $NEW_KEYMAP…"
if localectl status 2>/dev/null | grep -q "^ *VC Keymap: $NEW_KEYMAP$"; then
    echo "  already set to $NEW_KEYMAP — skipping"
else
    localectl set-keymap "$NEW_KEYMAP"
fi

# ---- 3. Create user --------------------------------------------------------
echo
echo "[3/8] Creating user $NEW_USER…"
if id "$NEW_USER" >/dev/null 2>&1; then
    echo "  user $NEW_USER already exists — skipping"
else
    useradd -m -s /bin/bash "$NEW_USER"
fi

# ---- 4. Sudo rights --------------------------------------------------------
echo
echo "[4/8] Granting passwordless sudo to $NEW_USER…"
SUDOERS_FILE="/etc/sudoers.d/90-$NEW_USER"
cat > "$SUDOERS_FILE" <<EOF
# Bootstrap-installed: $NEW_USER may run any command without a password.
# This is intentional for an Ansible-managed host. Replace NOPASSWD:ALL
# with a more restrictive policy if the host is used interactively.
$NEW_USER ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 "$SUDOERS_FILE"
# visudo -cf bails out non-zero on syntax errors
visudo -cf "$SUDOERS_FILE" >/dev/null

# ---- 5. SSH public key -----------------------------------------------------
echo
echo "[5/8] Installing SSH public key for $NEW_USER…"
USER_HOME="/home/$NEW_USER"
USER_SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$USER_SSH_DIR/authorized_keys"

install -d -m 0700 -o "$NEW_USER" -g "$NEW_USER" "$USER_SSH_DIR"
touch "$AUTH_KEYS"
if ! grep -qxF "$SSH_PUBKEY" "$AUTH_KEYS"; then
    echo "$SSH_PUBKEY" >> "$AUTH_KEYS"
    echo "  key appended to $AUTH_KEYS"
else
    echo "  key already present — skipping"
fi
chmod 0600 "$AUTH_KEYS"
chown "$NEW_USER:$NEW_USER" "$AUTH_KEYS"

# Reset SELinux labels on the .ssh tree to whatever the policy says
# they should be (ssh_home_t for the dir + authorized_keys). Files
# created via shell redirection inherit the parent's context, which
# is usually correct here, but `restorecon` makes failure deterministic
# instead of "sometimes works, sometimes mysterious AVC denial".
if command -v restorecon >/dev/null 2>&1; then
    restorecon -R "$USER_SSH_DIR"
fi

# ---- 6. Firewalld ----------------------------------------------------------
echo
echo "[6/8] Opening firewall port $NEW_SSH_PORT/tcp (port 22 is left open"
echo "      until you confirm the new port works — see banner at the end)…"
firewall-cmd --permanent --add-port="$NEW_SSH_PORT/tcp" >/dev/null
firewall-cmd --reload >/dev/null

# ---- 7. SELinux ssh_port_t label ------------------------------------------
echo
echo "[7/8] Labeling port $NEW_SSH_PORT as ssh_port_t in SELinux…"
if semanage port -l | grep -qE "ssh_port_t\s+tcp\s+.*\b$NEW_SSH_PORT\b"; then
    echo "  port $NEW_SSH_PORT already labeled ssh_port_t — skipping"
else
    semanage port -a -t ssh_port_t -p tcp "$NEW_SSH_PORT"
fi

# ---- 8. sshd hardening drop-in --------------------------------------------
echo
echo "[8/8] Writing sshd hardening drop-in and restarting sshd…"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-bootstrap.conf"
cat > "$SSHD_DROPIN" <<EOF
# Bootstrap-installed sshd hardening (see scripts/bootstrap-host.sh).
Port $NEW_SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
chmod 0600 "$SSHD_DROPIN"

# Same insurance as for authorized_keys — if the policy expects
# sshd_config_t in /etc/ssh/sshd_config.d/ (it does on RHEL 9),
# restorecon makes the label deterministic so sshd can read it.
if command -v restorecon >/dev/null 2>&1; then
    restorecon "$SSHD_DROPIN"
fi

# Validate config before restart
sshd -t

systemctl restart sshd

# ---- Done ------------------------------------------------------------------
HOST_IP=$(hostname -I | awk '{print $1}')
cat <<EOF

==================================================================
 Done.
==================================================================

Verify in a SECOND terminal BEFORE closing this session:

    ssh -p $NEW_SSH_PORT $NEW_USER@$HOST_IP

If that works, lock down by removing port 22 from the firewall:

    firewall-cmd --permanent --remove-service=ssh
    firewall-cmd --reload

If you get locked out (e.g. firewall mistake), this current root
session stays open; you can fix sshd_config from here.

EOF
