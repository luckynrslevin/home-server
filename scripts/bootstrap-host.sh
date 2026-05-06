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
#   2. Creates user `ds` with passwordless sudo.
#   3. Installs your SSH public key for `ds` BEFORE password auth is
#      disabled — without this you would be locked out.
#   4. Hardens sshd via /etc/ssh/sshd_config.d/ drop-in:
#        - port 2343
#        - disables root login
#        - disables password authentication
#   5. Opens port 2343 in firewalld and labels it ssh_port_t in SELinux.
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
echo "   pubkey:         ${SSH_PUBKEY:0:50}…"
echo "=================================================================="

# ---- 1. System update + prerequisites --------------------------------------
echo
echo "[1/7] Updating system and installing prerequisites…"
dnf -y update
dnf -y install \
    sudo openssh-server \
    python3 python3-pip \
    policycoreutils-python-utils \
    firewalld \
    podman

systemctl enable --now firewalld

# ---- 2. Create user --------------------------------------------------------
echo
echo "[2/7] Creating user $NEW_USER…"
if id "$NEW_USER" >/dev/null 2>&1; then
    echo "  user $NEW_USER already exists — skipping"
else
    useradd -m -s /bin/bash "$NEW_USER"
fi

# ---- 3. Sudo rights --------------------------------------------------------
echo
echo "[3/7] Granting passwordless sudo to $NEW_USER…"
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

# ---- 4. SSH public key -----------------------------------------------------
echo
echo "[4/7] Installing SSH public key for $NEW_USER…"
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

# ---- 5. Firewalld ----------------------------------------------------------
echo
echo "[5/7] Opening firewall port $NEW_SSH_PORT/tcp (port 22 is left open"
echo "      until you confirm the new port works — see banner at the end)…"
firewall-cmd --permanent --add-port="$NEW_SSH_PORT/tcp" >/dev/null
firewall-cmd --reload >/dev/null

# ---- 6. SELinux ssh_port_t label ------------------------------------------
echo
echo "[6/7] Labeling port $NEW_SSH_PORT as ssh_port_t in SELinux…"
if semanage port -l | grep -qE "ssh_port_t\s+tcp\s+.*\b$NEW_SSH_PORT\b"; then
    echo "  port $NEW_SSH_PORT already labeled ssh_port_t — skipping"
else
    semanage port -a -t ssh_port_t -p tcp "$NEW_SSH_PORT"
fi

# ---- 7. sshd hardening drop-in --------------------------------------------
echo
echo "[7/7] Writing sshd hardening drop-in and restarting sshd…"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-bootstrap.conf"
cat > "$SSHD_DROPIN" <<EOF
# Bootstrap-installed sshd hardening (see scripts/bootstrap-host.sh).
Port $NEW_SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
chmod 0600 "$SSHD_DROPIN"

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
