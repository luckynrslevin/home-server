#!/bin/bash
# ============================================================================
# Home Server — Interactive Setup Script
#
# Run on a freshly installed Fedora Server:
#   curl -fsSL https://raw.githubusercontent.com/luckynrslevin/home-server/main/setup.sh | bash
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

if ! command -v dnf &>/dev/null; then
    err "This script requires Fedora (dnf not found)."
    exit 1
fi

echo
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}   Home Server — Interactive Setup${NC}"
echo -e "${BOLD}============================================${NC}"
echo
echo "This script will set up your Fedora server as an automated home server"
echo "with containerized services managed by Ansible and rootless Podman."
echo

# ============================================================================
# Step 1: Install prerequisites
# ============================================================================
info "Step 1/7: Installing prerequisites..."

sudo dnf install -y podman git python3-pyyaml pipx &>/dev/null \
    || sudo dnf install -y podman git python3-pyyaml pipx

# Install ansible-core via pipx for the latest version (Fedora repos
# may ship an older version with compatibility issues).
if ! command -v ansible-playbook &>/dev/null; then
    pipx install ansible-core &>/dev/null
    # Inject the full ansible package for built-in collections
    pipx inject ansible-core ansible &>/dev/null
fi

ok "Prerequisites installed."

# ============================================================================
# Step 2: Clone the repo
# ============================================================================
INSTALL_DIR="$HOME/home-server"

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
    git clone https://github.com/luckynrslevin/home-server.git "$INSTALL_DIR" 2>/dev/null
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
# Step 4: Configure vault password
# ============================================================================
info "Step 4/7: Setting up Ansible Vault..."

VAULT_PW_FILE="$HOME/.vaultpw"

if [[ -f "$VAULT_PW_FILE" ]]; then
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
EOF

# ============================================================================
# Step 5: Gather host configuration
# ============================================================================
info "Step 5/7: Configuring your server..."

echo
echo -e "${BOLD}--- Network Configuration ---${NC}"
echo

