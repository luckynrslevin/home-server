#!/bin/bash
# ============================================================================
# Open a path for Ansible to reach a fresh RHEL-family host.
#
# Supported targets: RHEL 8/9, AlmaLinux 8/9, Rocky 8/9, CentOS Stream 8/9,
# Oracle Linux 8/9, and Fedora (upstream of the family). The script
# checks `/etc/os-release` on the target and bails out on anything
# else (Debian/Ubuntu/Arch/etc).
#
# Run this from the Ansible control machine. The script SSHs to the target
# as root on port 22, hardens sshd, creates an `ansible` user with sudo,
# installs your SSH key, then verifies the new connection. Everything else
# (packages, hostname, services) is the Ansible playbook's job from there.
#
# Prerequisites on the target:
#   - Fresh OS install with sshd listening on port 22
#   - Root login enabled (password or key — the script handles both)
#   - python3 in /usr/bin (default on AlmaLinux 9; the script installs it
#     if missing)
#
# Prerequisites on this machine:
#   - bash, ssh
#
# Usage:
#   bash scripts/bootstrap-host.sh -H <host> -k <ssh-pubkey> \
#        [-u <user>] [-p <port>]
#
# Examples:
#   bash bootstrap-host.sh -H 1.2.3.4 -k "$(cat ~/.ssh/id_ed25519.pub)"
#   bash bootstrap-host.sh -H new.example.com -k "$(cat key.pub)" -p 2200
#
# Flow:
#   Phase 1: ssh root@<host>:22 → run the six-step hardening payload
#            (ensure prereqs, create user+sudoers, install key, open port
#            in firewalld+SELinux, write sshd drop-in, restart sshd).
#   Phase 2: local prompt — update any EXTERNAL firewall (cloud security
#            group, edge router, ...) — open new port, close 22 — Enter.
#   Phase 3: ssh -p <new-port> <user>@<host> → verify.
#   Phase 4: optional — close port 22 in the target's local firewalld.
# ============================================================================

set -euo pipefail

# ---- Defaults --------------------------------------------------------------
TARGET_HOST=""
SSH_PUBKEY=""
NEW_USER="ansible"
NEW_SSH_PORT=2222

usage() {
    cat <<'EOF'
Usage: bootstrap-host.sh -H <host> -k <ssh-pubkey> [-u <user>] [-p <port>]

Required:
  -H <host>      Target hostname or IP
  -k <pubkey>    SSH public key (string) to install for the new user

Optional:
  -u <user>      Linux username to create  (default: ansible)
  -p <port>      SSH port to harden onto   (default: 2222)
  -h             Show this help and exit

Examples:
  bash bootstrap-host.sh -H 1.2.3.4 -k "$(cat ~/.ssh/id_ed25519.pub)"
  bash bootstrap-host.sh -H new.example.com -k "$(cat key.pub)" -p 2200
EOF
}

# ---- Args ------------------------------------------------------------------
while getopts ":H:k:u:p:h" opt; do
    case "$opt" in
        H) TARGET_HOST="$OPTARG" ;;
        k) SSH_PUBKEY="$OPTARG" ;;
        u) NEW_USER="$OPTARG" ;;
        p) NEW_SSH_PORT="$OPTARG" ;;
        h) usage; exit 0 ;;
        \?) echo "Error: invalid option -$OPTARG" >&2; usage >&2; exit 1 ;;
        :)  echo "Error: option -$OPTARG requires an argument" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
[[ $# -gt 0 ]] && {
    echo "Error: unexpected positional arguments: $*" >&2; usage >&2; exit 1
}

# ---- Validation ------------------------------------------------------------
[[ -z "$TARGET_HOST" ]] && { echo "Error: -H <host> is required." >&2; usage >&2; exit 1; }
[[ -z "$SSH_PUBKEY"  ]] && { echo "Error: -k <ssh-pubkey> is required." >&2; usage >&2; exit 1; }

if ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Error: invalid username '$NEW_USER' (must match ^[a-z_][a-z0-9_-]{0,31}\$)." >&2
    exit 1
fi
if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]] || (( NEW_SSH_PORT < 1 || NEW_SSH_PORT > 65535 )); then
    echo "Error: invalid SSH port '$NEW_SSH_PORT' (must be 1-65535)." >&2; exit 1
fi
if ! [[ "$SSH_PUBKEY" =~ ^(ssh-(rsa|ed25519|ecdsa-sha2-nistp[0-9]+)|sk-(ssh-ed25519|ecdsa-sha2-nistp[0-9]+))@?[a-z0-9-]*\ [A-Za-z0-9+/=]+ ]]; then
    echo "Error: SSH_PUBKEY does not look like a valid public key." >&2
    echo "       Got: ${SSH_PUBKEY:0:60}..." >&2
    exit 1
