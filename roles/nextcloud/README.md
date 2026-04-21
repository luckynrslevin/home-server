# nextcloud

[Nextcloud](https://nextcloud.com) — self-hosted personal cloud for
file sync, calendar, contacts, and collaboration. Deployed as a
rootless Podman pod with PostgreSQL, Redis, and a cron container for
background jobs.

## Container images

| Container | Image |
|-----------|-------|
| nextcloud | `docker.io/library/nextcloud:latest` |
| nextcloud-db | `docker.io/library/postgres:16` |
| nextcloud-redis | `docker.io/library/redis:7-alpine` |
| nextcloud-cron | `docker.io/library/nextcloud:latest` (cron entrypoint) |

## Service user

`nextcloud` (UID/GID 1013) — rootless.

## Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `nextcloud_admin_user` | `admin` | Admin account created on first startup. |
| `nextcloud_time_zone` | `Europe/Berlin` | Timezone. |
| `nextcloud_trusted_domains` | `localhost` | Hostnames Nextcloud accepts (space-separated). Must include reverse proxy subdomain. |
| `nextcloud_max_upload_size` | `16G` | Maximum upload size (PHP limit). |

## Secrets

```bash
openssl rand -base64 24 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'nextcloud_db_password'

openssl rand -base64 24 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'nextcloud_admin_password'
```

Inspect:

```bash
ansible -i inventory/hosts.yml homeserver -m debug -a "var=nextcloud_db_password"
```

## Firewall ports

- **8080/tcp** — Web UI (HTTP, behind Caddy reverse proxy).

## Endpoints

- Web UI: `http://<server-ip>:8080`
- With reverse proxy: `https://nextcloud.<caddy_domain>`

## Volumes

- `nextcloud-config` — PHP app, installed apps, settings.
- `nextcloud-data` — user files (documents, photos, etc.).
- `nextcloud-db-data` — PostgreSQL data files.
- `nextcloud-redis-data` — Redis persistence.

## Deployment

```bash
ansible-playbook playbooks/nextcloud.yml --limit homeserver
```

First startup takes several minutes (database migrations + app
installation). After deployment, open `http://<server-ip>:8080` —
the admin account is created automatically from the vault secrets.

### Trusted domains

When using the Caddy reverse proxy, add the subdomain to
`nextcloud_trusted_domains` in your host_vars:

```yaml
nextcloud_trusted_domains: "localhost nextcloud.eddie.lan"
```

Without this, Nextcloud will reject requests from the proxy with
"Access through untrusted domain".

## Background jobs

The `nextcloud-cron` container runs `/cron.sh` which executes
Nextcloud's background tasks (file scanning, notifications, cleanup)
every 5 minutes. No host-level cron configuration needed.

## Tips and troubleshooting

### "Access through untrusted domain"

Add the domain to `nextcloud_trusted_domains` and re-deploy. Or
fix inside the container:

```bash
sudo -u nextcloud podman exec -u www-data nextcloud \
    php occ config:system:set trusted_domains 1 --value=nextcloud.eddie.lan
```

### Maintenance mode

Enable/disable via `occ`:

```bash
sudo -u nextcloud podman exec -u www-data nextcloud \
    php occ maintenance:mode --on
```
