# nextcloud

[Nextcloud](https://nextcloud.com/) — files, contacts, and (via the
built-in OpenID Connect Identity Provider app) household-wide SSO for
other services in this stack. Deployed as a rootless Podman pod with
Apache+PHP, Postgres, and Redis.

## Container images

| Container | Image |
|-----------|-------|
| nextcloud-server | `docker.io/library/nextcloud:apache` |
| nextcloud-postgres | `public.ecr.aws/docker/library/postgres:16` |
| nextcloud-redis | `public.ecr.aws/docker/library/redis:7-alpine` |

## Service user

`nextcloud` (UID/GID 1015) — rootless.

## Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `nextcloud_image` | `docker.io/library/nextcloud:apache` | Apache+PHP single-container variant. |
| `nextcloud_listen_port` | `8090` | Internal port on the host that Caddy reverse-proxies. |
| `nextcloud_admin_user` | `ncadmin` | Admin account auto-created on first start. |
| `nextcloud_admin_password` | (required, vault) | Admin password — must be set in inventory. |
| `nextcloud_db_user` | `ncuser` | Postgres user. |
| `nextcloud_db_name` | `nextcloud` | Postgres database. |
| `nextcloud_db_password` | (required, vault) | Postgres password — must be set in inventory. |
| `nextcloud_subdomain` | `cloud` | Subdomain Caddy serves Nextcloud at (`<sub>.<caddy_domain>`). |

The role asserts both passwords are non-empty at the top of
`tasks/main.yml`; no silent install with default credentials.

## Reverse-proxy entry

Add this to `caddy_reverse_proxy_services` in your host_vars:

```yaml
- { subdomain: cloud, port: 8090 }
```

## SMTP

Project-level SMTP relay vars (see [`docs/SMTP-Setup.md`](../../docs/SMTP-Setup.md))
are picked up automatically. When `smtp_host` is set, Nextcloud's
`SMTP_*` env vars get rendered into the container quadlet so password
resets, share notifications, and admin-test mails work out of the box.

## Secrets

| Variable | Purpose |
|---|---|
| `nextcloud_admin_password` | Admin login. Vault-encrypt. |
| `nextcloud_db_password` | Postgres password. Vault-encrypt. |

Generate and vault:

```bash
openssl rand -base64 24 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'nextcloud_admin_password'

openssl rand -base64 24 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'nextcloud_db_password'
```

## Endpoints

- Web UI: `https://<nextcloud_subdomain>.<caddy_domain>/`
- WebDAV: `https://<nextcloud_subdomain>.<caddy_domain>/remote.php/dav/`

## Volumes

- `nextcloud-postgres-data` — Postgres data files. (`pgdump` backup.)
- `nextcloud-data` — user files (the big one, `/var/www/html/data`).
  Backed up via `rsync` to NAS share `backup-nextcloud`.
- `nextcloud-config` — `config.php` + installed apps' settings.
  (`tar` backup.)
- `nextcloud-redis-data` — Redis AOF persistence (memcache + file
  locking state). Not backed up — recoverable from cold start.
- `nextcloud-html` — Nextcloud PHP source. Image-managed, not backed up.

## Deployment

```bash
ansible-playbook playbooks/nextcloud.yml --limit <host>
```

The role:

1. Asserts admin + DB passwords are set.
2. Creates the `nextcloud` rootless user with linger.
3. Deploys the pod (apache + postgres + redis) via the Galaxy
   `luckynrslevin.podman_quadlet` role.
4. Waits for `/status.php` to report `installed:true` (DB migrations
   on first boot can take ~60 s).
5. Configures Caddy (127.0.0.1) as a trusted reverse proxy.
6. Installs and enables the **OpenID Connect Identity Provider** app
   (`oidc_provider`) so other apps can OIDC against Nextcloud.
7. Installs the **Contacts** app.

## Bootstrapping OIDC for other apps

After the role finishes, log into Nextcloud as the admin and:

1. **Settings → Administration → Security → OpenID Connect** (or
   "OAuth 2.0" depending on the app version).
2. Click **Add client**.
3. Name: e.g. `Paperless`.
4. Redirect URI: e.g. `https://paperless.<caddy_domain>/accounts/oidc/<provider_id>/login/callback/` —
   verify the exact form against the consuming app's documentation.
5. Save. Copy the generated **client ID** and **client secret**.
6. Paste them into the consuming role's inventory vars (e.g.
   `paperless_oidc_client_id` / `paperless_oidc_client_secret`).
7. Re-deploy the consuming app.

## Restore

The generic restore re-imports the tar/rsync/pgdump artifacts and
restarts the pod. After that, `tasks/restore.yml` runs
`occ maintenance:repair --include-expensive` to re-validate the file
index against the on-disk files.

```bash
ansible-playbook playbooks/restore.yml --limit <host> --tags nextcloud
```

## Cross-role dependencies

Pairs with [caddy](../caddy/README.md) — the reverse proxy fronts the
Nextcloud Apache container at `https://<sub>.<caddy_domain>`.

Source of OIDC identity for any consuming role (today: paperless-ngx
when `paperless_oidc_enabled: true`; future: jellyfin via plugin,
vaultwarden, etc.).
