# Quickstart Guide

Step-by-step instructions to deploy your own home server using this project.

## Prerequisites

- **Fedora Server** installed on a dedicated machine (mini PC, old laptop,
  NUC) or a VM
- Basic familiarity with the Linux command line and SSH

### Networking requirements

Your server must be a **direct host on your home network** — not behind
an additional NAT layer. If you're using a VM (e.g., UTM, VirtualBox,
Proxmox), configure it with **bridged networking** so it gets its own IP
address from your home router, just like a physical machine.

Services like AirPlay (Shairport-sync), DNS (Pi-hole), and file sharing
(Samba) rely on mDNS/Bonjour discovery and direct LAN connectivity.
These will not work correctly behind a NAT or on a virtual host-only
network.

---

## Quick start (single command)

On a freshly installed Fedora Server, run:

```bash
curl -fsSL https://raw.githubusercontent.com/luckynrslevin/home-server/main/setup.sh \
  -o /tmp/setup.sh && bash /tmp/setup.sh
```

This interactive script will:
1. Install Ansible, Podman, and dependencies
2. Clone this repository
3. Walk you through network configuration and service selection
4. Generate all config files with vault-encrypted secrets
5. Deploy the selected services

The server acts as its own Ansible controller — no separate workstation
needed. After the script finishes, open `http://<server-ip>` to see
your dashboard.

In case you face issues with individual services, see Tips and Tricks section below.

If you prefer more control over the setup, follow the manual steps
below.

---

## Manual setup

### 1. Install the operating system

Flash **Fedora Server** onto a USB stick and boot your server from it.
This project includes a kickstart file that automates the OS
installation.

#### Using the kickstart file

1. Copy `!Linux-kickstart/ks.cfg` and edit it for your hardware:
   - **Network device**: change `enp1s0` to your NIC name
   - **Disk device**: change `nvme0n1` to your disk (e.g., `sda`)
   - **Partition sizes**: adjust to your disk capacity
   - **Hostname**: change `homeserver` to your preferred name
   - **User**: change `myuser` to your username
   - **SSH key**: paste your public key
   - **Timezone**: change `Europe/Berlin` if needed

2. Host the kickstart file on a web server (or USB) and boot Fedora
   with the `inst.ks=` parameter pointing at it.

3. The installer runs unattended: partitions the disk, installs
   packages, configures automatic updates, and reboots.

After reboot, SSH into the server to verify: `ssh myuser@<server-ip>`.

#### Manual install

If you prefer not to use kickstart, install Fedora Server manually and
ensure:
- `podman` is installed (`sudo dnf install podman`)
- Your user has passwordless sudo (`echo "myuser ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/myuser`)
- SSH key authentication works

---

### 2. Clone the repository and install dependencies

SSH into your server and run:

```bash
git clone https://github.com/luckynrslevin/home-server.git
cd home-server

# Install Ansible (via pipx for the latest version)
sudo dnf install -y pipx git python3-pyyaml
pipx install ansible-core
pipx inject ansible-core ansible

# Install the Galaxy role dependency
ansible-galaxy install -r roles/requirements.yml
```

---

### 3. Set up your inventory

#### hosts.yml

Copy the example and fill in your server's details:

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
```

Edit `inventory/hosts.yml`:

```yaml
all:
  children:
    homeservers:
      hosts:
        homeserver:
          ansible_host: 127.0.0.1
          ansible_connection: local
          ansible_host_name: myserver
          ansible_user: myuser
```

#### Host variables

Create a directory for your host's configuration:

```bash
mkdir -p inventory/host_vars/homeserver
cp inventory/host_vars/homeserver.yml.example \
   inventory/host_vars/homeserver/main.yml
```

Edit `inventory/host_vars/homeserver/main.yml` and fill in:

- **`deploy_services`** list — which services to deploy on this host
- **Linux users** (UIDs/GIDs) for each service
- **Service-specific settings** (hostnames, network ranges, ports)
- **Vault-encrypted secrets** (see next step)

---

### 4. Create vault-encrypted secrets

Create a vault password file:

```bash
openssl rand -base64 32 > ~/.vaultpw
chmod 400 ~/.vaultpw
```

Update `ansible.cfg` to point at it:

```ini
[defaults]
vault_password_file = ~/.vaultpw
```

Generate and encrypt each secret. Example for Pi-hole:

```bash
openssl rand -base64 24 | \
  ansible-vault encrypt_string \
    --encrypt-vault-id default \
    --stdin-name 'pihole_api_password'
```

Paste the output into `inventory/host_vars/homeserver/main.yml`.
Repeat for each service's secrets (see the comments in the example
file for which secrets each service needs).

---

### 5. Create host-specific data files

#### Dashboard config

```bash
cp roles/dashboard/files/dashboard-config.yaml.example \
   inventory/host_vars/homeserver/dashboard-config.yaml
