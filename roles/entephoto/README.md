# entephoto

Self-hosted [Ente Photos](https://ente.io) — encrypted photo storage
with a web UI. Deployed as a rootless Podman pod with four
containers: PostgreSQL, Garage (S3-compatible object storage), Museum
(API backend), and Web (frontend).

> **History note:** the object store was MinIO until issue #168.
> MinIO upstream removed the admin UI from the community image and
> pivoted toward a commercial SKU. Garage is a maintained Rust
> alternative, single binary, native S3 API, designed for self-hosted
> 1–3 node clusters. Existing deployments migrate via
> `playbooks/entephoto-minio-to-garage.yml` (see
> `docs/Garage-Migration.md`).

## Container images

| Container | Image |
|-----------|-------|
| postgres  | `public.ecr.aws/docker/library/postgres:15` |
| garage    | `dxflrs/garage:v1.0.1`          |
| museum    | `ghcr.io/ente-io/server:latest` |
| web       | `ghcr.io/ente-io/web:latest`    |

The Garage image is pinned to a specific release tag — Garage's
on-disk format can change between minor versions, so do not chase
`:latest`.

## Service user

`entephoto` (UID/GID 1008) — rootless.

## Variables

| Variable                    | Default                            | Purpose                                                                                          |
|-----------------------------|-------------------------------------|--------------------------------------------------------------------------------------------------|
| `entephoto_admin_user_ids`  | `[]`                                | Ente user IDs granted admin rights. Populate after first signup (see "Bootstrapping an admin").  |
| `entephoto_api_url`         | `http://<server-ip>:8080`           | Museum API URL served to the browser. Override for reverse proxy.                                |
| `entephoto_photos_url`      | `http://<server-ip>:3000`           | Photos web app URL served to the browser.                                                        |
| `entephoto_albums_url`      | `http://<server-ip>:3002`           | Albums/public-albums URL served to the browser.                                                  |
| `entephoto_s3_endpoint`     | `<server-ip>:3900`                  | S3 endpoint for presigned upload URLs. Override when proxying via Caddy.                         |

## Secrets

Generate fresh vault entries with `homeserver.sh add entephoto` (the
installer prompts and vault-encrypts each). Manual rotation:

```bash
# Random secrets
openssl rand -base64 24 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'entephoto_db_password'

openssl rand -hex 32 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'entephoto_garage_rpc_secret'

openssl rand -base64 32 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'entephoto_garage_admin_token'

# Encryption keys (Ente expects specific lengths)
openssl rand -base64 32 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'entephoto_encryption_key'

openssl rand -base64 64 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'entephoto_hash_key'

openssl rand -hex 32 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'entephoto_jwt_secret'
```

The museum's S3 access key + secret are **not** prompted — Garage
generates them at first deploy and the bootstrap task persists them
to `/home/entephoto/.garage-museum-key.json` on the target. Re-runs
read the sidecar back so the key stays stable across redeploys.

## Firewall ports

None. All Ente surfaces (photos, accounts, cast, auth, museum API,
S3) are reverse-proxied by Caddy on `https://*.<caddy_domain>` —
direct LAN access on 8080, 3900, and 3000-3008 is intentionally not
exposed.

## Endpoints

- Photos: `https://photos.<caddy_domain>`
- Accounts: `https://accounts.<caddy_domain>`
- Cast: `https://cast.<caddy_domain>`
- Auth: `https://auth.<caddy_domain>`
- API: `https://photos-api.<caddy_domain>`
- S3: `https://photos-s3.<caddy_domain>`

## Volumes

- `entephoto-postgres-data` — PostgreSQL data files.
- `entephoto-garage-data` — Garage blob storage (opaque chunks).
- `entephoto-garage-meta` — Garage bucket/object index (RocksDB/LMDB).
  **Losing this orphans the data volume** — it's part of the backup
  manifest as a result.
- `entephoto-garage-config` — staged `garage.toml`.
- `entephoto-museum-config` — staged `museum.yaml` (rendered from
  template with vaulted secrets + the generated S3 key).

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
| `entephoto-s3`         | `localhost:3900`     |

When using the `caddy` role, add matching entries to
`caddy_reverse_proxy_services` in your host_vars.

## Deployment

```bash
ansible-playbook playbooks/entephoto.yml --limit homeserver
```

## Post-install behaviour

After the pod is up, `tasks/garage-bootstrap.yml` runs against the
Garage container and:

1. Assigns the single-node layout if not already done.
2. Creates the three buckets Ente expects (`b2-eu-cen`,
   `wasabi-eu-central-2-v3`, `scw-eu-fr-v3`).
3. Generates an access key (`entephoto-museum`) once and persists
   id+secret to `/home/entephoto/.garage-museum-key.json` so re-runs
   don't rotate it.
4. Grants the key read/write on each bucket.

`museum.yaml` is then re-rendered with the persisted key/secret and
the museum container is restarted if anything drifted.

## Bootstrapping an admin

After signing up the first user via the web UI, find their user ID:

```bash
sudo -u entephoto podman exec entephoto-postgres \
  psql -U pguser ente_db -c "SELECT user_id FROM users;"
```

Add the ID to `entephoto_admin_user_ids` in your host_vars and re-run
the playbook so it gets written into `museum.yaml`.

## License note

Garage is AGPL-3.0. For non-distributed personal/household hosting
this has no practical implication; if you plan to distribute a fork
or run a service for third parties, review the AGPL terms.