# Detect IP and network automatically
DEFAULT_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
DEFAULT_GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
DEFAULT_NETWORK=$(ip -4 addr show "$DEFAULT_IFACE" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
DEFAULT_HOSTNAME=$(hostname -s 2>/dev/null)
DEFAULT_USER=$(whoami)

ask "Server IP address [$DEFAULT_IP]:"
read -r SERVER_IP
SERVER_IP=${SERVER_IP:-$DEFAULT_IP}

ask "Server hostname [$DEFAULT_HOSTNAME]:"
read -r SERVER_HOSTNAME
SERVER_HOSTNAME=${SERVER_HOSTNAME:-$DEFAULT_HOSTNAME}

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

echo
echo -e "${BOLD}--- Service Selection ---${NC}"
echo
echo "Choose which services to deploy. You can always add more later"
echo "by running individual playbooks."
echo

declare -A SERVICES
SERVICES=(
    [caddy]="Web server (serves the dashboard) — recommended"
    [dashboard]="Status dashboard showing all services — recommended"
    [pihole]="Pi-hole DNS ad-blocker"
    [syncthing]="Syncthing file synchronization"
    [samba]="Samba file sharing (SMB)"
    [shairportsync]="Shairport-sync AirPlay audio receiver (needs audio device)"
    [jukebox]="Lyrion Music Server + Squeezelite player"
    [entephoto]="Ente Photos (self-hosted photo storage)"
    [paperless-ngx]="Paperless-NGX document management (OCR + search)"
)

# Recommended order for deployment
SERVICE_ORDER=(caddy dashboard pihole syncthing samba shairportsync jukebox entephoto paperless-ngx)
SELECTED_SERVICES=()

for svc in "${SERVICE_ORDER[@]}"; do
    desc="${SERVICES[$svc]}"
    if [[ "$svc" == "caddy" || "$svc" == "dashboard" ]]; then
        ask "Deploy $svc? ($desc) [Y/n]:"
    else
        ask "Deploy $svc? ($desc) [y/N]:"
    fi
    read -r answer
    if [[ "$svc" == "caddy" || "$svc" == "dashboard" ]]; then
        [[ ! "$answer" =~ ^[Nn]$ ]] && SELECTED_SERVICES+=("$svc")
    else
        [[ "$answer" =~ ^[Yy]$ ]] && SELECTED_SERVICES+=("$svc")
    fi
done

echo
ok "Selected services: ${SELECTED_SERVICES[*]}"

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
mkdir -p inventory/host_vars/homeserver

cat > inventory/hosts.yml << EOF
all:
  children:
    homeservers:
      hosts:
        homeserver:
          ansible_host: 127.0.0.1
          ansible_connection: local
          ansible_host_name: $SERVER_HOSTNAME
          ansible_user: $SERVER_USER
EOF

ok "Generated inventory/hosts.yml"

# --- Generate host_vars ---
info "Generating secrets (this takes a moment)..."

# Generate all secrets
PIHOLE_PW=$(openssl rand -base64 24)
ENTEPHOTO_DB_PW=$(openssl rand -base64 24)
ENTEPHOTO_MINIO_PW=$(openssl rand -base64 24)
ENTEPHOTO_ENC_KEY=$(openssl rand -base64 32)
ENTEPHOTO_HASH_KEY=$(openssl rand -base64 64)
ENTEPHOTO_JWT=$(openssl rand -hex 32)
PAPERLESS_SECRET_KEY=$(openssl rand -hex 32)
PAPERLESS_DB_PW=$(openssl rand -base64 24)
PAPERLESS_ADMIN_PW=$(openssl rand -base64 24)

# Generate a stable, locally-administered unicast MAC for the
# squeezelite player. First octet 0x02 sets the locally-administered
# bit (b1=1) and clears the multicast bit (b0=0). LMS uses the MAC as
# the player's identity, so a stable value keeps the player recognized
# across redeploys and clean re-installs.
JUKEBOX_MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g;s/:$//')"

# Build the host_vars file
{
cat << YAML
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
  jukebox:
    uid: 1006
    gid: 1006
  entephoto:
    uid: 1008
    gid: 1008
  paperless:
    uid: 1007
    gid: 1007
  samba:
    uid: 1010
    gid: 1010
  webproxy:
    uid: 1011
    gid: 1011
##################################################################################################

### Samba
samba_timezone: "$TIMEZONE"

### Pi-hole
pihole_local_network: "$LAN_CIDR"
pihole_local_router: "$LAN_GATEWAY"
YAML

echo ""
vault_encrypt "$PIHOLE_PW" "pihole_api_password"
echo ""
echo "### Jukebox"
echo "jukebox_squeezelite_mac: \"$JUKEBOX_MAC\""
echo ""
echo "### Ente Photos"
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
vault_encrypt "$PAPERLESS_SECRET_KEY" "paperless_secret_key"
echo ""
vault_encrypt "$PAPERLESS_DB_PW" "paperless_db_password"
echo ""
vault_encrypt "$PAPERLESS_ADMIN_PW" "paperless_admin_password"
echo "##################################################################################################"
} > inventory/host_vars/homeserver/main.yml

ok "Generated inventory/host_vars/homeserver/main.yml (with vault-encrypted secrets)"

# --- Generate dashboard config ---
# Only include services that were actually selected for deployment, so
# the dashboard doesn't display stale "Stopped" rows for un-deployed
# services.
is_selected() {
    local needle=$1
    for s in "${SELECTED_SERVICES[@]}"; do
        [[ "$s" == "$needle" ]] && return 0
    done
    return 1
}

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
        url: https://${SERVER_IP}:8443/admin
    volumes:
      - systemd-pihole-etc
      - systemd-pihole-dnsmasq

EOF
fi

if is_selected samba; then
cat << EOF
  - name: Samba
    user: samba
    uid: 1010
    service: samba
    volumes:
      - systemd-samba-data

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
        url: https://${SERVER_IP}:8384
    volumes:
      - systemd-syncthing

EOF
fi

if is_selected jukebox; then
cat << EOF
  - name: Jukebox
    user: jukebox
    uid: 1006
    service: jukebox-pod
    urls:
      - label: Web UI
        url: http://${SERVER_IP}:9100
    volumes:
      - jukebox-server-config
      - jukebox-server-music
      - jukebox-server-playlist

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
        url: http://${SERVER_IP}:3000
      - label: API
        url: http://${SERVER_IP}:8080/ping
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
        url: http://${SERVER_IP}:8000
    volumes:
      - paperless-db-data
      - paperless-media
      - paperless-data

EOF
fi
} > inventory/host_vars/homeserver/dashboard-config.yaml

ok "Generated inventory/host_vars/homeserver/dashboard-config.yaml"

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
    echo "  $INSTALL_DIR/inventory/host_vars/homeserver/"
    echo
    echo "Deploy manually anytime with:"
    echo "  cd $INSTALL_DIR"
    echo "  ansible-playbook playbooks/site.yml --limit homeserver"
    exit 0
fi

echo

info "Deploying selected services..."
ansible-playbook playbooks/site.yml --limit homeserver
DEPLOY_EXIT=$?

if [[ $DEPLOY_EXIT -ne 0 ]]; then
    warn "Some services may have failed. Check the output above."
    echo "Re-run with: cd $INSTALL_DIR && ansible-playbook playbooks/site.yml --limit homeserver"
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
echo "Your home server is now running at: http://${SERVER_IP}"
echo
echo "Useful commands:"
echo "  cd $INSTALL_DIR"
echo "  ansible-playbook playbooks/<service>.yml --limit homeserver  # deploy a service"
echo "  podman ps                                                     # list containers"
echo
echo "Configuration files:"
echo "  $INSTALL_DIR/inventory/host_vars/homeserver/main.yml"
echo "  $INSTALL_DIR/inventory/host_vars/homeserver/dashboard-config.yaml"
echo "  $VAULT_PW_FILE  (vault password — BACK THIS UP!)"
echo
echo "Container images auto-update daily via podman-auto-update.timer."
echo "See the Quickstart.md for more details."
echo