fi

echo "=================================================================="
echo " Open Ansible path on a fresh host"
echo "   target:         root@$TARGET_HOST:22"
echo "   new user:       $NEW_USER  (passwordless sudo)"
echo "   new ssh port:   $NEW_SSH_PORT"
echo "   pubkey:         ${SSH_PUBKEY:0:50}..."
echo "=================================================================="

# ---- Phase 1: SSH root@host:22 and run the hardening payload ---------------
SSH_OPTS=(-p 22 -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15)

echo
echo "Phase 1 — connecting to root@$TARGET_HOST:22 to run the hardening payload."
echo "(If you don't have key auth as root, you'll be prompted for the password.)"
echo

ssh "${SSH_OPTS[@]}" "root@$TARGET_HOST" bash -s <<EOF
SSH_PUBKEY=$(printf %q "$SSH_PUBKEY")
NEW_USER=$(printf %q "$NEW_USER")
NEW_SSH_PORT=$NEW_SSH_PORT
$(cat <<'PAYLOAD'
set -euo pipefail

[[ "$EUID" -eq 0 ]] || { echo "Error: must run as root on the target." >&2; exit 1; }

# ---- 0. Distro sanity check ----
# Accept anything in the RHEL-family tree (rhel/centos/fedora as ID
# or anywhere in ID_LIKE). dnf, firewalld, SELinux, semanage, and
# restorecon below all assume that family.
if [[ -r /etc/os-release ]]; then
    . /etc/os-release
else
    echo "Error: /etc/os-release missing — can't identify distro." >&2
    exit 1
fi
case " ${ID:-} ${ID_LIKE:-} " in
    *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*|*" ol "*) ;;
    *)
        echo "Error: unsupported distro." >&2
        echo "  ID=${ID:-?} ID_LIKE=${ID_LIKE:-?}" >&2
        echo "  This script supports RHEL family only" \
             "(RHEL/AlmaLinux/Rocky/CentOS Stream/Oracle Linux/Fedora)." >&2
        exit 1
        ;;
esac
echo "Detected: ${PRETTY_NAME:-$ID $VERSION_ID}"

