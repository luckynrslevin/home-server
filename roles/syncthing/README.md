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

**Fresh install: none.** Syncthing generates its own device identity
on first start; set the admin password via the web UI on first
visit at `https://<server-ip>:8384`.

Two secrets become relevant only when you [restore a previous
identity](#restoring-a-previous-syncthing-identity):

| Variable                       | Purpose                                                                          |
|--------------------------------|----------------------------------------------------------------------------------|
| `syncthing_gui_password_hash`  | Bcrypt hash rendered into `config.xml.j2` under `<password>`.                    |
| `syncthing_api_key`            | API key rendered into `config.xml.j2` under `<apikey>`.                          |

Copy both values out of the `config.xml` from the installation
you're restoring (the role re-renders that file from your saved
`config.xml.j2` template, which needs these substitutions). To
inspect a stored value:

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

To preserve a host's device ID, GUI auth, and API key across
re-installs, keep an identity bundle under
`inventory/host_vars/<hostname>/syncthing/` in your **private** repo:

```
config.xml.j2     # Jinja template of the previous config.xml with
                  # {{ syncthing_gui_password_hash }} and
                  # {{ syncthing_api_key }} placeholders in place of
                  # the literal <password> and <apikey> values
cert.pem          # device certificate (plain file)
key.pem           # device private key (plain file)
```

Then in the same host's `main.yml`:

```yaml
syncthing_restore_config: true
syncthing_gui_password_hash: !vault | ...   # matches config.xml.j2
syncthing_api_key: !vault | ...             # matches config.xml.j2
```

Re-run the playbook. The post-install task:
1. Stops the container.
2. Renders `config.xml.j2` (substituting the two vaulted secrets) and
   copies `cert.pem`/`key.pem` into the config volume.
3. Fixes ownership via `podman unshare chown` (rootless UID mapping).
4. Restarts the container — it now comes up with the previous
   device ID and credentials.

Fresh installs leave `syncthing_restore_config` at its `false` default
and skip the block entirely.
