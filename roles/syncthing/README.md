# syncthing

[Syncthing](https://syncthing.net) — continuous file synchronization
between your devices. Web UI on port 8384.

## Container image

`ghcr.io/syncthing/syncthing:2`

## Service user

`syncthg` (UID/GID 1003) — rootless. Note the abbreviated username
(8-char limit on legacy systems).

## Variables

| Variable                     | Default                                                            | Purpose                                                              |
|------------------------------|--------------------------------------------------------------------|----------------------------------------------------------------------|
| `syncthing_gui_port`         | `8384`                                                             | Web UI HTTPS port.                                                   |
| `syncthing_listen_port`      | `22000`                                                            | Sync protocol port (peer-to-peer).                                   |
| `syncthing_discovery_port`   | `21027`                                                            | Local discovery (UDP broadcast).                                     |
| `syncthing_restore_config`   | `false`                                                            | If `true`, restore device identity from backup files (see below).    |
| `syncthing_config_path`      | `{{ inventory_dir }}/host_vars/{{ inventory_hostname }}/syncthing` | Where the role looks for restore files.                              |

## Secrets

| Variable                       | Purpose                                                                |
|--------------------------------|------------------------------------------------------------------------|
| `syncthing_gui_password_hash`  | Bcrypt hash for the web UI login (matches `<password>` in config.xml). |
| `syncthing_api_key`            | API key from `<apikey>` in config.xml — needed for tools.              |

For an existing installation, copy both values out of the previous
`config.xml`. For a new installation:

```bash
# Hash a chosen password (or pull from a running syncthing's config.xml)
openssl passwd -apr1 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'syncthing_gui_password_hash'

# Random API key
openssl rand -hex 32 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'syncthing_api_key'
```

Inspect a stored secret:

```bash
ansible -i inventory/hosts.yml homeserver -m debug -a "var=syncthing_gui_password_hash"
ansible -i inventory/hosts.yml homeserver -m debug -a "var=syncthing_api_key"
```

## Firewall ports

- **8384/tcp** — GUI
- **22000/tcp** + **22000/udp** — sync protocol
- **21027/udp** — local discovery

## Endpoints

- Web UI: `https://<server-ip>:8384`

## Volumes

- `systemd-syncthing-config` — `config.xml`, device certificate +
  private key, sync index database.
- `systemd-syncthing-data` — the synced folders themselves.

Splitting these means the data volume can be backed up with `rsync`
(big, mostly-static) while the config is tarred (small, hot).

## Deployment

```bash
ansible-playbook playbooks/syncthing.yml --limit homeserver
```

## Restoring a previous Syncthing identity

To preserve a host's device ID across re-installs, drop these files
into `inventory/host_vars/<host>/syncthing/` (in your **private**
repo):

```
config.xml.j2     # config template — Jinja-render placeholders for
                  # syncthing_gui_password_hash + syncthing_api_key
cert.pem          # device certificate
key.pem           # device private key
```

Then set `syncthing_restore_config: true` in the host's main.yml and
re-run the playbook. The post-install task stages the files into the
config volume, then runs `podman unshare chown` to fix ownership for
the rootless UID mapping.
