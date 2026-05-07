#!/bin/bash
# ============================================================================
# Bootstrap a fresh AlmaLinux 9 (or RHEL/Rocky 9) host as an Ansible target.
#
# Run as root on a fresh install. Idempotent — safe to re-run.
#
# Usage:
#   bash scripts/bootstrap-host.sh -k <ssh-pubkey> [-u <user>] [-p <port>] [-n <hostname>]
#
# Required:
#   -k <pubkey>      SSH public key (string) to install for the new user
#
# Optional:
#   -u <user>        Linux username to create (default: ds)
#   -p <port>        SSH port to harden onto         (default: 2222)
#   -n <hostname>    Hostname to set                 (default: leave unchanged)
#   -h               Show this help and exit
#
# Examples:
#   bash scripts/bootstrap-host.sh -k "$(cat ~/.ssh/id_ed25519.pub)"
#   bash scripts/bootstrap-host.sh -k "$(cat key.pub)" -u admin -p 2222 -n dnsvserver
#
# What it does:
#   1. Enables EPEL, updates the system, installs prerequisites
#      (Python for Ansible, Podman, firewalld, SELinux tooling, bpytop).
#   2. Sets the hostname (if a second argument was passed).
#   3. Sets the console keymap to German (configurable via NEW_KEYMAP).
#   4. Creates user `ds` with passwordless sudo.
#   5. Installs your SSH public key for `ds` BEFORE password auth is
#      disabled — without this you would be locked out.
#   6. Hardens sshd via /etc/ssh/sshd_config.d/ drop-in:
#        - port 2222
#        - disables root login
#        - disables password authentication
#   7. Opens port 2222 in firewalld and labels it ssh_port_t in SELinux.
#
# SELinux notes:
#   - AlmaLinux/RHEL 9 ships with SELinux Enforcing by default. The
#     script keeps it that way — no setenforce/setpermissive — and
#     prints a warning if the running mode is not Enforcing.
#   - The new SSH port (2222) gets `semanage port -a -t ssh_port_t -p tcp`
#     so sshd is allowed to bind it.
#   - `restorecon` is run on the files we write (authorized_keys and
#     the sshd drop-in) to ensure the labels match the policy
#     defaults (ssh_home_t / sshd_config_t). Cheap insurance against
#     "key auth silently fails" debugging on RHEL family.
#
# What it deliberately does NOT do:
#   - Close port 22 in the firewall. Test the new port first from a
#     SECOND terminal:
#       ssh -p 2222 ds@<this-host>
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

# ---- Defaults --------------------------------------------------------------
NEW_USER="ds"
NEW_SSH_PORT=2222
NEW_KEYMAP="de"   # console (TTY) keymap — see `localectl list-keymaps`
SSH_PUBKEY=""
NEW_HOSTNAME=""

usage() {
    cat <<'EOF'
Usage: bootstrap-host.sh -k <ssh-pubkey> [-u <user>] [-p <port>] [-n <hostname>]

Required:
  -k <pubkey>      SSH public key (string) to install for the new user

Optional:
  -u <user>        Linux username to create  (default: ds)
  -p <port>        SSH port to harden onto   (default: 2222)
  -n <hostname>    Hostname to set           (default: leave unchanged)
  -h               Show this help and exit

Examples:
  bash bootstrap-host.sh -k "$(cat ~/.ssh/id_ed25519.pub)"
  bash bootstrap-host.sh -k "$(cat key.pub)" -u admin -p 2222 -n dnsvserver
EOF
}

# ---- Args ------------------------------------------------------------------
while getopts ":k:u:p:n:h" opt; do
    case "$opt" in
        k) SSH_PUBKEY="$OPTARG" ;;
        u) NEW_USER="$OPTARG" ;;
        p) NEW_SSH_PORT="$OPTARG" ;;
        n) NEW_HOSTNAME="$OPTARG" ;;
        h) usage; exit 0 ;;
        \?) echo "Error: invalid option -$OPTARG" >&2; usage >&2; exit 1 ;;
        :)  echo "Error: option -$OPTARG requires an argument" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
