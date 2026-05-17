#!/bin/bash
# ============================================================================
# Home Server — Interactive Setup Script
#
# Run on a freshly installed RHEL-family host (AlmaLinux 9+, Rocky 9+,
# Fedora Server). Invoke as your non-root sudo user, NOT as root:
#   curl -fsSL https://raw.githubusercontent.com/luckynrslevin/home-server/main/setup.sh \
#     -o /tmp/setup.sh && bash /tmp/setup.sh
#
# This script:
#   1. Installs Ansible and dependencies
#   2. Clones the home-server repo
#   3. Installs the Galaxy role dependency
#   4. Walks you through configuring your server
#   5. Generates inventory, host_vars, vault secrets, and dashboard config
#   6. Lets you choose which services to deploy
#   7. Runs the selected playbooks against localhost
# ============================================================================
set -euo pipefail

# --- Require file execution (not pipe) ---
# This script is interactive and needs terminal stdin for prompts.
# When piped via `curl ... | bash`, stdin is consumed by the stream.
# Detect this and download + run from a file instead.
if [[ ! -t 0 ]]; then
    SELF_PATH="/tmp/home-server-setup.sh"
    curl -fsSL "https://raw.githubusercontent.com/luckynrslevin/home-server/main/setup.sh" \
        -o "$SELF_PATH" 2>/dev/null
    chmod +x "$SELF_PATH"
    echo
    echo "This script is interactive and cannot run via pipe."
    echo "It has been downloaded to: $SELF_PATH"
    echo
    echo "Run it with:"
    echo "  bash $SELF_PATH"
    echo
    exit 0
fi

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}==>${NC} $*"; }
ok()    { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}==> WARNING:${NC} $*"; }
err()   { echo -e "${RED}==> ERROR:${NC} $*" >&2; }
ask()   { echo -en "${BOLD}$*${NC} "; }

# --- Sanity checks ---
if [[ $EUID -eq 0 ]]; then
    err "Do not run this script as root. Run as your normal user (with sudo access)."
    exit 1
fi

# Distro family detection — accept anything in the RHEL family
# (rhel/centos/fedora as ID or anywhere in ID_LIKE). Same case
# statement scripts/bootstrap-host.sh uses, for consistency.
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    err "/etc/os-release missing — can't identify distro."
    exit 1
fi
case " ${ID:-} ${ID_LIKE:-} " in
    *" rhel "*|*" centos "*|*" fedora "*|*" almalinux "*|*" rocky "*) ;;
    *)
        err "This script supports the RHEL family (Fedora / AlmaLinux / Rocky)."
        err "  Detected: ID=${ID:-?} ID_LIKE=${ID_LIKE:-?}"
        exit 1
        ;;
esac

# Passwordless sudo is required — every install/config step shells out
# via `sudo dnf …` etc., and the script is non-interactive past the
# config-collection phase.
if ! sudo -n true 2>/dev/null; then
    err "This user needs passwordless sudo (NOPASSWD:ALL) to run setup.sh."
    err "See docs/Install-Manual.md → Step 3 for how to configure it."
    exit 1
fi

echo
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}   Home Server — Interactive Setup${NC}"
echo -e "${BOLD}============================================${NC}"
echo
echo "Setting up your server (${PRETTY_NAME:-${ID:-?} ${VERSION_ID:-?}}) as"
echo "an automated home server with containerized services managed by"
echo "Ansible and rootless Podman."
echo

# ============================================================================
# Step 1: Install prerequisites
# ============================================================================
info "Step 1/7: Installing prerequisites..."

# `pipx` lives in EPEL on AlmaLinux / Rocky / RHEL / CentOS-9 and in
# the base repos on Fedora. Enable EPEL on the RHEL-9 family before
# the install; on Fedora the block is skipped.
#
# We also install `python3.11` on the RHEL-9 family because:
#   - AL9's default system Python is 3.9.
#   - pipx defaults to building its venvs against the system Python.
#   - ansible-core 2.16+ requires Python ≥ 3.10.
#   - On Python 3.9, pipx caps us at ansible-core 2.15.x, which has
#     a parser bug in include_tasks/role-include path resolution
#     (TypeError: expected str, ... not NoneType) that this project's
#     Galaxy podman_quadlet role triggers reliably.
# python3.11 ships in AL9 AppStream; Fedora's system Python is
# already current so this whole block is a no-op there.
PIPX_PYTHON_ARG=()
if [[ "${ID:-}" =~ ^(almalinux|rocky|centos|rhel)$ ]]; then
    sudo dnf install -y epel-release python3.11 &>/dev/null \
        || sudo dnf install -y epel-release python3.11
    PIPX_PYTHON_ARG=(--python python3.11)
fi

sudo dnf install -y podman git python3-pyyaml pipx &>/dev/null \
    || sudo dnf install -y podman git python3-pyyaml pipx

# Hard-fail if pipx still isn't on PATH — usually means EPEL is
# misconfigured on AL/Rocky.
if ! command -v pipx &>/dev/null; then
    err "pipx not available after install — EPEL likely missing on AlmaLinux/Rocky."
    err "Try: sudo dnf install -y epel-release && sudo dnf install -y pipx"
    exit 1
fi