# ---- 1. Prerequisites ----
# python3, firewalld, and SELinux's `semanage` are the bare minimum to do
# the rest of the steps below and let Ansible take over from here.
echo "[1/6] Ensuring prerequisites (python3, firewalld, semanage) are installed..."
missing=()
command -v python3       >/dev/null 2>&1 || missing+=(python3)
command -v firewall-cmd  >/dev/null 2>&1 || missing+=(firewalld)
command -v semanage      >/dev/null 2>&1 || missing+=(policycoreutils-python-utils)
if (( ${#missing[@]} )); then
    echo "  installing: ${missing[*]}"
    dnf -y install "${missing[@]}"
else
    echo "  all prerequisites present"
fi

# ---- 2. firewalld active ----
echo "[2/6] Ensuring firewalld is enabled and running..."
systemctl enable --now firewalld

# ---- 3. User + sudoers ----
echo "[3/6] Creating user $NEW_USER with passwordless sudo..."
if id "$NEW_USER" >/dev/null 2>&1; then
    echo "  user $NEW_USER already exists — skipping useradd"
else
    useradd -m -s /bin/bash "$NEW_USER"
fi
SUDOERS_FILE="/etc/sudoers.d/90-$NEW_USER"
cat > "$SUDOERS_FILE" <<SUDO
# Bootstrap-installed: $NEW_USER may run any command without a password.
$NEW_USER ALL=(ALL) NOPASSWD:ALL
SUDO
chmod 0440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null

# ---- 4. SSH public key ----
echo "[4/6] Installing SSH public key..."
USER_SSH_DIR="/home/$NEW_USER/.ssh"
AUTH_KEYS="$USER_SSH_DIR/authorized_keys"
install -d -m 0700 -o "$NEW_USER" -g "$NEW_USER" "$USER_SSH_DIR"
touch "$AUTH_KEYS"
if grep -qxF "$SSH_PUBKEY" "$AUTH_KEYS"; then
    echo "  key already present — skipping"
else
    echo "$SSH_PUBKEY" >> "$AUTH_KEYS"
    echo "  key appended to $AUTH_KEYS"
fi
chmod 0600 "$AUTH_KEYS"
chown "$NEW_USER:$NEW_USER" "$AUTH_KEYS"
command -v restorecon >/dev/null && restorecon -R "$USER_SSH_DIR"

# ---- 5. Open new SSH port (firewalld + SELinux) ----
echo "[5/6] Opening port $NEW_SSH_PORT/tcp in firewalld and labeling ssh_port_t in SELinux..."
firewall-cmd --permanent --add-port="$NEW_SSH_PORT/tcp" >/dev/null
firewall-cmd --reload >/dev/null
if semanage port -l | grep -qE "ssh_port_t\s+tcp\s+.*\b$NEW_SSH_PORT\b"; then
    echo "  port $NEW_SSH_PORT already labeled ssh_port_t — skipping"
else
    semanage port -a -t ssh_port_t -p tcp "$NEW_SSH_PORT"
fi

# ---- 6. sshd drop-in + restart ----
echo "[6/6] Writing sshd hardening drop-in and restarting sshd..."
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-bootstrap.conf"
cat > "$SSHD_DROPIN" <<SSHD
# Bootstrap-installed sshd hardening (see scripts/bootstrap-host.sh).
Port $NEW_SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
SSHD
chmod 0600 "$SSHD_DROPIN"
command -v restorecon >/dev/null && restorecon "$SSHD_DROPIN"
sshd -t
systemctl restart sshd

echo
echo "Remote hardening complete. Port 22 in local firewalld stays open as a fallback."
PAYLOAD
)
EOF

# ---- Phase 2: prompt user about external firewall --------------------------
cat <<EOF

==================================================================
 Phase 2 — external firewall
==================================================================

 sshd on $TARGET_HOST is now listening on port $NEW_SSH_PORT.
 The host's local firewalld already has the new port open.

 If the host has an EXTERNAL firewall (cloud provider security
 group, edge router, hosting-panel firewall):

     • OPEN  port $NEW_SSH_PORT/tcp
     • CLOSE port 22/tcp

 If you have no external firewall, just press Enter — port 22 in
 local firewalld stays open until phase 4.

EOF
read -r -p "Press Enter to continue with verification (Ctrl-C to abort)... " _

# ---- Phase 3: verify -------------------------------------------------------
echo
echo "Phase 3 — verifying ssh -p $NEW_SSH_PORT $NEW_USER@$TARGET_HOST..."
if ssh -p "$NEW_SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
       -o BatchMode=yes "$NEW_USER@$TARGET_HOST" \
       'echo "  OK as $(whoami) on $(hostnamectl --static 2>/dev/null || hostname)"' 2>&1; then
    :
else
    cat <<EOF

==================================================================
 ✗ Verification failed.
==================================================================

 Couldn't connect to $NEW_USER@$TARGET_HOST on port $NEW_SSH_PORT.

 Likely causes:
   - External firewall not yet open on port $NEW_SSH_PORT
   - Your private key isn't in your ssh-agent (try: ssh-add -l)
   - Routing/IP propagation delay; wait and retry

 Try manually:
     ssh -p $NEW_SSH_PORT $NEW_USER@$TARGET_HOST

 Port 22 on the target is still open as a fallback. SSH back as
 root@$TARGET_HOST:22 and remove /etc/ssh/sshd_config.d/99-bootstrap.conf
 to undo if needed.
EOF
    exit 1
fi

# ---- Phase 4: optionally close port 22 in local firewalld -----------------
echo
read -r -p "Close port 22 in the target's LOCAL firewalld now? [y/N] " close22
if [[ "$close22" =~ ^[Yy]$ ]]; then
    echo "  Closing port 22 via $NEW_USER@$TARGET_HOST:$NEW_SSH_PORT..."
    ssh -p "$NEW_SSH_PORT" "$NEW_USER@$TARGET_HOST" \
        'sudo firewall-cmd --permanent --remove-service=ssh && sudo firewall-cmd --reload' \
        | sed 's/^/  /'
    echo "  Port 22 removed from local firewalld."
else
    echo "  Skipped. Close it later with:"
    echo "    ssh -p $NEW_SSH_PORT $NEW_USER@$TARGET_HOST 'sudo firewall-cmd --permanent --remove-service=ssh && sudo firewall-cmd --reload'"
fi

cat <<EOF

==================================================================
 ✓ Done. Hand off to Ansible from here.
==================================================================

 Suggested ~/.ssh/config entry on this machine:

   Host $TARGET_HOST
     HostName $TARGET_HOST
     User $NEW_USER
     Port $NEW_SSH_PORT
     IdentityFile ~/.ssh/id_ed25519

 Sanity check:
   ansible -i <inventory> -m ping <host>

 Then deploy with ansible-playbook.
EOF
