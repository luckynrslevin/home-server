# syncthing

[Syncthing](https://syncthing.net) — continuous file synchronization
between your devices. Web UI on port 8384.

## Container image

`ghcr.io/syncthing/syncthing:2`

## Service user

`syncthg` (UID/GID 1003) — rootless. Note the abbreviated username
(8-char limit on legacy systems).

## Variables

| Variable                     | Default | Purpose                                  |
|------------------------------|---------|------------------------------------------|
| `syncthing_gui_port`         | `8384`  | Web UI HTTPS port.                       |
| `syncthing_listen_port`      | `22000` | Sync protocol port (peer-to-peer).       |
| `syncthing_discovery_port`   | `21027` | Local discovery (UDP broadcast).         |

## Secrets

None. Syncthing generates its own device identity and API key on
first start; set the admin password via the web UI on first visit
at `https://<server-ip>:8384`.

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

Use the standard volume-restore flow — same as every other role.
The [backup role](../backup/README.md) tars
`systemd-syncthing-config` nightly (≈35 MB); that archive contains
the full `config.xml`, `cert.pem`, `key.pem` and the sync index
database, which is everything needed to come back as the same
Syncthing device.

```bash
# 1. Deploy the role (creates an empty config volume)
ansible-playbook playbooks/syncthing.yml --limit homeserver

# 2. Stop the container so the volume is safe to overwrite
sudo -u syncthg XDG_RUNTIME_DIR=/run/user/1003 \
    systemctl --user stop syncthing

# 3. Overwrite the config volume with the backup tarball
sudo -u syncthg podman volume rm systemd-syncthing-config
sudo -u syncthg podman volume create systemd-syncthing-config
gunzip -c /mnt/backup/tar/systemd-syncthing-config/<snapshot>.tar.gz \
    | sudo -u syncthg podman volume import systemd-syncthing-config -

# 4. Start the container — same device ID, same GUI password, same API key
sudo -u syncthg XDG_RUNTIME_DIR=/run/user/1003 \
    systemctl --user start syncthing
```

The synced data itself is mirrored nightly via rsync to the NAS
`backup-syncthing` share — restore it back into
`systemd-syncthing-data` the same way the backup role documents,
via `podman unshare rsync`.
