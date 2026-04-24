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

The role can pre-seed the CA into `caddy-data` on every deploy, driven
by four variables in `host_vars`:

| Variable                       | Contents                              |
|--------------------------------|---------------------------------------|
| `caddy_ca_root_crt`            | Root certificate (PEM)                |
| `caddy_ca_root_key`            | Root private key (PEM, vault-encrypt) |
| `caddy_ca_intermediate_crt`    | Intermediate certificate (PEM)        |
| `caddy_ca_intermediate_key`    | Intermediate private key (PEM, vault-encrypt) |

With `caddy_seed_internal_ca: true`, the role renders these into the
volume at the exact paths Caddy expects. Caddy reuses them on startup
instead of generating a new CA.

### One-time bootstrap

1. On the already-running host, extract the current CA:

   ```bash
   ./scripts/caddy-ca-extract.sh
   ```

   The script writes the four files to a `/tmp/caddy-ca-<timestamp>/`
   staging directory and prints the next-step commands.

2. Vault-encrypt each private key into a YAML-ready block:

   ```bash
   ansible-vault encrypt_string --stdin-name 'caddy_ca_root_key' \
       < /tmp/caddy-ca-*/root.key
   ansible-vault encrypt_string --stdin-name 'caddy_ca_intermediate_key' \
       < /tmp/caddy-ca-*/intermediate.key
   ```

   Paste each block into the host's `inventory/host_vars/<host>/main.yml`.

3. Paste the two certificates as plain YAML literal-block strings:

   ```yaml
   caddy_ca_root_crt: |
     -----BEGIN CERTIFICATE-----
     ... contents of root.crt ...
     -----END CERTIFICATE-----

   caddy_ca_intermediate_crt: |
     -----BEGIN CERTIFICATE-----
     ... contents of intermediate.crt ...
     -----END CERTIFICATE-----
   ```

4. Flip the flag in the same `host_vars`:

   ```yaml
   caddy_seed_internal_ca: true
   ```

5. Redeploy caddy and verify:

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
host-specific identity and secrets. Putting the CA inline with the
rest of the host_vars keeps all per-host configuration in one file,
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
