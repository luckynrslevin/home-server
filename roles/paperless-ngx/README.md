# paperless-ngx

[Paperless-ngx](https://docs.paperless-ngx.com) — document management
system with OCR, full-text search, tagging, and a web UI. Deployed as
a rootless Podman pod with Postgres, Redis, the Paperless-ngx app, and
Gotenberg (document conversion).

## Container images

| Container | Image |
|-----------|-------|
| paperless-db | `docker.io/library/postgres:16` |
| paperless-redis | `docker.io/library/redis:7-alpine` |
| paperless-ngx | `ghcr.io/paperless-ngx/paperless-ngx:latest` |
| paperless-gotenberg | `docker.io/gotenberg/gotenberg:8` |

## Service user

`paperless` (UID/GID 1007) — rootless.

## Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `paperless_admin_user` | `admin` | Admin account created on first startup. |
| `paperless_time_zone` | `Europe/Berlin` | Timezone for timestamps and scheduler. |
| `paperless_ocr_language` | `deu+eng` | OCR languages (ISO 639-2, `+` separated). |
| `paperless_enable_gotenberg` | `true` | Enable Gotenberg for Office doc conversion. |

## Secrets

All three must be vaulted in your host_vars:

```bash
openssl rand -hex 32 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'paperless_secret_key'

openssl rand -base64 24 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'paperless_db_password'

openssl rand -base64 24 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'paperless_admin_password'
```

Inspect a stored secret:

```bash
ansible -i inventory/hosts.yml homeserver -m debug -a "var=paperless_secret_key"
```

## Firewall ports

- **8000/tcp** — Web UI and API.

## Endpoints

- Web UI: `http://<server-ip>:8000`

## Volumes

- `paperless-db-data` — PostgreSQL data files.
- `paperless-redis-data` — Redis persistence.
- `paperless-media` — uploaded/processed documents (originals + archive).
- `paperless-data` — search index, thumbnails, classification model.
- `paperless-export` — document exports.
- `paperless-consume` — incoming documents (drop files here for auto-import).

## Deployment

```bash
ansible-playbook playbooks/paperless-ngx.yml --limit homeserver
```

After deployment, open `http://<server-ip>:8000` and log in with the
admin credentials from your host_vars. The admin account is only
created on first startup — subsequent deploys don't overwrite it.

## Document ingestion

Drop files into the consume volume for automatic import:

```bash
# Find the consume volume's host path
sudo -u paperless podman volume inspect paperless-consume \
    --format '{{.Mountpoint}}'

# Copy a document into it
sudo cp invoice.pdf <mountpoint>/
```

Or upload via the web UI (drag-and-drop).

## Tips and troubleshooting

### OCR not working for a language

Install additional Tesseract language packs by setting
`paperless_ocr_language` to include the desired language codes.
Common: `deu` (German), `eng` (English), `fra` (French),
`ita` (Italian). The container downloads language data on first use.

### Gotenberg disabled

If you don't need Office document conversion, set
`paperless_enable_gotenberg: false` in your host_vars. The Gotenberg
container won't be started, saving ~200 MB of RAM.