# Install ansible-core via pipx (latest available for the chosen
# Python). With python3.11 we get ansible-core 2.18.x; without the
# override on Fedora we get whatever's current for system Python.
if ! command -v ansible-playbook &>/dev/null; then
    pipx install "${PIPX_PYTHON_ARG[@]}" ansible-core &>/dev/null
    # Inject the full ansible package for built-in collections.
    pipx inject ansible-core ansible &>/dev/null
fi

# pipx installs into ~/.local/bin which isn't always on PATH for a
# fresh AlmaLinux 9 user (depends on ~/.bash_profile sourcing it).
# Make sure subsequent ansible-playbook calls in this script find it.
export PATH="$HOME/.local/bin:$PATH"

if ! command -v ansible-playbook &>/dev/null; then
    err "ansible-playbook not on PATH after pipx install."
    err "Expected at $HOME/.local/bin/ansible-playbook"
    exit 1
fi

ok "Prerequisites installed: $(ansible-playbook --version 2>/dev/null | head -1)"

# ============================================================================
# Step 2: Clone the repo
# ============================================================================
INSTALL_DIR="$HOME/home-server"

# Move out of $INSTALL_DIR before any rm/clone — if the user
# happens to be running setup.sh from inside ~/home-server (e.g.
# re-running after a previous attempt), wiping it leaves the shell
# with an unlinked cwd, and `git clone` silently fails on the
# missing directory.
cd "$HOME"

if [[ -d "$INSTALL_DIR" ]]; then
    warn "$INSTALL_DIR already exists."
    ask "Overwrite it? [y/N]:"
    read -r overwrite
    if [[ "$overwrite" =~ ^[Yy]$ ]]; then
        rm -rf "$INSTALL_DIR"
    else
        info "Using existing directory."
    fi
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
    info "Step 2/7: Cloning home-server repository..."
    # Don't suppress stderr — if git fails (auth, network, broken
    # cwd, …) we want the user to see why.
    git clone https://github.com/luckynrslevin/home-server.git "$INSTALL_DIR"
    ok "Repository cloned to $INSTALL_DIR"
else
    ok "Using existing $INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# ============================================================================
# Step 3: Install Galaxy dependency
# ============================================================================
info "Step 3/7: Installing Ansible Galaxy dependencies..."
ansible-galaxy install -r roles/requirements.yml --force 2>/dev/null
ok "Galaxy roles installed."

# ============================================================================
# Step 3.5: Hostname + optional private overlay
# ============================================================================
# Capture hostname early so the overlay prompt can look for an
# existing host_vars/<hostname>/main.yml. The hostname prompt in
# Step 5 used to live here; consolidated into this block.

DEFAULT_HOSTNAME=$(hostname -s 2>/dev/null)
echo
ask "Server hostname [$DEFAULT_HOSTNAME]:"
read -r SERVER_HOSTNAME
SERVER_HOSTNAME=${SERVER_HOSTNAME:-$DEFAULT_HOSTNAME}

OVERLAY_DIR="$HOME/home-server-private"
OVERLAY_URL=""
USE_EXISTING_INVENTORY=false

echo
echo -e "${BOLD}--- Private overlay repo (optional) ---${NC}"
echo
echo "If you have a private git repo for inventory storage — either an"
echo "existing one (rebuild path) or a fresh empty one prepared for"
echo "this host (first-time path) — point to it here. We'll clone it"
echo "and either reuse its inventory as-is or generate fresh inventory"
echo "directly into it."
echo "Leave empty to keep inventory local in ~/home-server/inventory/."
echo
ask "Private overlay repo URL [empty to skip]:"
read -r OVERLAY_URL

if [[ -n "$OVERLAY_URL" ]]; then
    ask "Vault password for the overlay (input hidden — invent one if the repo is empty):"
    read -rs OVERLAY_VAULT_PW
    echo
    if [[ -z "$OVERLAY_VAULT_PW" ]]; then
        err "Vault password is required when using an overlay."
        exit 1
    fi

    if [[ ! -d "$OVERLAY_DIR/.git" ]]; then
        info "Cloning overlay into $OVERLAY_DIR ..."
        git clone "$OVERLAY_URL" "$OVERLAY_DIR"
    else
        ok "Overlay already cloned at $OVERLAY_DIR — pulling latest."
        (cd "$OVERLAY_DIR" && git pull --ff-only) || warn "git pull failed; continuing with existing tree"
    fi

    mkdir -p "$OVERLAY_DIR/inventory/host_vars"

    # Vault pw lives in the overlay so future Case 3 rebuilds can
    # re-read it. ~/.vaultpw is a symlink so ansible.cfg stays valid.
    echo -n "$OVERLAY_VAULT_PW" > "$OVERLAY_DIR/vault.pw"
    chmod 400 "$OVERLAY_DIR/vault.pw"

    if [[ -f "$OVERLAY_DIR/inventory/host_vars/$SERVER_HOSTNAME/main.yml" ]]; then
        USE_EXISTING_INVENTORY=true
        ok "Overlay has existing inventory for '$SERVER_HOSTNAME' — using it as-is."
    else
        ok "Overlay has no inventory for '$SERVER_HOSTNAME' yet — will generate fresh into it."
        existing_hosts=$(ls -1 "$OVERLAY_DIR/inventory/host_vars/" 2>/dev/null | tr '\n' ' ')
        [[ -n "$existing_hosts" ]] && info "  Other hosts already in overlay: $existing_hosts"
    fi
