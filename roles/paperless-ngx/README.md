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
| paperless-sftp (optional) | `docker.io/atmoz/sftp:latest` — only when `paperless_sftp_ingest_enabled` is true |

## Service user

`paperless` (UID/GID 1007) — rootless.

## Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `paperless_admin_user` | `admin` | Admin account created on first startup. |
| `paperless_time_zone` | `Europe/Berlin` | Timezone for timestamps and scheduler. |
| `paperless_ocr_language` | `deu+eng` | OCR languages (ISO 639-2, `+` separated). |
| `paperless_enable_gotenberg` | `true` | Enable Gotenberg for Office doc conversion. |
| `paperless_sftp_ingest_enabled` | `false` | Deploy the SFTP sidecar so scanners / SFTP clients can drop PDFs straight into the consume volume. See [Scanner SFTP auto-ingest](#scanner-sftp-auto-ingest) below. |
| `paperless_sftp_image` | `docker.io/atmoz/sftp:latest` | Sidecar image — override only if mirroring to GHCR or similar. |
| `paperless_sftp_port` | `2222` | Host TCP port the sidecar publishes. |
| `paperless_sftp_ingest_authorized_keys` | `[]` | List of SSH public-key strings authorised to SFTP as `paperless-scanner`. Typically set from vault. |

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

## Scanner SFTP auto-ingest

Opt-in sidecar that lets an SFTP-capable scanner (or any SFTP client)
drop PDFs straight into the `paperless-consume` volume. Paperless's own
inotify picks them up and ingests — no manual `mv` step, no Samba mover
in between.

The sidecar runs as the same rootless `paperless` host user as the rest
of the stack, so it mounts `paperless-consume.volume` natively; files
written by the scanner look "native" to paperless (UID 1000 inside the
container namespace) and get consumed, classified, and deleted exactly
as if dropped via the web UI.

### Enable

In inventory / host_vars:

```yaml
paperless_sftp_ingest_enabled: true
paperless_sftp_ingest_authorized_keys:
  - "ssh-ed25519 AAAA…host-key-comment scanner@brother"
  # additional keys on additional lines
```

Typical setup is to **vault-encrypt** the `paperless_sftp_ingest_authorized_keys`
list (keys themselves aren't secret, but vaulting keeps inventory uniform
and rotatable). Re-deploy with `ansible-playbook playbooks/paperless-ngx.yml`.

Hard-fails at play time if the flag is on and the key list is empty — no
silent deployment of an unreachable endpoint.

### Scanner-side configuration

| Setting | Value |
|---------|-------|
| Protocol | SFTP |
| Host | your paperless host (e.g. `paperless.eddie.lan` or the IP) |
| Port | `2222` (default `paperless_sftp_port`) |
| User | `paperless-scanner` |
| Authentication | SSH public key (password auth is disabled) |
| Remote path | `/inbox/` — or leave blank; session auto-cd's there |

Chroot is enforced by the image; the SFTP session sees only the `inbox/`
tree, no other filesystem exposure.

### Diagnostics

```bash
# Is the sidecar up?
sudo -u paperless podman ps --filter name=paperless-sftp

# Recent logs (auth attempts, sshd startup)
sudo -u paperless podman logs paperless-sftp

# Port reachable on the host?
ss -tlnp | grep 2222

# Try a connection from the workstation
sftp -i ~/.ssh/scanner-key -P 2222 paperless-scanner@<host>
```

### Teardown

Flip `paperless_sftp_ingest_enabled: false` and rerun the playbook.
The Galaxy `podman_quadlet` role stops and removes the `paperless-sftp`
systemd unit; the firewall port closes; the keys volume lingers empty
(harmless — delete manually if desired with
`sudo -u paperless podman volume rm paperless-sftp-keys`).

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
