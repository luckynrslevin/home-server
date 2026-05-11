# caddy

Front-door web server and reverse proxy. **Mandatory** in this project:
every per-service web UI is fronted at `https://<subdomain>.<caddy_domain>`
with an internally-trusted CA, and direct per-service HTTP ports are not
exposed in the firewall. `caddy_domain` must be set in host_vars; an
empty value will cause `playbooks/site.yml` to fail fast.

## Container image

`public.ecr.aws/docker/library/caddy:latest`

## Service user

`webproxy` (UID/GID 1011) — rootless.

## Variables

| Variable                        | Default | Purpose |
|---------------------------------|---------|---------|
| `caddy_image`                   | `ghcr.io/luckynrslevin/caddy-acme:latest` | Caddy build with deSEC + Cloudflare + Hetzner DNS-01 plugins compiled in. See [`../../caddy-image/`](../../caddy-image/). |
| `caddy_listen_port`             | `9080`  | Internal HTTP port. Firewall forwards `80 → caddy_listen_port`. |
| `caddy_listen_port_https`       | `9443`  | Internal HTTPS port. Firewall forwards `443 → caddy_listen_port_https` (only when `caddy_domain` is set). |
| `caddy_domain`                  | `""`    | Server domain (e.g. `myhome.dedyn.io` or `homeserver.lan`). Enables reverse proxy + HTTPS. Empty = simple dashboard mode. |
| `caddy_reverse_proxy_services`  | `[]`    | List of `{subdomain, port, proto?}` dicts — one per proxied service. |
| `caddy_acme_provider`           | `"internal"` | TLS issuer: `internal` (Caddy self-signed CA), `desec`, `cloudflare`, or `hetzner`. See [TLS issuer selection](#tls-issuer-selection). |
| `caddy_acme_subdomain`          | `""`    | For `desec`: the dedyn.io subdomain (without `.dedyn.io`). |
| `caddy_acme_zone`               | `""`    | For `cloudflare` / `hetzner`: the apex zone (e.g. `example.com`). |
| `caddy_acme_token`              | `""`    | DNS-provider API token (vault-encrypt in host_vars). |
| `caddy_seed_internal_ca`        | `false` | When `caddy_acme_provider == 'internal'`, stage the internal ACME CA (root + intermediate cert/key) from the private overlay on deploy. See [Internal CA persistence](#internal-ca-persistence). |

## TLS issuer selection

`caddy_acme_provider` picks how Caddy issues certs:

| Provider | When to use | Cert type | Per-device install? |
|---|---|---|---|
| **`internal`** | Air-gapped homelab; no internet at install time. | Self-signed by Caddy's built-in CA. | **Yes** — every device that hits a Caddy URL must trust the root cert. The `/trust` HTTP landing page (served at `http://<caddy_domain>/trust`) walks users through the install. |
| **`desec`** | Default platform path — recommended. Free `*.dedyn.io` subdomain at deSEC. | **Real Let's Encrypt** (via DNS-01). | No. |
| **`cloudflare`** | You own a domain hosted at Cloudflare DNS. | **Real Let's Encrypt** (via DNS-01). | No. |
| **`hetzner`** | You own a domain hosted at Hetzner DNS. | **Real Let's Encrypt** (via DNS-01). | No. |

Setting any non-`internal` provider:
- Drops every `tls internal` line from the Caddyfile.
- Emits a global `acme_dns <provider> <token>` block at the top of the Caddyfile.
- Skips the entire CA-extract / mobileconfig / `/trust` landing-page deploy chain (those tasks are gated on `caddy_acme_provider == 'internal'`).
- Caddy auto-issues a wildcard cert for `*.<caddy_domain>` via the chosen provider's API.

Example for the deSEC default path:

```yaml
# host_vars (private overlay)
caddy_domain: "myhome.dedyn.io"
caddy_acme_provider: "desec"
caddy_acme_subdomain: "myhome"
caddy_acme_token: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  ...
```

Example for BYO Cloudflare:

```yaml
caddy_domain: "homeserver.example.com"
caddy_acme_provider: "cloudflare"
caddy_acme_zone: "example.com"
caddy_acme_token: !vault |
  ...
```

### Reverse proxy configuration example

```yaml
# In host_vars:
caddy_domain: "homeserver.lan"
caddy_reverse_proxy_services:
  - { subdomain: pihole, port: 8443, proto: https }
  - { subdomain: syncthing, port: 8384, proto: https }
  - { subdomain: jukebox, port: 9100 }
  - { subdomain: photos, port: 3000 }
  - { subdomain: paperless, port: 8000 }
```

This creates:
- `https://homeserver.lan` → dashboard
- `https://pihole.homeserver.lan` → Pi-hole admin (proxied from HTTPS upstream)
- `https://syncthing.homeserver.lan` → Syncthing
- `https://jukebox.homeserver.lan` → Jukebox
- etc.

### DNS records

Each subdomain needs an A record pointing to the server IP. Add
them to Pi-hole via `pihole_local_dns_records` in host_vars:

```yaml
pihole_local_dns_records:
  - { ip: "192.168.1.231", hostname: "homeserver.lan" }
  - { ip: "192.168.1.231", hostname: "pihole.homeserver.lan" }
  - { ip: "192.168.1.231", hostname: "syncthing.homeserver.lan" }
  # ... etc
```

## Secrets

None.

## Firewall ports

- **80/tcp** (port-forward → `caddy_listen_port`)
- **443/tcp** (port-forward → `caddy_listen_port_https`)

## Endpoints

- Dashboard: `https://<caddy_domain>/`
- Per-service: `https://<subdomain>.<caddy_domain>/` (one per `caddy_reverse_proxy_services` entry)

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

## Distributing the internal CA to client devices

The role publishes a small **HTTP-served landing page** plus the raw
artifacts so a fresh device can bootstrap trust without first
trusting the cert it's trying to download:

| URL                                            | Scheme | For                       | UX                                                                                                  |
|------------------------------------------------|:---:|---------------------------|-----------------------------------------------------------------------------------------------------|
| `http://<caddy_domain>/trust`                  | HTTP | Any device, first install | Self-contained landing page with download links + per-platform install instructions. **Start here on a fresh device.** |
| `http://<caddy_domain>/caddy-trust.mobileconfig` | HTTP | iOS / iPadOS / macOS      | Apple Configuration Profile bundling the root cert. Linked from the landing page.                    |
| `http://<caddy_domain>/caddy-root.crt`         | HTTP | Linux / Android / Windows | Raw PEM cert. Linked from the landing page.                                                          |

These three paths are the only HTTP exemptions in the Caddyfile;
everything else on `http://<caddy_domain>` 301-redirects to HTTPS as
normal. Serving them over HTTP is safe — they're the **public** part
of the CA and install instructions for it; nothing secret.

Once installed, the user reaches the dashboard at
`https://<caddy_domain>/` cleanly with no warnings.

The landing page is rendered from
`templates/trust.html.j2`; the mobileconfig from
`templates/caddy-trust.mobileconfig.j2`. Both regenerate on every
deploy, so a CA rotation refreshes them automatically.

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

## Cross-role dependencies

Pairs with [dashboard](../dashboard/README.md). Caddy is the public
face; dashboard is the content. Either can be deployed first.

When reverse proxy is enabled, depends on
[pihole](../pihole/README.md) for DNS records (subdomain → server IP).
