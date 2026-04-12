# Quickstart Guide

Step-by-step instructions to deploy your own home server using this project.

## Prerequisites

- A dedicated machine (mini PC, old laptop, NUC) or VM for the server
- A workstation (Mac, Linux, Windows with WSL) to run Ansible from
- Basic familiarity with the Linux command line and SSH

### On your workstation

Install Ansible and a few tools:

```bash
# macOS
brew install ansible

# Fedora / RHEL
sudo dnf install ansible-core

# Ubuntu / Debian
sudo apt install ansible
```

You also need `git` and an SSH key pair (`ssh-keygen -t ed25519` if you
don't have one).

---

## 1. Install the operating system

Flash **Fedora Server** onto a USB stick and boot your server from it.
This project includes a kickstart file that automates the OS
installation.

### Using the kickstart file

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

### Manual install

If you prefer not to use kickstart, install Fedora Server manually and
ensure:
- `podman` is installed (`sudo dnf install podman`)
- Your user has passwordless sudo (`echo "myuser ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/myuser`)
- SSH key authentication works

---

## 2. Clone the repositories

On your **workstation** (not the server):

```bash
# Public repo (roles, playbooks, examples)
git clone https://github.com/luckynrslevin/home-server.git
cd home-server

# Private repo (your secrets, IPs, host-specific config)
# Create your own private repo on GitHub, then clone it alongside:
cd ..
mkdir home-server-private
cd home-server-private
git init
```

The private repo keeps your passwords, API keys, and host-specific
configuration out of the public repo.

---

## 3. Install the Ansible Galaxy dependency

```bash
cd home-server
ansible-galaxy install -r roles/requirements.yml
```

This installs `luckynrslevin.podman_quadlet`, the role that manages
rootless Podman containers via systemd Quadlets.

---

## 4. Set up your inventory

### hosts.yml

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
          ansible_host: 192.168.1.100    # Your server's IP
          ansible_host_name: myserver    # Hostname
          ansible_user: myuser           # SSH user
          ansible_ssh_private_key_file: ~/.ssh/id_ed25519
```

### Host variables

Create a directory for your host's configuration:

```bash
mkdir -p inventory/host_vars/homeserver
```

Copy the example as a starting point:

```bash
cp inventory/host_vars/homeserver.yml.example \
   inventory/host_vars/homeserver/main.yml
```

Edit `inventory/host_vars/homeserver/main.yml` and fill in:

- **Linux users** (UIDs/GIDs) for each service
- **Service-specific settings** (hostnames, network ranges, ports)
- **Vault-encrypted secrets** (see next step)

---

## 5. Create vault-encrypted secrets

Create a vault password file:

```bash
openssl rand -base64 32 > vault.pw
chmod 600 vault.pw
```

Generate and encrypt each secret. Example for Pi-hole:

```bash
openssl rand -base64 24 | \
  ansible-vault encrypt_string \
    --vault-password-file vault.pw \
    --stdin-name 'pihole_api_password'
```

Paste the output into `inventory/host_vars/homeserver/main.yml`.
Repeat for each service's secrets (see the comments in the example
file for which secrets each service needs).

---

## 6. Create host-specific data files

Some roles expect data files alongside your host variables:

### Dashboard config

```bash
cp roles/dashboard/files/dashboard-config.yaml.example \
   inventory/host_vars/homeserver/dashboard-config.yaml
```

Edit it with your server's IP addresses in the service URLs.

### Syncthing identity (optional)

Only needed if restoring a previous Syncthing installation. Create:

```
inventory/host_vars/homeserver/syncthing/
  config.xml.j2    # Syncthing config template
  cert.pem         # Device certificate
  key.pem          # Device private key
```

And set `syncthing_restore_config: true` in your host vars.

---

## 7. Deploy services

Verify connectivity:

```bash
ansible all -m ping
```

Deploy services one at a time:

```bash
# DNS ad-blocker
ansible-playbook playbooks/pihole.yml --limit homeserver

# File sync
ansible-playbook playbooks/syncthing.yml --limit homeserver

# File sharing
ansible-playbook playbooks/samba.yml --limit homeserver

# Web dashboard (shows service status)
ansible-playbook playbooks/caddy.yml --limit homeserver
ansible-playbook playbooks/dashboard.yml --limit homeserver

# AirPlay audio receiver (requires /dev/snd)
ansible-playbook playbooks/shairportsync.yml --limit homeserver

# Music server
ansible-playbook playbooks/jukebox.yml --limit homeserver

# Photo storage (self-hosted Ente)
ansible-playbook playbooks/entephoto.yml --limit homeserver

# VPN server
ansible-playbook playbooks/wireguard.yml --limit homeserver

# Backup (requires NFS-accessible NAS)
ansible-playbook playbooks/backup-deploy.yml --limit homeserver
```

You don't need to deploy all services. Pick the ones you want.

---

## 8. Verify

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
home-server/                         # Public repo (this repo)
  !Linux-kickstart/ks.cfg            # OS install automation
  ansible.cfg                        # Ansible configuration
  playbooks/                         # One playbook per service
  roles/                             # One role per service
    <role>/
      defaults/main.yml              # Default variables (generic)
      tasks/main.yml                 # Deployment logic
      files/quadlets/                # Podman Quadlet unit files
      templates/                     # Jinja2 templates
  inventory/
    hosts.yml.example                # Example inventory
    host_vars/
      homeserver.yml.example         # Example host variables
      homeserver/                    # Symlink to private repo (local)

home-server-private/                 # Your private repo
  vault.pw                           # Vault password (never commit to public)
  inventory/
    hosts.yml                        # Real inventory with IPs
    host_vars/
      homeserver/                    # Per-host directory
        main.yml                     # Variables + vault-encrypted secrets
        dashboard-config.yaml        # Dashboard service list with real IPs
        syncthing/                   # Syncthing identity files (optional)
```

---

## Adding a test server

To test changes before deploying to production, add a second host:

1. Add it to `inventory/hosts.yml` under the `homeservers` group
2. Create `inventory/host_vars/<testhost>/main.yml` with its own
   config and secrets
3. Deploy with `--limit <testhost>`:
   ```bash
   ansible-playbook playbooks/syncthing.yml --limit homeserver-test
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

## Backup and restore

The backup role writes to NFS shares on a NAS. Configure
`backup_nas_hostname`, `backup_nas_ip`, and `backup_nas_volume` in
your host vars, then:

```bash
ansible-playbook playbooks/backup-deploy.yml --limit homeserver
```

The backup runs nightly at 02:00 via a systemd timer. It uses:
- `podman volume export` (tar) for small config volumes
- `rsync` for large data volumes
- `pg_dump` for PostgreSQL databases

To restore: re-run the service's playbook (recreates the container),
then import the backup volume with `podman volume import`.
