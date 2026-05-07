#!/bin/bash
# ============================================================================
# Bootstrap a fresh AlmaLinux 9 (or RHEL/Rocky 9) host as an Ansible target.
#
# Run this script from your LAPTOP (or any Ansible-control machine).
# It SSHs to the target as root on port 22 and performs all hardening
# remotely. You never need to log into the host's console manually.
#
# Prerequisites on the target:
#   - Fresh OS install with sshd listening on port 22
#   - Root login enabled with either a password or a key you control
#
# Prerequisites on this machine:
#   - bash, ssh
#
# Usage:
#   bash scripts/bootstrap-host.sh -H <host> -k <ssh-pubkey> \
#        [-u <user>] [-p <port>] [-n <hostname>]
#
# Required:
#   -H <host>        Target hostname or IP (the new server)
#   -k <pubkey>      SSH public key to install for the new user
#
# Optional:
#   -u <user>        Linux username to create  (default: myuser)
#   -p <port>        SSH port to harden onto   (default: 2222)
#   -n <hostname>    Hostname to set on target (default: leave unchanged)
#   -h               Show this help and exit
#
# Examples:
#   bash bootstrap-host.sh -H 1.2.3.4 -k "$(cat ~/.ssh/id_ed25519.pub)"
#   bash bootstrap-host.sh -H new.example.com -k "$(cat key.pub)" \
#                          -u admin -p 2200 -n dnsvserver
#
# Flow:
#   1. ssh root@<host>:22 → run hardening payload (system update,
#      EPEL+bpytop, hostname, keymap, user+sudo, key install, firewalld
#      open new port, SELinux port label, sshd hardening drop-in,
#      restart sshd).
#   2. Local prompt: "Update any external/provider firewall now —
#      open <new-port>, close 22 — then press Enter."
#   3. ssh -p <new-port> <user>@<host> → verify the hardened
#      configuration works.
#   4. Optionally close port 22 in the target's local firewalld.
# ============================================================================

set -euo pipefail

# ---- Defaults --------------------------------------------------------------
TARGET_HOST=""
SSH_PUBKEY=""
NEW_USER="myuser"
NEW_SSH_PORT=2222
NEW_KEYMAP="de"
NEW_HOSTNAME=""

usage() {
    cat <<'EOF'
Usage: bootstrap-host.sh -H <host> -k <ssh-pubkey> [-u <user>] [-p <port>] [-n <hostname>]

Required:
  -H <host>        Target hostname or IP (the new server)
  -k <pubkey>      SSH public key (string) to install for the new user

Optional:
  -u <user>        Linux username to create  (default: myuser)
  -p <port>        SSH port to harden onto   (default: 2222)
  -n <hostname>    Hostname to set on target (default: leave unchanged)
  -h               Show this help and exit

Examples:
  bash bootstrap-host.sh -H 1.2.3.4 -k "$(cat ~/.ssh/id_ed25519.pub)"
  bash bootstrap-host.sh -H new.example.com -k "$(cat key.pub)" -u admin -p 2200 -n dnsvserver
EOF
}

# ---- Args ------------------------------------------------------------------
while getopts ":H:k:u:p:n:h" opt; do
    case "$opt" in
        H) TARGET_HOST="$OPTARG" ;;
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

# Required
if [[ -z "$TARGET_HOST" ]]; then
    echo "Error: -H <host> is required." >&2
    echo
    usage >&2
    exit 1
fi
if [[ -z "$SSH_PUBKEY" ]]; then
    echo "Error: -k <ssh-pubkey> is required." >&2
    echo
    usage >&2
    exit 1
fi

# Validate username
if ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Error: invalid username '$NEW_USER' (must match ^[a-z_][a-z0-9_-]{0,31}\$)." >&2
    exit 1
fi

# Validate SSH port
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

# Sanity-check the pubkey looks like one
if ! [[ "$SSH_PUBKEY" =~ ^(ssh-(rsa|ed25519|ecdsa-sha2-nistp[0-9]+)|sk-(ssh-ed25519|ecdsa-sha2-nistp[0-9]+))@?[a-z0-9-]*\ [A-Za-z0-9+/=]+ ]]; then
    echo "Error: SSH_PUBKEY does not look like a valid public key." >&2
    echo "       Got: ${SSH_PUBKEY:0:60}..." >&2
    exit 1
fi

echo "=================================================================="
echo " Home-server host bootstrap (remote driver)"
echo "   target:         root@$TARGET_HOST:22"
echo "   new user:       $NEW_USER  (passwordless sudo)"
echo "   new ssh port:   $NEW_SSH_PORT"
echo "   keymap:         $NEW_KEYMAP"
echo "   hostname:       ${NEW_HOSTNAME:-<unchanged>}"
echo "   pubkey:         ${SSH_PUBKEY:0:50}…"
echo "=================================================================="

