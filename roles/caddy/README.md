# caddy

Front-door web server and reverse proxy. In simple mode (default),
it serves the [dashboard](../dashboard/README.md) on port 80. When
`caddy_domain` is set, it becomes a full reverse proxy with
subdomain-based routing and automatic HTTPS (self-signed certs).

## Container image

`public.ecr.aws/docker/library/caddy:latest`

## Service user

`webproxy` (UID/GID 1011) — rootless.

## Variables

| Variable                        | Default | Purpose |
|---------------------------------|---------|---------|
| `caddy_listen_port`             | `9080`  | Internal HTTP port. Firewall forwards `80 → caddy_listen_port`. |
| `caddy_listen_port_https`       | `9443`  | Internal HTTPS port. Firewall forwards `443 → caddy_listen_port_https` (only when `caddy_domain` is set). |
| `caddy_domain`                  | `""`    | Server domain (e.g. `eddie.lan`). Enables reverse proxy + HTTPS. Empty = simple dashboard mode. |
| `caddy_reverse_proxy_services`  | `[]`    | List of `{subdomain, port, proto?}` dicts — one per proxied service. |
| `caddy_seed_internal_ca`        | `false` | Stage the internal ACME CA (root + intermediate cert/key) from the private overlay on deploy. See [Internal CA persistence](#internal-ca-persistence). |

### Reverse proxy configuration example

```yaml
# In host_vars:
caddy_domain: "eddie.lan"
caddy_reverse_proxy_services:
  - { subdomain: pihole, port: 8443, proto: https }
  - { subdomain: syncthing, port: 8384, proto: https }
  - { subdomain: jukebox, port: 9100 }
  - { subdomain: photos, port: 3000 }
  - { subdomain: paperless, port: 8000 }
```

This creates:
- `https://eddie.lan` → dashboard
- `https://pihole.eddie.lan` → Pi-hole admin (proxied from HTTPS upstream)
- `https://syncthing.eddie.lan` → Syncthing
- `https://jukebox.eddie.lan` → Jukebox
- etc.

### DNS records

Each subdomain needs an A record pointing to the server IP. Add
them to Pi-hole via `pihole_local_dns_records` in host_vars:

```yaml
pihole_local_dns_records:
  - { ip: "192.168.1.231", hostname: "eddie.lan" }
  - { ip: "192.168.1.231", hostname: "pihole.eddie.lan" }
  - { ip: "192.168.1.231", hostname: "syncthing.eddie.lan" }
  # ... etc
```

## Secrets

None.

## Firewall ports

- **80/tcp** (port-forward → `caddy_listen_port`)
- **443/tcp** (port-forward → `caddy_listen_port_https`) — only when
  `caddy_domain` is set

## Endpoints

- Simple mode: `http://<server-ip>/`
- Reverse proxy mode: `https://<caddy_domain>/` + `https://<subdomain>.<caddy_domain>/`

## Volumes

- `caddy-data` — TLS certificates (auto-generated self-signed) and
  Caddy state.
- `caddy-config` — runtime config.
- `caddy-etc` — staged `Caddyfile` (rendered from Jinja2 template).
- Bind mount: `/var/www/dashboard:ro` — dashboard HTML written by
  the dashboard role.

## Deployment

```bash
ansible-playbook playbooks/caddy.yml --limit homeserver
```

The role:
1. Creates `/var/www/dashboard` with SELinux label `container_file_t`.
2. Stages the templated `Caddyfile` into `caddy-etc`.
3. Opens firewall port 443 when reverse proxy is enabled.
4. Runs `caddy reload` at the end so config changes apply without a
   container restart.

## HTTPS

Caddy automatically generates self-signed certificates for `.lan`
domains. Browsers will show a one-time cert warning — acceptable
for a LAN home server. Certificate data is persisted in `caddy-data`.

## Internal CA persistence

Caddy uses `tls internal`, which runs a private ACME CA. The root and
intermediate cert + key live in `caddy-data/caddy/pki/authorities/local/`.
By default a reinstall rolls a new CA and every device that trusted the
old root has to re-import the new one.

To preserve the CA across reinstalls, stage the four CA files from the
`home-server-private` overlay using the same pattern as syncthing's
identity:

### One-time bootstrap

1. On the already-running host, extract the current CA:

   ```bash
   ./scripts/caddy-ca-extract.sh
   ```

   The script prints the staging directory and the next-step commands.

2. Vault-encrypt the two private keys:

   ```bash
   ansible-vault encrypt <staging>/root.key <staging>/intermediate.key
   ```

3. Copy all four files into the private overlay at the exact path
   Caddy expects:

   ```
   home-server-private/
     roles/caddy/files/volumes/caddy-data/caddy/pki/authorities/local/
       root.crt
       root.key           # vault-encrypted
       intermediate.crt
       intermediate.key   # vault-encrypted
   ```

4. Symlink the staging paths into the public repo (mirrors the
   syncthing convention — see the project-level README):

   ```bash
   cd home-server
   mkdir -p roles/caddy/files/volumes/caddy-data/caddy/pki/authorities/local
   for f in root.crt root.key intermediate.crt intermediate.key; do
     ln -sf ../../../../../../../../home-server-private/roles/caddy/files/volumes/caddy-data/caddy/pki/authorities/local/$f \
       roles/caddy/files/volumes/caddy-data/caddy/pki/authorities/local/$f
   done
   ```

5. In the host's `inventory/host_vars/<host>/main.yml`, set:

   ```yaml
   caddy_seed_internal_ca: true
   ```

6. Redeploy caddy and verify:

   ```bash
   # Capture current CA fingerprint
   sudo openssl x509 -in /etc/pki/caddy-internal/root.crt \
       -noout -fingerprint -sha256

   # Destroy and recreate the volume to prove the seed works
   sudo -u webproxy systemctl --user stop caddy
   sudo -u webproxy podman volume rm caddy-data
   ansible-playbook playbooks/caddy.yml --limit <host>

   # Fingerprint must match
   sudo openssl x509 -in /etc/pki/caddy-internal/root.crt \
       -noout -fingerprint -sha256
   ```

### Why not back it up to the NAS?

The private overlay is already the project's source of truth for
host-specific identity (syncthing cert, vault-encrypted secrets).
Putting the CA there keeps all long-lived identity in one place,
avoids storing a private key in NAS tar archives, and removes the NAS
from the "reinstall-from-scratch" critical path.

`caddy-etc` (Caddyfile) and `caddy-config` (runtime state) are not
seeded or backed up — both are regenerated from the role on each
deploy.

## Backward compatibility

Direct `IP:port` access still works — existing firewall rules
remain. The reverse proxy is an additional access path, not a
replacement.

## Cross-role dependencies

Pairs with [dashboard](../dashboard/README.md). Caddy is the public
face; dashboard is the content. Either can be deployed first.

When reverse proxy is enabled, depends on
[pihole](../pihole/README.md) for DNS records (subdomain → server IP).
