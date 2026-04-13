#!/bin/bash
# ============================================================================
# Clean all home-server artifacts from a host for a fresh start.
#
# Usage (from the Ansible controller):
#   ssh <host> 'bash -s' < scripts/clean-host.sh
#
# Or directly on the host:
#   bash clean-host.sh
#
# This removes:
#   - All rootless and rootful containers, volumes, images
#   - Service users (shairport, syncthg, pihole, jukebox, entephoto,
#     samba, webproxy, wireguard)
#   - Systemd units (dashboard, backup timers)
#   - Deployed scripts and configs
#   - Firewall rules added by the roles
#   - Resolved/modprobe overrides
#   - The cloned repo and vault password (if from setup.sh)
#
# Does NOT remove:
#   - The primary user (ds)
#   - System packages (ansible, podman, etc.)
#   - SSH keys or system configuration
# ============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

info() { echo -e "${GREEN}==>${NC} $*"; }
warn() { echo -e "${RED}==>${NC} $*"; }

if [[ $EUID -eq 0 ]]; then
    warn "Do not run as root. Run as your normal user (with sudo access)."
    exit 1
fi

SERVICE_USERS=(shairport syncthg pihole jukebox entephoto samba webproxy wireguard)

# ---- Stop and remove containers ----
info "Stopping containers and cleaning podman state..."

for user in "${SERVICE_USERS[@]}"; do
    uid=$(id -u "$user" 2>/dev/null) || continue
    echo "  - $user (uid $uid)"
    sudo -u "$user" XDG_RUNTIME_DIR=/run/user/"$uid" \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/"$uid"/bus \
        systemctl --user stop '*' 2>/dev/null || true
    sudo su - "$user" -c 'podman system reset --force' 2>/dev/null || true
    sudo rm -rf "/home/$user/.config/containers" 2>/dev/null || true
done

# Rootful containers (shairport-sync)
sudo podman system reset --force 2>/dev/null || true
sudo rm -rf /etc/containers/systemd 2>/dev/null || true

# ---- Remove service users ----
info "Removing service users..."

for user in "${SERVICE_USERS[@]}"; do
    sudo loginctl disable-linger "$user" 2>/dev/null || true
    sudo killall -u "$user" 2>/dev/null || true
done
sleep 1
for user in "${SERVICE_USERS[@]}"; do
    if id "$user" &>/dev/null; then
        sudo userdel -r "$user" 2>/dev/null && echo "  - Removed $user" || true
        sudo groupdel "$user" 2>/dev/null || true
    fi
done

# ---- Remove systemd units ----
info "Removing systemd units..."

sudo rm -f /etc/systemd/system/home-server-dashboard.*
sudo rm -f /etc/systemd/system/home-server-backup.*
sudo systemctl daemon-reload 2>/dev/null

# ---- Remove deployed scripts and configs ----
info "Removing scripts and configs..."

sudo rm -f /usr/local/bin/home-server-dashboard.py
sudo rm -f /usr/local/bin/home-server-backup.sh
sudo rm -f /etc/home-server-dashboard.yaml
sudo rm -rf /var/www/dashboard
sudo rm -rf /var/lib/home-server-dashboard
sudo rm -f /var/log/home-server-backup.log

# ---- Remove resolved/modprobe overrides ----
info "Removing system overrides..."

sudo rm -f /etc/systemd/resolved.conf.d/pihole.conf
sudo rm -f /etc/modprobe.d/blacklist.conf
sudo rm -f /etc/asound.conf
sudo systemctl restart systemd-resolved 2>/dev/null || true

# ---- Remove firewall rules ----
info "Removing firewall rules..."

for port in $(sudo firewall-cmd --list-ports 2>/dev/null); do
    sudo firewall-cmd --permanent --remove-port="$port" 2>/dev/null || true
done
for fwd in $(sudo firewall-cmd --list-forward-ports 2>/dev/null); do
    sudo firewall-cmd --permanent --remove-forward-port="$fwd" 2>/dev/null || true
done
sudo firewall-cmd --reload 2>/dev/null || true

# ---- Remove setup artifacts ----
info "Removing setup artifacts..."

rm -rf "$HOME/home-server"
rm -f "$HOME/.vaultpw"
rm -f /tmp/home-server-setup.sh

# ---- Verify ----
info "Verifying clean state..."

remaining_users=$(awk -F: '$3 >= 1001 && $3 < 65534 {print $1}' /etc/passwd)
remaining_ports=$(sudo firewall-cmd --list-ports 2>/dev/null)
remaining_fwds=$(sudo firewall-cmd --list-forward-ports 2>/dev/null)

all_clean=true

if [[ -n "$remaining_users" ]]; then
    warn "Remaining users: $remaining_users"
    all_clean=false
fi

if [[ -n "$remaining_ports" ]]; then
    warn "Remaining firewall ports: $remaining_ports"
    all_clean=false
fi

if [[ -n "$remaining_fwds" ]]; then
    warn "Remaining firewall forwards: $remaining_fwds"
    all_clean=false
fi

if [[ -d "$HOME/home-server" ]]; then
    warn "~/home-server still exists"
    all_clean=false
fi

if $all_clean; then
    echo
    info "Host is clean. Ready for a fresh install."
else
    echo
    warn "Some artifacts remain. Check the warnings above."
fi
