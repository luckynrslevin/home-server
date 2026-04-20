# entephoto

Self-hosted [Ente Photos](https://ente.io) — encrypted photo storage
with a web UI. Deployed as a rootless Podman pod with four
containers: PostgreSQL, MinIO (S3-compatible object storage), Museum
(API backend), and Web (frontend).

## Container images

| Container | Image |
|-----------|-------|
| postgres  | `docker.io/library/postgres:15` |
| minio     | `quay.io/minio/minio:latest`    |
| museum    | `ghcr.io/ente-io/server:latest` |
| web       | `ghcr.io/ente-io/web:latest`    |

## Service user

`entephoto` (UID/GID 1008) — rootless.

## Variables

| Variable                    | Default                            | Purpose                                                                                          |
|-----------------------------|-------------------------------------|--------------------------------------------------------------------------------------------------|
| `entephoto_minio_root_user` | `enteadmin`                         | MinIO admin username (paired with `entephoto_minio_password`).                                   |
| `entephoto_admin_user_ids`  | `[]`                                | Ente user IDs granted admin rights. Populate after first signup (see "Bootstrapping an admin").  |
| `entephoto_api_url`         | `http://<server-ip>:8080`           | Museum API URL served to the browser. Override for reverse proxy.                                |
| `entephoto_photos_url`      | `http://<server-ip>:3000`           | Photos web app URL served to the browser.                                                        |
| `entephoto_albums_url`      | `http://<server-ip>:3002`           | Albums/public-albums URL served to the browser.                                                  |
| `entephoto_s3_endpoint`     | `<server-ip>:3200`                  | MinIO S3 endpoint for presigned upload URLs. Override when proxying MinIO.                       |

## Secrets

All five must be vaulted in your host_vars. Generate fresh values:

```bash
# Passwords / random secrets
openssl rand -base64 24 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'entephoto_db_password'

openssl rand -base64 24 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'entephoto_minio_password'

# Encryption keys (Ente expects specific lengths)
openssl rand -base64 32 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'entephoto_encryption_key'

openssl rand -base64 64 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'entephoto_hash_key'

openssl rand -hex 32 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'entephoto_jwt_secret'
```

To inspect a stored secret:

```bash
ansible -i inventory/hosts.yml homeserver -m debug -a "var=entephoto_db_password"
ansible -i inventory/hosts.yml homeserver -m debug -a "var=entephoto_minio_password"
ansible -i inventory/hosts.yml homeserver -m debug -a "var=entephoto_encryption_key"
ansible -i inventory/hosts.yml homeserver -m debug -a "var=entephoto_hash_key"
ansible -i inventory/hosts.yml homeserver -m debug -a "var=entephoto_jwt_secret"
```

## Firewall ports

- **8080/tcp** — Museum (API)
- **3200/tcp** — MinIO S3 (browser uploads via presigned URLs)
- **3000-3008/tcp** — Web apps (photos, accounts, albums, auth, cast,
  share, embed, paste)

## Endpoints

- Photos: `http://<server-ip>:3000`
- Albums: `http://<server-ip>:3002`
- API health: `http://<server-ip>:8080/ping`

## Volumes

- `entephoto-postgres-data` — PostgreSQL data files.
- `entephoto-minio-data` — MinIO buckets.
- `entephoto-museum-config` — staged `museum.yaml` (rendered from
  template with vaulted secrets).

## Reverse proxy

By default, all URLs use the server's IP address with direct port
access. When serving Ente through a reverse proxy (e.g. Caddy with
HTTPS subdomains), override the URL variables in your host_vars:

```yaml
entephoto_api_url: "https://entephoto-api.example.com"
entephoto_photos_url: "https://entephoto.example.com"
entephoto_albums_url: "https://entephoto-albums.example.com"
entephoto_s3_endpoint: "entephoto-s3.example.com"
```

The reverse proxy must forward each subdomain to the corresponding
local port:

| Subdomain              | Backend              |
|------------------------|----------------------|
| `entephoto-api`        | `localhost:8080`     |
| `entephoto`            | `localhost:3000`     |
| `entephoto-albums`     | `localhost:3002`     |
| `entephoto-s3`         | `localhost:3200`     |

When using the `caddy` role, add matching entries to
`caddy_reverse_proxy_services` in your host_vars.

## Deployment

```bash
ansible-playbook playbooks/entephoto.yml --limit homeserver
```

## Post-install behaviour

After containers start, the role waits for MinIO to come up and then
creates the three buckets Ente expects (`b2-eu-cen`,
`wasabi-eu-central-2-v3`, `scw-eu-fr-v3`). It does this from a
one-shot `minio/mc` container joined to the same pod network. The
official `minio/minio` image doesn't ship `mc`, so this is run
out-of-band.

## Bootstrapping an admin

After signing up the first user via the web UI, find their user ID:

```bash
sudo -u entephoto podman exec entephoto-postgres \
  psql -U pguser ente_db -c "SELECT user_id FROM users;"
```

Add the ID to `entephoto_admin_user_ids` in your host_vars and re-run
the playbook so it gets written into `museum.yaml`.