```

Edit it with your server's IP addresses in the service URLs.

#### Syncthing identity (optional)

Only needed if restoring a previous Syncthing installation. Create:

```
inventory/host_vars/homeserver/syncthing/
  config.xml.j2    # Syncthing config template
  cert.pem         # Device certificate
  key.pem          # Device private key
```

And set `syncthing_restore_config: true` in your host vars.

---

### 6. Deploy services

Deploy all services declared in your `deploy_services` list:

```bash
ansible-playbook playbooks/site.yml --limit homeserver
```

Or deploy individual services:

```bash
ansible-playbook playbooks/pihole.yml --limit homeserver
ansible-playbook playbooks/syncthing.yml --limit homeserver
```

You don't need to deploy all services. Pick the ones you want.

---

### 7. Verify

Open your browser and go to `http://<server-ip>` to see the dashboard.
It shows each service's status, container image, update availability,
volume sizes, and backup timestamps.

Each service also has its own web UI (where applicable):

| Service | URL |
|---------|-----|
| Pi-hole | `https://<server-ip>:8443/admin` |
| Syncthing | `https://<server-ip>:8384` |
| Jukebox (LMS) | `http://<server-ip>:9100` |
| Ente Photos | `http://<server-ip>:3000` |

---

## Project structure

```
home-server/
  setup.sh                             # Interactive single-command installer
  !Linux-kickstart/ks.cfg              # OS install automation
  ansible.cfg                          # Ansible configuration
  playbooks/
    site.yml                           # Deploy all services for a host
    <service>.yml                      # Deploy a single service
  roles/                               # One role per service
    <role>/
      defaults/main.yml                # Default variables (generic)
      tasks/main.yml                   # Deployment logic
      files/quadlets/                  # Podman Quadlet unit files
      templates/                       # Jinja2 templates
  scripts/
    clean-host.sh                      # Reset a host to clean state
  inventory/
    hosts.yml.example                  # Example inventory
    host_vars/
      homeserver.yml.example           # Example host variables
      homeserver/                      # Per-host directory
        main.yml                       # Variables + vault-encrypted secrets
        dashboard-config.yaml          # Dashboard service list
        syncthing/                     # Syncthing identity files (optional)
```

---

## Adding a test server

To test changes before deploying to production, add a second host:

1. Add it to `inventory/hosts.yml` under the `homeservers` group
2. Create `inventory/host_vars/<testhost>/main.yml` with its own
   config, secrets, and `deploy_services` list
3. Deploy with `--limit`:
   ```bash
   ansible-playbook playbooks/site.yml --limit homeserver-test
   ```

---

## Updating services

Container images auto-update via `podman-auto-update.timer` (runs
daily). The dashboard shows when updates are available.

To re-deploy a role after changing its configuration:

```bash
ansible-playbook playbooks/<service>.yml --limit homeserver
```

---

## Resetting a host

To remove all home-server artifacts and start fresh:

```bash
ssh <host> 'bash -s' < scripts/clean-host.sh
```

Or run directly on the host:

```bash
bash scripts/clean-host.sh
```

This removes all containers, service users, firewall rules, and
deployed configs. It does not remove system packages or your primary
user.

---

## Backup and restore

The backup role writes to NFS shares on a NAS. Configure
`backup_nas_hostname`, `backup_nas_ip`, and `backup_nas_volume` in
your host vars, then:

```bash
ansible-playbook playbooks/backup.yml --limit homeserver
```

The backup runs at the time configured by `backup_time` (default:
02:00) via a systemd timer. It uses:
- `podman volume export` (tar) for small config volumes
- `rsync` for large data volumes
- `pg_dump` for PostgreSQL databases

To restore: re-run the service's playbook (recreates the container),
then import the backup volume with `podman volume import`.

---

## Per-service documentation

Each role has its own README with variables, secrets, firewall
ports, deployment notes, and troubleshooting:

- [backup](../roles/backup/README.md) — nightly NFS backup of every service's volumes
- [caddy](../roles/caddy/README.md) — front-door web server
- [dashboard](../roles/dashboard/README.md) — generated status page
- [entephoto](../roles/entephoto/README.md) — Ente Photos (Postgres + MinIO + Museum + Web)
- [jukebox](../roles/jukebox/README.md) — Lyrion Music Server + Squeezelite
- [os-audio](../roles/os-audio/README.md) — ALSA prerequisites (used by shairportsync, jukebox)
- [pihole](../roles/pihole/README.md) — Pi-hole DNS ad-blocker
- [samba](../roles/samba/README.md) — SMB file share
- [shairportsync](../roles/shairportsync/README.md) — AirPlay receiver (incl. audio debugging)
- [syncthing](../roles/syncthing/README.md) — file sync
- [paperless-ngx](../roles/paperless-ngx/README.md) — document management (OCR + search)
- [jellyfin](../roles/jellyfin/README.md) — media server (movies, TV, music)