if [[ $# -gt 0 ]]; then
    echo "Error: unexpected positional arguments: $*" >&2
    usage >&2
    exit 1
fi

# Required: pubkey
if [[ -z "$SSH_PUBKEY" ]]; then
    echo "Error: -k <ssh-pubkey> is required." >&2
    echo
    usage >&2
    exit 1
fi

# Validate username (POSIX/RHEL-friendly subset)
if ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Error: invalid username '$NEW_USER'." >&2
    echo "       Must start with a lowercase letter or underscore," >&2
    echo "       contain only [a-z0-9_-], and be 1-32 characters." >&2
    exit 1
fi

# Validate SSH port (integer 1-65535)
if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] \
    || [[ "$NEW_SSH_PORT" -lt 1 || "$NEW_SSH_PORT" -gt 65535 ]]; then
    echo "Error: invalid SSH port '$NEW_SSH_PORT' (must be 1-65535)." >&2
    exit 1
fi

# Validate hostname (RFC 1123) if one was provided
if [[ -n "$NEW_HOSTNAME" ]] \
    && ! [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    echo "Error: hostname '$NEW_HOSTNAME' contains characters not allowed (RFC 1123)." >&2
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
echo "   hostname:       ${NEW_HOSTNAME:-<unchanged>}"
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
echo "[1/9] Enabling EPEL, updating, installing prerequisites…"
# EPEL provides bpytop (and a few other niceties); harmless to enable
# even if bpytop is the only package we draw from it.
dnf -y install epel-release
dnf -y update
dnf -y install \
    sudo openssh-server \
    python3 python3-pip \
    policycoreutils-python-utils \
    firewalld \
    podman \
    bpytop

systemctl enable --now firewalld

# ---- 2. Hostname -----------------------------------------------------------
echo
echo "[2/9] Setting hostname…"
if [[ -z "$NEW_HOSTNAME" ]]; then
    echo "  (no hostname argument given — keeping current: $(hostname))"
elif [[ "$(hostnamectl --static 2>/dev/null)" == "$NEW_HOSTNAME" ]]; then
    echo "  hostname already $NEW_HOSTNAME — skipping"
else
    hostnamectl set-hostname "$NEW_HOSTNAME"
    echo "  hostname set to $NEW_HOSTNAME"
fi

# ---- 3. Console keymap -----------------------------------------------------
echo
echo "[3/9] Setting console keymap to $NEW_KEYMAP…"
if localectl status 2>/dev/null | grep -q "^ *VC Keymap: $NEW_KEYMAP$"; then
    echo "  already set to $NEW_KEYMAP — skipping"
else
    localectl set-keymap "$NEW_KEYMAP"
fi

# ---- 4. Create user --------------------------------------------------------
echo
echo "[4/9] Creating user $NEW_USER…"
if id "$NEW_USER" >/dev/null 2>&1; then
    echo "  user $NEW_USER already exists — skipping"
else
    useradd -m -s /bin/bash "$NEW_USER"
fi

# ---- 5. Sudo rights --------------------------------------------------------
echo
echo "[5/9] Granting passwordless sudo to $NEW_USER…"
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

# ---- 6. SSH public key -----------------------------------------------------
echo
echo "[6/9] Installing SSH public key for $NEW_USER…"
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

# ---- 7. Firewalld ----------------------------------------------------------
echo
echo "[7/9] Opening firewall port $NEW_SSH_PORT/tcp (port 22 is left open"
echo "      until you confirm the new port works — see banner at the end)…"
firewall-cmd --permanent --add-port="$NEW_SSH_PORT/tcp" >/dev/null
firewall-cmd --reload >/dev/null

# ---- 8. SELinux ssh_port_t label ------------------------------------------
echo
echo "[8/9] Labeling port $NEW_SSH_PORT as ssh_port_t in SELinux…"
if semanage port -l | grep -qE "ssh_port_t\s+tcp\s+.*\b$NEW_SSH_PORT\b"; then
    echo "  port $NEW_SSH_PORT already labeled ssh_port_t — skipping"
else
    semanage port -a -t ssh_port_t -p tcp "$NEW_SSH_PORT"
fi

# ---- 9. sshd hardening drop-in --------------------------------------------
echo
echo "[9/9] Writing sshd hardening drop-in and restarting sshd…"
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