fi

# ============================================================================
# Step 4: Configure vault password
# ============================================================================
info "Step 4/7: Setting up Ansible Vault..."

VAULT_PW_FILE="$HOME/.vaultpw"

if [[ -n "$OVERLAY_URL" ]]; then
    # Overlay path — point ~/.vaultpw at the overlay's vault.pw.
    rm -f "$VAULT_PW_FILE"
    ln -s "$OVERLAY_DIR/vault.pw" "$VAULT_PW_FILE"
    ok "Vault password symlinked: $VAULT_PW_FILE → $OVERLAY_DIR/vault.pw"

    if [[ "$USE_EXISTING_INVENTORY" == "true" ]]; then
        if ! ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PW_FILE" \
                ansible-vault view "$OVERLAY_DIR/inventory/host_vars/$SERVER_HOSTNAME/main.yml" \
                &>/dev/null; then
            err "Vault password doesn't decrypt the existing inventory at"
            err "  $OVERLAY_DIR/inventory/host_vars/$SERVER_HOSTNAME/main.yml"
            err "Re-run setup.sh with the correct vault password."
            exit 1
        fi
        ok "Vault password verified — existing inventory decrypts cleanly."
    fi
elif [[ -f "$VAULT_PW_FILE" ]]; then
    ok "Vault password already exists at $VAULT_PW_FILE"
else
    echo
    echo "Ansible Vault encrypts your secrets (passwords, API keys)."
    echo "You need a vault password — either generate a random one or choose your own."
    echo
    ask "Generate a random vault password? [Y/n]:"
    read -r gen_vault

    if [[ "$gen_vault" =~ ^[Nn]$ ]]; then
        ask "Enter your vault password:"
        read -rs vault_pw
        echo
        echo -n "$vault_pw" > "$VAULT_PW_FILE"
    else
        openssl rand -base64 32 > "$VAULT_PW_FILE"
    fi

    chmod 400 "$VAULT_PW_FILE"
    ok "Vault password saved to $VAULT_PW_FILE (mode 400)"
    echo
    warn "Back up this file! Without it you cannot decrypt your secrets."
fi

# Point ansible.cfg at the vault password file
cat > ansible.cfg << EOF
[defaults]
inventory = inventory/hosts.yml
roles_path = ./roles:./.ansible/roles:~/.ansible/roles:/usr/share/ansible/roles
stdout_callback = default
host_key_checking = False
vault_password_file = $VAULT_PW_FILE

[ssh_connection]
pipelining = True
use_tty = False
EOF

# Replace the public repo's inventory/ stub with a symlink into the
# overlay so generated (Case 2) or existing (Case 3) inventory lives
# in the overlay repo.
if [[ -n "$OVERLAY_URL" ]]; then
    if [[ ! -L inventory ]]; then
        rm -rf inventory
        ln -s "$OVERLAY_DIR/inventory" inventory
        ok "Symlinked inventory/ → $OVERLAY_DIR/inventory"
    fi
fi

