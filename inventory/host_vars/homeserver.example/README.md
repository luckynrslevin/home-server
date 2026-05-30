# `host_vars/<hostname>/` — split layout

Each file in this directory mirrors what `homeserver.sh install` writes
into the private overlay on a real host. To kick-tire a deployment by
hand (without running install):

```bash
cp -r inventory/host_vars/homeserver.example inventory/host_vars/<yourhost>
# Then edit each *.yml — remove the `.example` suffix is implicit:
# every file in the dir ending in `.yml` is loaded by ansible.
```

## Layout

| File                    | Owner             | What's in it |
|-------------------------|-------------------|--------------|
| `00-services.yml`       | tool              | `platform_services` + `apps` lists, `os_base_hostname`, `home_server_release` |
| `01-linux-users.yml`    | tool              | `my_linux_users` dict — aggregated from each selected role's `meta/install.yml` `side_effects.my_linux_users` with operator overrides layered on top |
| `10-caddy.yml`          | tool              | `caddy_domain`, `caddy_acme_*`, `caddy_reverse_proxy_services` (aggregated) |
| `20-extras.yml`         | **operator**      | Anything the tool doesn't write itself — Pi-hole DNS records, Jellyfin NFS mounts, MA internal hosts, custom backup-snapshot SSH config, extra Caddy entries |
| `30-smtp.yml`           | tool              | SMTP relay (optional whole-file — omit to disable email) |
| `40-pihole.yml`         | tool              | Pi-hole core (subnet, gateway, API password) |
| `50-backup.yml`         | tool              | Backup NAS coords + schedule |
| `60-tailscale.yml`      | tool              | Tailscale (optional) |
| `apps/<name>.yml`       | tool              | One file per app — secrets + URLs for that app only |

"Tool" files carry a `# DO NOT EDIT — managed by homeserver.sh` header
because `homeserver.sh install` regenerates them on every run. Move
your overrides to `20-extras.yml` (operator-owned, never touched).

## Quick tips

- **Secrets**: encrypt with `ansible-vault encrypt_string '<value>' --name '<var_name>'`
- **Generate password / key material**:
  - `openssl rand -base64 24` — passwords / DB creds
  - `openssl rand -base64 32` — entephoto encryption key
  - `openssl rand -base64 64` — entephoto hash key
  - `openssl rand -hex 32` — JWT / Django secret keys
- **Skip what you don't deploy**: drop a service from `apps:` in
  `00-services.yml` and the matching `apps/<name>.yml` file → that
  service is no longer rendered or deployed.
- **Re-prompt instead of editing**: most operators never touch this
  dir by hand — `homeserver.sh install` walks every value with the
  current inventory as the default, so `Enter Enter Enter` through a
  re-install reconfigures cleanly.
