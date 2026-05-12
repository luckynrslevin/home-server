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

echo
echo -e "${BOLD}--- Service Selection ---${NC}"
echo
echo "Choose which services to deploy. You can always add more later"
echo "by running individual playbooks."
echo

declare -A SERVICES
SERVICES=(
    [dashboard]="Status dashboard showing all services — recommended"
    [pihole]="Pi-hole DNS ad-blocker"
    [syncthing]="Syncthing file synchronization"
    [shairportsync]="Shairport-sync AirPlay audio receiver (needs audio device)"
    [entephoto]="Ente Photos (self-hosted photo storage)"
    [paperless-ngx]="Paperless-NGX document management (OCR + search)"
    [jellyfin]="Jellyfin media server (movies, TV, music)"
    [music-assistant]="Music Assistant music server (optional local Squeezelite player on hosts with a USB DAC)"
)

# Caddy is always deployed — it's the mandatory front-door reverse proxy.
SELECTED_SERVICES=(caddy)

# Recommended order for deployment of optional services
SERVICE_ORDER=(dashboard pihole syncthing shairportsync entephoto paperless-ngx jellyfin music-assistant)

for svc in "${SERVICE_ORDER[@]}"; do
    desc="${SERVICES[$svc]}"
    if [[ "$svc" == "dashboard" ]]; then
        ask "Deploy $svc? ($desc) [Y/n]:"
    else
        ask "Deploy $svc? ($desc) [y/N]:"
    fi
    read -r answer
    if [[ "$svc" == "dashboard" ]]; then
        [[ ! "$answer" =~ ^[Nn]$ ]] && SELECTED_SERVICES+=("$svc")
    else
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
ENTEPHOTO_HASH_KEY=$(openssl rand -base64 64 | tr -d '\n')
ENTEPHOTO_JWT=$(openssl rand -hex 32)
PAPERLESS_SECRET_KEY=$(openssl rand -hex 32)
PAPERLESS_DB_PW=$(openssl rand -base64 24)
PAPERLESS_ADMIN_PW=$(openssl rand -base64 24)
JELLYFIN_ADMIN_PW=$(openssl rand -base64 24)

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
echo ""
echo "### Jellyfin"
vault_encrypt "$JELLYFIN_ADMIN_PW" "jellyfin_admin_password"
echo "##################################################################################################"
} > inventory/host_vars/homeserver/main.yml

ok "Generated inventory/host_vars/homeserver/main.yml (with vault-encrypted secrets)"

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
} > inventory/host_vars/homeserver/dashboard-config.yaml

ok "Generated inventory/host_vars/homeserver/dashboard-config.yaml"

# ============================================================================
# Step 6.5: deSEC API — upsert the wildcard A record
# ============================================================================
# Writes `*.<sub>.dedyn.io` and `<sub>.dedyn.io` → SERVER_IP so LAN
# clients (Pi-hole) and roaming Tailscale clients both resolve every
# Caddy subdomain to this host's LAN IP. Caddy then issues a wildcard
# LE cert against deSEC's DNS-01 challenge during the deploy below.
# PATCH on the rrset collection is idempotent — safe to re-run.
info "Step 6.5/7: Writing wildcard A record at deSEC..."
api_body=$(cat <<JSON
[
  {"subname":"","type":"A","ttl":3600,"records":["$SERVER_IP"]},
  {"subname":"*","type":"A","ttl":3600,"records":["$SERVER_IP"]}
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
