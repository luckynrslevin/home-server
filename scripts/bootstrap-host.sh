#!/bin/bash
# ============================================================================
# Open a path for Ansible to reach a fresh RHEL-family host.
#
# Run this *on the target* (you've already SSH'd or console'd in). The
# script applies a minimal hardening payload locally so that Ansible can
# take over from your laptop afterwards. There is no remote SSH layer.
#
# Supported targets: RHEL 8/9, AlmaLinux 8/9, Rocky 8/9, CentOS Stream 8/9,
# Oracle Linux 8/9, and Fedora. The script checks `/etc/os-release` and
# bails on anything else (Debian/Ubuntu/Arch/etc).
#
# Two invocation modes, decided by who runs the script:
#
#   - Running as root (e.g. you SSH'd in with the root password) →
#     create a new sudo user (default name: ansible) and install the
#     SSH key for that user. You should not keep using root long-term.
#
#   - Running via sudo as a non-root user (e.g. cloud-init gave you
#     `fedora` / `almalinux` / `opc` with NOPASSWD sudo) → use that
#     user as the ansible user. The SSH key is appended to that user's
#     authorized_keys and a NOPASSWD sudoers drop-in is written to
#     make the privilege grant permanent. No new user is created.
#
# Either way the script then:
#   - opens the new SSH port in firewalld and labels it ssh_port_t
#   - writes /etc/ssh/sshd_config.d/99-bootstrap.conf to move sshd to
#     the new port and disable root login + password auth
#   - leaves port 22 open in local firewalld as a fallback (close it
#     yourself once you've verified the new port works)
#
# Usage:
#   sudo bash scripts/bootstrap-host.sh -k <ssh-pubkey> [-u <user>] [-p <port>]
#
# Or directly via curl on the target:
#   curl -fsSL https://raw.githubusercontent.com/luckynrslevin/home-server/refs/heads/main/scripts/bootstrap-host.sh \
#     | sudo bash -s -- -k "$(cat ~/.ssh/id_ed25519.pub)"
#
# After it finishes, verify from your laptop:
#   ssh -p <port> <user>@<this-host>
# ============================================================================

set -euo pipefail

# ---- Defaults --------------------------------------------------------------
SSH_PUBKEY=""
NEW_USER_OVERRIDE=""    # set if -u was explicitly passed; empty otherwise
NEW_USER_DEFAULT="ansible"
NEW_SSH_PORT=2222

usage() {
    cat <<'EOF'
Usage: bootstrap-host.sh -k <ssh-pubkey> [-u <user>] [-p <port>]

Run this on the target host, as root or via sudo.

Required:
  -k <pubkey>    SSH public key (string) to install for the ansible user

Optional:
  -u <user>      Username to create (root-mode only; default: ansible).
                 Ignored when invoked via sudo by a non-root user — that
                 user is used as the ansible user instead.
  -p <port>      SSH port to harden onto   (default: 2222)
  -h             Show this help and exit

Examples:
  sudo bash bootstrap-host.sh -k "$(cat ~/.ssh/id_ed25519.pub)"
  sudo bash bootstrap-host.sh -k "$(cat key.pub)" -p 2200
EOF
}

# ---- Args ------------------------------------------------------------------
while getopts ":k:u:p:h" opt; do
    case "$opt" in
        k) SSH_PUBKEY="$OPTARG" ;;
        u) NEW_USER_OVERRIDE="$OPTARG" ;;
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
[[ -z "$SSH_PUBKEY" ]] && { echo "Error: -k <ssh-pubkey> is required." >&2; usage >&2; exit 1; }

USERNAME_RE='^[a-z_][a-z0-9_-]{0,31}$'
if [[ -n "$NEW_USER_OVERRIDE" ]] && ! [[ "$NEW_USER_OVERRIDE" =~ $USERNAME_RE ]]; then
    echo "Error: invalid username '$NEW_USER_OVERRIDE' (must match $USERNAME_RE)." >&2
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

# ---- Privilege + mode detection -------------------------------------------
# Must be root. The two modes differ on whether sudo brought us here:
#   - $SUDO_USER unset (or 'root')   → mode=root, create a new user
#   - $SUDO_USER set to a non-root   → mode=sudo, that user is the target
if (( EUID != 0 )); then
    # Detect curl|bash invocation: $0 is the interpreter name (e.g.
    # "bash") because the script came in over stdin, not from a real
    # path on disk. In that case `sudo bash $0` is meaningless — point
    # the user at `curl … | sudo bash -s -- …` instead.
    cat >&2 <<EOF
Error: must run as root. Re-run with sudo:

EOF
    if [[ -f "$0" ]]; then
        echo "  sudo bash $0 $*" >&2
    else
        cat >&2 <<EOF
  curl -fsSL https://raw.githubusercontent.com/luckynrslevin/home-server/refs/heads/main/scripts/bootstrap-host.sh \\
    | sudo bash -s -- -k "<your-ssh-pubkey>" [-u <user>] [-p <port>]
EOF
    fi
    exit 1
fi

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    MODE="sudo"
    TARGET_USER="$SUDO_USER"
    if [[ -n "$NEW_USER_OVERRIDE" && "$NEW_USER_OVERRIDE" != "$TARGET_USER" ]]; then
        echo "Warning: -u '$NEW_USER_OVERRIDE' ignored — using invoking sudo user '$TARGET_USER' as the ansible user." >&2
    fi
else
    MODE="root"
    TARGET_USER="${NEW_USER_OVERRIDE:-$NEW_USER_DEFAULT}"
fi

if ! [[ "$TARGET_USER" =~ $USERNAME_RE ]]; then
    echo "Error: target username '$TARGET_USER' is invalid (must match $USERNAME_RE)." >&2
    exit 1
fi

echo "=================================================================="
echo " On-target bootstrap"
echo "   mode:           $MODE"
echo "   target user:    $TARGET_USER"
echo "   new ssh port:   $NEW_SSH_PORT"
echo "   pubkey:         ${SSH_PUBKEY:0:50}..."
echo "=================================================================="

# ---- 0. Distro sanity check ----
# Accept anything in the RHEL-family tree (rhel/centos/fedora as ID
# or anywhere in ID_LIKE). dnf, firewalld, SELinux, semanage, and
# restorecon below all assume that family.
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
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
echo "Detected: ${PRETTY_NAME:-${ID:-?} ${VERSION_ID:-?}}"

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
if [[ "$MODE" == "root" ]]; then
    echo "[3/6] Creating user $TARGET_USER with passwordless sudo..."
    if id "$TARGET_USER" >/dev/null 2>&1; then
        echo "  user $TARGET_USER already exists — skipping useradd"
    else
        useradd -m -s /bin/bash "$TARGET_USER"
    fi
else
    echo "[3/6] Ensuring permanent NOPASSWD sudo for invoking user $TARGET_USER..."
fi

SUDOERS_FILE="/etc/sudoers.d/90-$TARGET_USER"
cat > "$SUDOERS_FILE" <<SUDO
# Bootstrap-installed: $TARGET_USER may run any command without a password.
$TARGET_USER ALL=(ALL) NOPASSWD:ALL
SUDO
chmod 0440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" >/dev/null

# ---- 4. SSH public key ----
echo "[4/6] Installing SSH public key for $TARGET_USER..."
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    echo "Error: home directory for $TARGET_USER not found (looked up: '$USER_HOME')." >&2
    exit 1
fi
USER_SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$USER_SSH_DIR/authorized_keys"
install -d -m 0700 -o "$TARGET_USER" -g "$TARGET_USER" "$USER_SSH_DIR"
touch "$AUTH_KEYS"
if grep -qxF "$SSH_PUBKEY" "$AUTH_KEYS"; then
    echo "  key already present — skipping"
else
    echo "$SSH_PUBKEY" >> "$AUTH_KEYS"
    echo "  key appended to $AUTH_KEYS"
fi
chmod 0600 "$AUTH_KEYS"
chown "$TARGET_USER:$TARGET_USER" "$AUTH_KEYS"
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

# ---- Done ------------------------------------------------------------------
THIS_HOST=$(hostnamectl --static 2>/dev/null || hostname)

cat <<EOF

==================================================================
 ✓ Bootstrap done on $THIS_HOST.
==================================================================

 Port 22 is still open in local firewalld as a fallback.
 sshd is now listening on port $NEW_SSH_PORT as well.

 From your laptop:

  1. (If applicable) Update any external firewall:
        OPEN  $NEW_SSH_PORT/tcp
        CLOSE 22/tcp

  2. Verify SSH on the new port:
        ssh -p $NEW_SSH_PORT $TARGET_USER@$THIS_HOST

  3. Add to ~/.ssh/config:
        Host $THIS_HOST
          HostName $THIS_HOST
          User $TARGET_USER
          Port $NEW_SSH_PORT
          IdentityFile ~/.ssh/id_ed25519

  4. Once verified, close port 22 in local firewalld here:
        sudo firewall-cmd --permanent --remove-service=ssh \\
          && sudo firewall-cmd --reload

 Then hand off to Ansible:
        ansible -i inventory/hosts.yml $THIS_HOST -m ping
        ansible-playbook playbooks/site.yml --limit $THIS_HOST
EOF