# ============================================================================
# Step 5: Gather host configuration
# ============================================================================
if [[ "$USE_EXISTING_INVENTORY" == "true" ]]; then
    info "Step 5/7: Using existing inventory — skipping configuration prompts."
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    # Pull deSEC creds from existing inventory for the A-record refresh
    # in Step 6.5. ansible-inventory decrypts vaulted vars in its output.
    INV_JSON=$(ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PW_FILE" \
        ansible-inventory --host "$SERVER_HOSTNAME" 2>/dev/null)
    if [[ -z "$INV_JSON" ]]; then
        err "ansible-inventory couldn't read host vars for '$SERVER_HOSTNAME'."
        err "Check inventory/hosts.yml in the overlay."
        exit 1
    fi
    DESEC_SUBDOMAIN=$(echo "$INV_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('caddy_acme_subdomain',''))")
    DESEC_TOKEN=$(echo "$INV_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('caddy_acme_token',''))")
    CADDY_DOMAIN=$(echo "$INV_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('caddy_domain',''))")
    if [[ -z "$DESEC_SUBDOMAIN" || -z "$DESEC_TOKEN" ]]; then
        err "Existing inventory is missing caddy_acme_subdomain / caddy_acme_token."
        exit 1
    fi
    ok "Loaded inventory for $SERVER_HOSTNAME ($CADDY_DOMAIN)"
else

info "Step 5/7: Configuring your server..."

echo
echo -e "${BOLD}--- Network Configuration ---${NC}"
echo

# Detect IP and network automatically
DEFAULT_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
DEFAULT_GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
DEFAULT_NETWORK=$(ip -4 addr show "$DEFAULT_IFACE" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
DEFAULT_USER=$(whoami)

ask "Server IP address [$DEFAULT_IP]:"
read -r SERVER_IP
SERVER_IP=${SERVER_IP:-$DEFAULT_IP}

# --- TLS / cert strategy ---
# --- TLS via deSEC + Let's Encrypt ---
# Single supported path: real LE certs via DNS-01 against deSEC.
# User signs up at desec.io, claims a *.dedyn.io subdomain, and
# generates an API token; we prompt for both.
echo
echo -e "${BOLD}--- deSEC + Let's Encrypt ---${NC}"
echo
echo "Caddy issues real Let's Encrypt certs via DNS-01 against deSEC."
echo "Every device gets a green padlock with no per-device CA install."
echo "Sign up at https://desec.io/ first if you haven't:"
echo "  1. Register an account and confirm via email."
echo "  2. Claim a *.dedyn.io subdomain at first sign-in."
echo "  3. Create an API token in Token Management."
echo "See docs/Setup-Guide/01-deSEC-account.md for the click-by-click."
echo
ask "deSEC subdomain (without .dedyn.io):"
read -r DESEC_SUBDOMAIN
if [[ -z "$DESEC_SUBDOMAIN" ]]; then
    err "Subdomain is required."
    exit 1
fi
ask "deSEC API token (input hidden):"
read -rs DESEC_TOKEN
echo
if [[ -z "$DESEC_TOKEN" ]]; then
    err "Token is required."
    exit 1
fi
CADDY_DOMAIN="${DESEC_SUBDOMAIN}.dedyn.io"
ok "Caddy domain: $CADDY_DOMAIN"

ask "Your username [$DEFAULT_USER]:"
read -r SERVER_USER
SERVER_USER=${SERVER_USER:-$DEFAULT_USER}

ask "LAN subnet (for Pi-hole) [$DEFAULT_NETWORK]:"
read -r LAN_NETWORK
LAN_NETWORK=${LAN_NETWORK:-$DEFAULT_NETWORK}
# Convert to CIDR notation if needed (e.g., 192.168.1.5/24 → 192.168.1.0/24)
LAN_PREFIX=$(echo "$LAN_NETWORK" | cut -d/ -f2)
LAN_NETWORK_BASE=$(echo "$LAN_NETWORK" | cut -d/ -f1 | awk -F. '{printf "%s.%s.%s.0", $1, $2, $3}')
LAN_CIDR="${LAN_NETWORK_BASE}/${LAN_PREFIX}"

ask "LAN gateway/router [$DEFAULT_GATEWAY]:"
read -r LAN_GATEWAY
LAN_GATEWAY=${LAN_GATEWAY:-$DEFAULT_GATEWAY}

echo
echo -e "${BOLD}--- Timezone ---${NC}"
echo
DEFAULT_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")
ask "Timezone [$DEFAULT_TZ]:"
read -r TIMEZONE
TIMEZONE=${TIMEZONE:-$DEFAULT_TZ}

# --- SMTP relay (project-level) ---
# Needed by Nextcloud (password resets / share notifications), Ente
# Photos (signup OTPs — without SMTP, the operator has to read codes
# out of postgres), and Paperless-NGX (notifications). One relay
# config used by every role.
#
# See docs/SMTP-Setup.md. Recommended: Mailbox.org with an app
# password. Skip to deploy without working email — apps still install
# but can't send mail until you fill in these vars later.
echo
echo -e "${BOLD}--- SMTP relay (required) ---${NC}"
echo
echo "Nextcloud (password resets, share notifications), Ente Photos"
echo "(signup OTPs) and Paperless need an external SMTP relay to send"
echo "mail. See docs/SMTP-Setup.md for picking a provider (Mailbox.org"
echo "/ Posteo / etc.) and generating an app password."
echo
ask "SMTP host [smtp.mailbox.org]:"
read -r SMTP_HOST
SMTP_HOST=${SMTP_HOST:-smtp.mailbox.org}
ask "SMTP port [587]:"
read -r SMTP_PORT
SMTP_PORT=${SMTP_PORT:-587}
ask "SMTP username (full email):"
read -r SMTP_USERNAME
if [[ -z "$SMTP_USERNAME" ]]; then
    err "SMTP username is required."
    exit 1
fi
ask "SMTP password / app password (input hidden):"
read -rs SMTP_PASSWORD
echo
if [[ -z "$SMTP_PASSWORD" ]]; then
    err "SMTP password is required."
    exit 1
fi
ask "Encryption (starttls / ssl) [starttls]:"
read -r SMTP_ENCRYPTION
SMTP_ENCRYPTION=${SMTP_ENCRYPTION:-starttls}
ask "From address [$SMTP_USERNAME]:"
read -r SMTP_FROM
SMTP_FROM=${SMTP_FROM:-$SMTP_USERNAME}
ok "SMTP relay configured."

echo
echo -e "${BOLD}--- Service Selection ---${NC}"
echo
echo "Choose which services to deploy. You can always add more later"
echo "by running individual playbooks."
echo

declare -A SERVICES
SERVICES=(
    [dashboard]="Status dashboard showing all services"
    [pihole]="Pi-hole DNS ad-blocker"
    [entephoto]="Ente Photos (self-hosted photo storage)"
    [paperless-ngx]="Paperless-NGX document management (OCR + search)"
    [syncthing]="Syncthing file synchronization"
    [shairportsync]="Shairport-sync AirPlay audio receiver (needs audio device)"
    [jellyfin]="Jellyfin media server (movies, TV, music)"
    [music-assistant]="Music Assistant music server (optional local Squeezelite player on hosts with a USB DAC)"
)

# Caddy + Nextcloud are mandatory:
#   - Caddy is the front-door reverse proxy for every HTTPS service.
#   - Nextcloud is the household OIDC identity provider (Paperless and
#     future apps log in against it) and the central file/contacts
#     workspace.
SELECTED_SERVICES=(caddy nextcloud)

# Optional services. Defaults reflect the recommended baseline:
#   Y — dashboard, pihole, entephoto, paperless-ngx
#   N — syncthing, shairportsync, jellyfin, music-assistant
SERVICE_ORDER=(dashboard pihole entephoto paperless-ngx syncthing shairportsync jellyfin music-assistant)
declare -A SERVICE_DEFAULT_YES=(
    [dashboard]=1
    [pihole]=1
    [entephoto]=1
    [paperless-ngx]=1
)

for svc in "${SERVICE_ORDER[@]}"; do
    desc="${SERVICES[$svc]}"
    if [[ -n "${SERVICE_DEFAULT_YES[$svc]:-}" ]]; then
        ask "Deploy $svc? ($desc) [Y/n]:"
        read -r answer
        [[ ! "$answer" =~ ^[Nn]$ ]] && SELECTED_SERVICES+=("$svc")
    else
        ask "Deploy $svc? ($desc) [y/N]:"
        read -r answer
        [[ "$answer" =~ ^[Yy]$ ]] && SELECTED_SERVICES+=("$svc")
    fi
done

echo
ok "Selected services: ${SELECTED_SERVICES[*]}"

is_selected() {
    local needle=$1
    for s in "${SELECTED_SERVICES[@]}"; do
        [[ "$s" == "$needle" ]] && return 0
    done
    return 1
}

# ============================================================================
# Step 6: Generate configuration files
# ============================================================================
info "Step 6/7: Generating configuration files..."

# Helper: vault-encrypt a string.
# Uses a temp file for the value (avoids stdin conflicts with curl pipe).
# Uses ANSIBLE_VAULT_PASSWORD_FILE env var instead of --vault-password-file
# flag to avoid "duplicate vault-ids" error when ansible.cfg also sets it.
vault_encrypt() {
    local value=$1 name=$2
    local tmpfile
    tmpfile=$(mktemp)
    echo -n "$value" > "$tmpfile"
    ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PW_FILE" \
    ansible-vault encrypt_string \
        --encrypt-vault-id default \
        --stdin-name "$name" < "$tmpfile" 2>/dev/null
    rm -f "$tmpfile"
}

# --- Generate inventory/hosts.yml ---
mkdir -p "inventory/host_vars/$SERVER_HOSTNAME"

# When the overlay already has a multi-host hosts.yml, merge instead
# of clobber. Pure write for a brand-new file.
if [[ -s inventory/hosts.yml ]]; then
    python3 - "$SERVER_HOSTNAME" "$SERVER_USER" << 'PYEOF'
import sys, yaml
hostname, user = sys.argv[1], sys.argv[2]
with open("inventory/hosts.yml") as f:
    data = yaml.safe_load(f) or {}
data.setdefault("all", {}).setdefault("children", {}).setdefault(
    "homeservers", {}).setdefault("hosts", {})[hostname] = {
        "ansible_host": "127.0.0.1",
        "ansible_connection": "local",
        "ansible_user": user,
    }
with open("inventory/hosts.yml", "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
PYEOF
    ok "Merged $SERVER_HOSTNAME into existing inventory/hosts.yml"
else
    cat > inventory/hosts.yml << EOF
all:
  children:
    homeservers:
      hosts:
        $SERVER_HOSTNAME:
          ansible_host: 127.0.0.1
          ansible_connection: local
          ansible_user: $SERVER_USER
EOF
    ok "Generated inventory/hosts.yml"
fi

# --- Generate host_vars ---
info "Generating secrets (this takes a moment)..."

# Generate all secrets
PIHOLE_PW=$(openssl rand -base64 24)
ENTEPHOTO_DB_PW=$(openssl rand -base64 24)
ENTEPHOTO_MINIO_PW=$(openssl rand -base64 24)
ENTEPHOTO_ENC_KEY=$(openssl rand -base64 32)
ENTEPHOTO_HASH_KEY=$(openssl rand -base64 64 | tr -d '\n')
ENTEPHOTO_JWT=$(openssl rand -hex 32)
PAPERLESS_SECRET_KEY=$(openssl rand -hex 32)
PAPERLESS_DB_PW=$(openssl rand -base64 24)
PAPERLESS_ADMIN_PW=$(openssl rand -base64 24)
JELLYFIN_ADMIN_PW=$(openssl rand -base64 24)
NEXTCLOUD_ADMIN_PW=$(openssl rand -base64 24)
NEXTCLOUD_DB_PW=$(openssl rand -base64 24)

# Generate a stable, locally-administered unicast MAC for Music
# Assistant's built-in Squeezelite player. First octet 0x02 sets the
# locally-administered bit (b1=1) and clears the multicast bit
# (b0=0). SlimProto uses the MAC as the player's identity, so a
# stable value keeps the player recognized across redeploys and
# clean re-installs.
MUSIC_ASSISTANT_MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g;s/:$//')"

# Build the host_vars file
{
cat << YAML
##################################################################################################
### Host identity
# Pin the system hostname so os-base never renames the box on a
# re-deploy (the role's default would be inventory_hostname).
os_base_hostname: $SERVER_HOSTNAME

##################################################################################################
### Services to deploy on this host (used by playbooks/site.yml)
deploy_services:
YAML

for svc in "${SELECTED_SERVICES[@]}"; do
    echo "  - $svc"
done

cat << YAML

##################################################################################################
### Linux users — service accounts with fixed UIDs
my_linux_users:
  $SERVER_USER:
    uid: 1000
    gid: 1000
  shairport:
    uid: 1001
    gid: 1001
  syncthg:
    uid: 1003
    gid: 1003
  pihole:
    uid: 1005
    gid: 1005
  entephoto:
    uid: 1008
    gid: 1008
  paperless:
    uid: 1007
    gid: 1007
  jellyfin:
    uid: 1012
    gid: 1012
  webproxy:
    uid: 1011
    gid: 1011
  music-assistant:
    uid: 1014
    gid: 1014
  nextcloud:
    uid: 1015
    gid: 1015
##################################################################################################

### Caddy reverse-proxy + Let's Encrypt via deSEC DNS-01
caddy_domain: "$CADDY_DOMAIN"
caddy_acme_provider: "desec"
caddy_acme_subdomain: "$DESEC_SUBDOMAIN"
YAML

echo ""
vault_encrypt "$DESEC_TOKEN" "caddy_acme_token"
echo ""

# Emit caddy_reverse_proxy_services for selected services so each
# selected web UI is fronted at https://<sub>.$CADDY_DOMAIN with a
# real Let's Encrypt cert.
echo "caddy_reverse_proxy_services:"
is_selected pihole       && echo '  - { subdomain: pihole, port: 8443, proto: https }'
is_selected syncthing    && echo '  - { subdomain: syncthing, port: 8384, proto: https }'
if is_selected entephoto; then
  echo '  - { subdomain: photos, port: 3000 }'
  echo '  - { subdomain: accounts, port: 3001 }'
  echo '  - { subdomain: cast, port: 3002 }'
  echo '  - { subdomain: auth, port: 3003 }'
  echo '  - { subdomain: photos-api, port: 8080 }'
  echo '  - { subdomain: photos-s3, port: 3200 }'
fi
is_selected paperless-ngx   && echo '  - { subdomain: paperless, port: 8000 }'
is_selected jellyfin        && echo '  - { subdomain: jellyfin, port: 8096 }'
is_selected music-assistant && echo '  - { subdomain: music, port: 8095 }'
is_selected nextcloud       && echo '  - { subdomain: cloud, port: 8090 }'
echo ""

cat << YAML

### Pi-hole
pihole_local_network: "$LAN_CIDR"
pihole_local_router: "$LAN_GATEWAY"
YAML

echo ""
vault_encrypt "$PIHOLE_PW" "pihole_api_password"
echo ""
echo "### Music Assistant"
echo "# Stable MAC for the built-in Squeezelite player. SlimProto"
echo "# identifies players by MAC, so a fixed value keeps the player"
echo "# recognized across redeploys."
echo "music_assistant_squeezelite_mac: \"$MUSIC_ASSISTANT_MAC\""
echo "# On a host without a USB DAC / sound card, set this to false to"
echo "# skip the local Squeezelite player container — MA server still"
echo "# runs and can drive AirPlay / Cast / external Squeezelite."
echo "# music_assistant_player_enabled: false"
echo ""
echo "### Ente Photos"
echo "# Public URLs of the Ente services. Without these, the web client"
echo "# auto-detects http://<host_ip>:<port> from defaults and pops a"
echo "# 'developer settings' dialog at signup. Setting them here makes"
echo "# Caddy the canonical entry point and uses real LE certs."
echo "entephoto_api_url: \"https://photos-api.${CADDY_DOMAIN}\""
echo "entephoto_photos_url: \"https://photos.${CADDY_DOMAIN}\""
echo "# Port 9443 is intentional. Caddy's rootless quadlet publishes"
echo "# :9443 (only :80 / :443 are NAT'd in the host firewall, and that"
echo "# NAT only fires for inbound LAN traffic). Pod-to-host traffic"
echo "# from museum can ONLY reach the host at the high-numbered"
echo "# pasta-published ports. Browser uses the same URL — port 9443"
echo "# is open on the LAN too, so it works from both vantage points."
echo "entephoto_s3_endpoint: \"photos-s3.${CADDY_DOMAIN}:9443\""
echo "entephoto_s3_host: \"photos-s3.${CADDY_DOMAIN}\""
echo "# false here flips Ente's presigned upload URLs to https://, which"
echo "# matches the Caddy-fronted endpoint above and avoids browser"
echo "# mixed-content errors."
echo "entephoto_s3_local_buckets: false"
echo ""
vault_encrypt "$ENTEPHOTO_DB_PW" "entephoto_db_password"
echo ""
vault_encrypt "$ENTEPHOTO_MINIO_PW" "entephoto_minio_password"
echo ""
vault_encrypt "$ENTEPHOTO_ENC_KEY" "entephoto_encryption_key"
echo ""
vault_encrypt "$ENTEPHOTO_HASH_KEY" "entephoto_hash_key"
echo ""
vault_encrypt "$ENTEPHOTO_JWT" "entephoto_jwt_secret"
echo ""
echo "entephoto_admin_user_ids: []"
echo ""
echo "### Paperless-NGX"
echo "# Public URL of the web UI. Used for absolute-URL generation"
echo "# and as the only entry in Django's CSRF trusted origins,"
echo "# so login through the Caddy reverse-proxy stops returning 403."
echo "paperless_url: \"https://paperless.${CADDY_DOMAIN}\""
echo ""
vault_encrypt "$PAPERLESS_SECRET_KEY" "paperless_secret_key"
echo ""
vault_encrypt "$PAPERLESS_DB_PW" "paperless_db_password"
echo ""
vault_encrypt "$PAPERLESS_ADMIN_PW" "paperless_admin_password"
echo ""
echo "### Jellyfin"
vault_encrypt "$JELLYFIN_ADMIN_PW" "jellyfin_admin_password"

if is_selected nextcloud; then
    echo ""
    echo "### Nextcloud"
    vault_encrypt "$NEXTCLOUD_ADMIN_PW" "nextcloud_admin_password"
    echo ""
    vault_encrypt "$NEXTCLOUD_DB_PW" "nextcloud_db_password"
fi

if [[ -n "${SMTP_HOST:-}" ]]; then
    echo ""
    echo "### SMTP relay (project-level — used by Nextcloud, Ente, Paperless)"
    echo "# See docs/SMTP-Setup.md for provider/credential setup + rotation."
    echo "smtp_host: \"$SMTP_HOST\""
    echo "smtp_port: $SMTP_PORT"
    echo "smtp_username: \"$SMTP_USERNAME\""
    echo "smtp_encryption: \"$SMTP_ENCRYPTION\""
    echo "smtp_from: \"$SMTP_FROM\""
    vault_encrypt "$SMTP_PASSWORD" "smtp_password"
fi
echo "##################################################################################################"
} > inventory/host_vars/$SERVER_HOSTNAME/main.yml

ok "Generated inventory/host_vars/$SERVER_HOSTNAME/main.yml (with vault-encrypted secrets)"

# --- Generate dashboard config ---
# Only include services that were actually selected for deployment, so
# the dashboard doesn't display stale "Stopped" rows for un-deployed
# services.

{
echo "services:"

if is_selected shairportsync; then
cat << EOF
  - name: Shairport-sync
    user: root
    service: shairport-sync
    rootful: true
    volumes: []

EOF
fi

if is_selected pihole; then
cat << EOF
  - name: Pi-hole
    user: pihole
    uid: 1005
    service: pihole
    urls:
      - label: Admin UI
        url: https://pihole.${CADDY_DOMAIN}/admin
    volumes:
      - systemd-pihole-etc
      - systemd-pihole-dnsmasq

EOF
fi

if is_selected syncthing; then
cat << EOF
  - name: Syncthing
    user: syncthg
    uid: 1003
    service: syncthing
    urls:
      - label: Web UI
        url: https://syncthing.${CADDY_DOMAIN}
    volumes:
      - systemd-syncthing

EOF
fi

if is_selected entephoto; then
cat << EOF
  - name: Ente Photos
    user: entephoto
    uid: 1008
    service: entephoto-pod
    urls:
      - label: Photos
        url: https://photos.${CADDY_DOMAIN}
      - label: API
        url: https://photos-api.${CADDY_DOMAIN}/ping
    volumes:
      - entephoto-postgres-data
      - entephoto-minio-data
      - entephoto-museum-config

EOF
fi

if is_selected paperless-ngx; then
cat << EOF
  - name: Paperless-NGX
    user: paperless
    uid: 1007
    service: paperless-ngx-pod
    urls:
      - label: Web UI
        url: https://paperless.${CADDY_DOMAIN}
    volumes:
      - paperless-db-data
      - paperless-media
      - paperless-data

EOF
fi

if is_selected jellyfin; then
cat << EOF
  - name: Jellyfin
    user: jellyfin
    uid: 1012
    service: jellyfin
    urls:
      - label: Web UI
        url: https://jellyfin.${CADDY_DOMAIN}
    volumes:
      - jellyfin-config
      - jellyfin-media

EOF
fi

if is_selected music-assistant; then
cat << EOF
  - name: Music Assistant
    user: music-assistant
    uid: 1014
    service: music-assistant-pod
    urls:
      - label: Web UI
        url: https://music.${CADDY_DOMAIN}
    volumes:
      - music-assistant-data

EOF
fi

if is_selected nextcloud; then
cat << EOF
  - name: Nextcloud
    user: nextcloud
    uid: 1015
    service: nextcloud-pod
    urls:
      - label: Web UI
        url: https://cloud.${CADDY_DOMAIN}
    volumes:
      - nextcloud-config
      - nextcloud-data

EOF
fi
} > inventory/host_vars/$SERVER_HOSTNAME/dashboard-config.yaml

ok "Generated inventory/host_vars/$SERVER_HOSTNAME/dashboard-config.yaml"

fi  # end of USE_EXISTING_INVENTORY == false (Steps 5 + 6)

# ============================================================================
# Step 6.5: deSEC API — upsert A records + clear stale ACME challenge TXT
# ============================================================================
# Writes `*.<sub>.dedyn.io` and `<sub>.dedyn.io` → SERVER_IP so LAN
# clients (Pi-hole) and roaming Tailscale clients both resolve every
# Caddy subdomain to this host's LAN IP. Caddy then issues a wildcard
# LE cert against deSEC's DNS-01 challenge during the deploy below.
# PATCH on the rrset collection is idempotent — safe to re-run.
#
# Also clears `_acme-challenge.<sub>` TXT. Mitigates issue #170:
# Caddy's deSEC plugin occasionally leaves stale TXT records from
# a failed previous order, and the apex + wildcard cert challenges
# race on the same TXT name. Starting from a clean state ensures
# Caddy's first DNS-01 round sees only its own values; sending the
# rrset with records=[] tells deSEC to delete it. No-op if absent.
info "Step 6.5/7: Writing A records + clearing stale _acme-challenge TXT at deSEC..."
api_body=$(cat <<JSON
[
  {"subname":"","type":"A","ttl":3600,"records":["$SERVER_IP"]},
  {"subname":"*","type":"A","ttl":3600,"records":["$SERVER_IP"]},
  {"subname":"_acme-challenge","type":"TXT","ttl":3600,"records":[]}
]
JSON
)
api_resp=$(curl -sS -w "\n%{http_code}" -X PATCH \
    "https://desec.io/api/v1/domains/${DESEC_SUBDOMAIN}.dedyn.io/rrsets/" \
    -H "Authorization: Token $DESEC_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary "$api_body" 2>&1)
api_code=$(echo "$api_resp" | tail -n1)
api_body_resp=$(echo "$api_resp" | head -n -1)
if [[ "$api_code" == "200" ]]; then
    ok "deSEC: ${DESEC_SUBDOMAIN}.dedyn.io and *.${DESEC_SUBDOMAIN}.dedyn.io → $SERVER_IP"
else
    err "deSEC API call failed (HTTP $api_code):"
    echo "$api_body_resp" >&2
    err "Check that the subdomain '$DESEC_SUBDOMAIN' exists in your deSEC account"
    err "and the token has write access. Then re-run setup.sh."
    exit 1
fi

# ============================================================================
# Step 7: Deploy selected services
# ============================================================================
echo
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}   Ready to deploy!${NC}"
echo -e "${BOLD}============================================${NC}"
echo
echo "The following services will be deployed to this server:"
echo
for svc in "${SELECTED_SERVICES[@]}"; do
    echo "  - $svc"
done
echo
ask "Proceed with deployment? [Y/n]:"
read -r proceed
if [[ "$proceed" =~ ^[Nn]$ ]]; then
    echo
    ok "Setup complete! Configuration files generated at:"
    echo "  $INSTALL_DIR/inventory/hosts.yml"
    echo "  $INSTALL_DIR/inventory/host_vars/$SERVER_HOSTNAME/"
    echo
    echo "Deploy manually anytime with:"
    echo "  cd $INSTALL_DIR"
    echo "  ansible-playbook playbooks/site.yml --limit $SERVER_HOSTNAME"
    exit 0
fi

echo

info "Deploying selected services..."
ansible-playbook playbooks/site.yml --limit $SERVER_HOSTNAME
DEPLOY_EXIT=$?

if [[ $DEPLOY_EXIT -ne 0 ]]; then
    warn "Some services may have failed. Check the output above."
    echo "Re-run with: cd $INSTALL_DIR && ansible-playbook playbooks/site.yml --limit $SERVER_HOSTNAME"
fi

# Rootless containers can take a moment to start after the playbook
# finishes (linger user manager + image pulls). Refresh the dashboard
# after a short delay so the first page view reflects real state instead
# of the post-install "all stopped" snapshot.
if is_selected dashboard; then
    info "Refreshing dashboard..."
    sleep 30
    sudo systemctl start home-server-dashboard.service 2>/dev/null || true
fi

# ============================================================================
# Done!
# ============================================================================
echo
echo -e "${BOLD}============================================${NC}"
echo -e "${GREEN}${BOLD}   Setup complete!${NC}"
echo -e "${BOLD}============================================${NC}"
echo
echo "Your home server is now running at: https://${CADDY_DOMAIN}"
echo
echo -e "${BOLD}Back up ${VAULT_PW_FILE} into your password manager now.${NC}"
echo "Without it you cannot re-deploy this host or decrypt its inventory."
echo
echo "Configuration files:"
echo "  $INSTALL_DIR/inventory/host_vars/$SERVER_HOSTNAME/main.yml"
echo "  $INSTALL_DIR/inventory/host_vars/$SERVER_HOSTNAME/dashboard-config.yaml"
echo

if [[ -n "${OVERLAY_URL:-}" && "$USE_EXISTING_INVENTORY" != "true" ]]; then
    echo -e "${BOLD}Persist your generated inventory to the overlay repo:${NC}"
    echo "  cd $OVERLAY_DIR"
    echo "  git add -A && git commit -m \"$SERVER_HOSTNAME: initial install\" && git push"
    echo
fi
echo "Container images auto-update daily via podman-auto-update.timer."
echo "See the Quickstart.md for more details."
echo