# ---- Phase 1: connect to root@host:22 and run the payload ------------------
SSH_OPTS=(
    -p 22
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=15
)

echo
echo "Phase 1 — connecting to root@$TARGET_HOST:22 to run the hardening payload."
echo "(If you don't have key auth as root, you'll be prompted for the password."
echo " sshd is restarted onto port $NEW_SSH_PORT at the end of phase 1; the"
echo " existing connection on port 22 stays alive even after the restart.)"
echo

# The remote payload uses these variables, set as a preamble. We use
# printf %q to safely quote the values so any whitespace, quotes, or
# special characters in the pubkey survive intact across SSH.
ssh "${SSH_OPTS[@]}" "root@$TARGET_HOST" bash -s <<EOF
SSH_PUBKEY=$(printf %q "$SSH_PUBKEY")
NEW_USER=$(printf %q "$NEW_USER")
NEW_SSH_PORT=$NEW_SSH_PORT
NEW_HOSTNAME=$(printf %q "$NEW_HOSTNAME")
NEW_KEYMAP=$(printf %q "$NEW_KEYMAP")
$(cat <<'PAYLOAD'
set -euo pipefail

if [[ "\$EUID" -ne 0 ]]; then
    echo "Error: must run as root on the target." >&2
    exit 1
fi

# SELinux pre-flight (warn-only)
if command -v getenforce >/dev/null 2>&1; then
    selinux_mode=\$(getenforce 2>/dev/null || true)
    if [[ "\$selinux_mode" != "Enforcing" ]]; then
        echo
        echo "  WARNING: SELinux is '\$selinux_mode' (expected Enforcing)."
        echo "           Continuing anyway, but the system is less protected."
        echo
    fi
fi

# ---- 1. System update + prerequisites ----
echo
echo "[1/9] Enabling EPEL, updating, installing prerequisites…"
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

# ---- 2. Hostname ----
echo
echo "[2/9] Setting hostname…"
if [[ -z "\$NEW_HOSTNAME" ]]; then
    echo "  (no hostname argument given — keeping current: \$(hostname))"
elif [[ "\$(hostnamectl --static 2>/dev/null)" == "\$NEW_HOSTNAME" ]]; then
    echo "  hostname already \$NEW_HOSTNAME — skipping"
else
    hostnamectl set-hostname "\$NEW_HOSTNAME"
    echo "  hostname set to \$NEW_HOSTNAME"
fi

# ---- 3. Console keymap ----
echo
echo "[3/9] Setting console keymap to \$NEW_KEYMAP…"
if localectl status 2>/dev/null | grep -q "^ *VC Keymap: \$NEW_KEYMAP\$"; then
    echo "  already set to \$NEW_KEYMAP — skipping"
else
    localectl set-keymap "\$NEW_KEYMAP"
fi

# ---- 4. Create user ----
echo
echo "[4/9] Creating user \$NEW_USER…"
if id "\$NEW_USER" >/dev/null 2>&1; then
    echo "  user \$NEW_USER already exists — skipping"
else
    useradd -m -s /bin/bash "\$NEW_USER"
fi

# ---- 5. Sudo rights ----
echo
echo "[5/9] Granting passwordless sudo to \$NEW_USER…"
SUDOERS_FILE="/etc/sudoers.d/90-\$NEW_USER"
cat > "\$SUDOERS_FILE" <<SUDOEOF
# Bootstrap-installed: \$NEW_USER may run any command without a password.
\$NEW_USER ALL=(ALL) NOPASSWD:ALL
SUDOEOF
chmod 0440 "\$SUDOERS_FILE"
visudo -cf "\$SUDOERS_FILE" >/dev/null

# ---- 6. SSH public key ----
echo
echo "[6/9] Installing SSH public key for \$NEW_USER…"
USER_SSH_DIR="/home/\$NEW_USER/.ssh"
AUTH_KEYS="\$USER_SSH_DIR/authorized_keys"
install -d -m 0700 -o "\$NEW_USER" -g "\$NEW_USER" "\$USER_SSH_DIR"
touch "\$AUTH_KEYS"
if ! grep -qxF "\$SSH_PUBKEY" "\$AUTH_KEYS"; then
    echo "\$SSH_PUBKEY" >> "\$AUTH_KEYS"
    echo "  key appended to \$AUTH_KEYS"
else
    echo "  key already present — skipping"
fi
chmod 0600 "\$AUTH_KEYS"
chown "\$NEW_USER:\$NEW_USER" "\$AUTH_KEYS"
if command -v restorecon >/dev/null 2>&1; then
    restorecon -R "\$USER_SSH_DIR"
fi

# ---- 7. Firewalld ----
echo
echo "[7/9] Opening firewall port \$NEW_SSH_PORT/tcp (port 22 stays open as a"
echo "      safety net until you verify the new port works)…"
firewall-cmd --permanent --add-port="\$NEW_SSH_PORT/tcp" >/dev/null
firewall-cmd --reload >/dev/null

# ---- 8. SELinux ssh_port_t label ----
echo
echo "[8/9] Labeling port \$NEW_SSH_PORT as ssh_port_t in SELinux…"
if semanage port -l | grep -qE "ssh_port_t\s+tcp\s+.*\b\$NEW_SSH_PORT\b"; then
    echo "  port \$NEW_SSH_PORT already labeled ssh_port_t — skipping"
else
    semanage port -a -t ssh_port_t -p tcp "\$NEW_SSH_PORT"
fi

# ---- 9. sshd hardening drop-in ----
echo
echo "[9/9] Writing sshd hardening drop-in and restarting sshd…"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-bootstrap.conf"
cat > "\$SSHD_DROPIN" <<SSHDEOF
# Bootstrap-installed sshd hardening (see scripts/bootstrap-host.sh).
Port \$NEW_SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
SSHDEOF
chmod 0600 "\$SSHD_DROPIN"
if command -v restorecon >/dev/null 2>&1; then
    restorecon "\$SSHD_DROPIN"
fi
sshd -t
systemctl restart sshd

echo
echo "Remote hardening complete."
PAYLOAD
)
EOF

# ---- Phase 2: prompt user about external firewall --------------------------
cat <<EOF

==================================================================
 Phase 2 — external firewall
==================================================================

 sshd on $TARGET_HOST is now listening on port $NEW_SSH_PORT.
 Local firewalld already has the new port open.

 If your host has an EXTERNAL firewall (cloud provider security
 group, edge router rules, hosting-panel firewall, etc.):

     • OPEN  port $NEW_SSH_PORT/tcp
     • CLOSE port 22/tcp

 If you have no external firewall, just press Enter — local
 firewalld already covers port $NEW_SSH_PORT, and you can close
 port 22 in local firewalld in phase 4.

EOF

read -r -p "Press Enter to continue with verification (Ctrl-C to abort)... " _

# ---- Phase 3: verify new port works as the new user -----------------------
echo
echo "Phase 3 — verifying SSH on port $NEW_SSH_PORT as $NEW_USER@$TARGET_HOST …"
if ssh -p "$NEW_SSH_PORT" \
       -o ConnectTimeout=10 \
       -o StrictHostKeyChecking=accept-new \
       -o BatchMode=yes \
       "$NEW_USER@$TARGET_HOST" \
       'echo OK; hostnamectl --static 2>/dev/null | head -1' 2>&1 \
    | sed 's/^/  /'; then
    verified=true
else
    verified=false
fi

if ! "$verified"; then
    cat <<EOF

==================================================================
 ✗ Verification failed.
==================================================================

 Couldn't connect to $NEW_USER@$TARGET_HOST on port $NEW_SSH_PORT.

 Possible causes:
   - External firewall not yet open on port $NEW_SSH_PORT
   - Routing not yet propagated; wait a few seconds and retry
   - Your private key isn't loaded; try: ssh-add -l

 Try manually:
     ssh -p $NEW_SSH_PORT $NEW_USER@$TARGET_HOST

 Port 22 on the target is still open as a fallback. If everything
 is broken, SSH back as root@$TARGET_HOST:22 and remove
 /etc/ssh/sshd_config.d/99-bootstrap.conf.
EOF
    exit 1
fi

# ---- Phase 4: optionally close port 22 in local firewalld -----------------
echo
read -r -p "Close port 22 in the target's LOCAL firewalld now? [y/N] " close22
if [[ "$close22" =~ ^[Yy]$ ]]; then
    echo "  Closing port 22 via $NEW_USER@$TARGET_HOST:$NEW_SSH_PORT …"
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
 ✓ Done.
==================================================================

 The host is now ready as an Ansible target.

 Suggested ~/.ssh/config entry on this machine:

   Host $TARGET_HOST
     HostName $TARGET_HOST
     User $NEW_USER
     Port $NEW_SSH_PORT
     IdentityFile ~/.ssh/id_ed25519

 Then add to your inventory and deploy services with ansible-playbook.

EOF
