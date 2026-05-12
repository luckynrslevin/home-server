# caddy

Front-door web server and reverse proxy. **Mandatory** in this
project: every per-service web UI is fronted at
`https://<subdomain>.<caddy_domain>` with real Let's Encrypt
certificates issued via the DNS-01 ACME challenge, and direct
per-service HTTP ports are not exposed in the firewall.
`caddy_domain`, `caddy_acme_provider`, and `caddy_acme_token` must
be set in host_vars; the role asserts this at the top of the play.

## Container image

`ghcr.io/luckynrslevin/caddy-acme:latest` — Caddy + bundled DNS-01
plugins (deSEC, Cloudflare, Hetzner DNS) compiled in via xcaddy.
See [`../../caddy-image/`](../../caddy-image/) for the Dockerfile +
GitHub Actions workflow that publishes this tag.

## Service user

`webproxy` (UID/GID 1011) — rootless.

## Variables

| Variable                        | Default | Purpose |
|---------------------------------|---------|---------|
| `caddy_image`                   | `ghcr.io/luckynrslevin/caddy-acme:latest` | Caddy build with deSEC + Cloudflare + Hetzner DNS-01 plugins. |
| `caddy_listen_port`             | `9080`  | Internal HTTP port. Firewall forwards `80 → caddy_listen_port`. |
| `caddy_listen_port_https`       | `9443`  | Internal HTTPS port. Firewall forwards `443 → caddy_listen_port_https`. |
| `caddy_domain`                  | `""`    | **Required.** Server domain (e.g. `myhome.dedyn.io`). |
| `caddy_reverse_proxy_services`  | `[]`    | List of `{subdomain, port, proto?}` dicts — one per proxied service. |
| `caddy_acme_provider`           | `""`    | **Required.** DNS provider for the ACME DNS-01 challenge: `desec`, `cloudflare`, or `hetzner`. |
| `caddy_acme_subdomain`          | `""`    | For `desec`: the dedyn.io subdomain (without `.dedyn.io`). |
| `caddy_acme_zone`               | `""`    | For `cloudflare` / `hetzner`: the apex zone (e.g. `example.com`). |
| `caddy_acme_token`              | `""`    | **Required.** DNS-provider API token. Vault-encrypt this in host_vars. |

## TLS issuer

Caddy issues real Let's Encrypt certificates via the **DNS-01
challenge** against your DNS provider. No port-forwarding from the
public internet, no per-device CA install, no browser warnings —
every client trusts LE roots out of the box.

Three providers are supported (all bundled in the image):

| Provider | Set in inventory | Use when |
|---|---|---|
| **`desec`** | `caddy_acme_provider: desec` + `caddy_acme_subdomain: <sub>` | Default platform path. Free `*.dedyn.io` subdomain at deSEC. |
| **`cloudflare`** | `caddy_acme_provider: cloudflare` + `caddy_acme_zone: <zone>` | You own a domain hosted at Cloudflare DNS. |
| **`hetzner`** | `caddy_acme_provider: hetzner` + `caddy_acme_zone: <zone>` | You own a domain hosted at Hetzner DNS. |

Caddy issues a **single wildcard cert** covering both the apex
(`<caddy_domain>`) and every subdomain (`*.<caddy_domain>`), and
auto-renews it. One Caddyfile site block routes every reverse-
proxied service via `host` matchers, so adding a service is just
an inventory entry — no extra cert, no extra ACME challenge.

The DNS provider's API only sees a single temporary
`_acme-challenge.<domain>` TXT record per renewal — your homeserver
is never reachable from the public internet, and there are no
per-subdomain TXTs to leave behind.

### Example: deSEC (default platform path)

```yaml
# host_vars (private overlay)
caddy_domain: "myhome.dedyn.io"
caddy_acme_provider: "desec"
caddy_acme_subdomain: "myhome"
caddy_acme_token: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  ...
```

### Example: BYO Cloudflare

```yaml
caddy_domain: "homeserver.example.com"
caddy_acme_provider: "cloudflare"
caddy_acme_zone: "example.com"
caddy_acme_token: !vault |
  ...
```

### Reverse proxy configuration example

```yaml
caddy_reverse_proxy_services:
  - { subdomain: pihole, port: 8443, proto: https }
  - { subdomain: syncthing, port: 8384, proto: https }
  - { subdomain: photos, port: 3000 }
  - { subdomain: paperless, port: 8000 }
```

This creates `https://pihole.<caddy_domain>/`, `https://syncthing.<caddy_domain>/`, etc.

### DNS records

LAN clients need to resolve `*.<caddy_domain>` to the homeserver's
LAN IP. The pihole role's wildcard local-DNS fragment handles this
automatically when `caddy_acme_subdomain` (deSEC) or
`caddy_acme_zone` (BYO) is set — see
[roles/pihole/README.md](../pihole/README.md#wildcard-local-dns-for-the-caddy-acme-domain).

For roaming Tailscale clients, see
[docs/Tailscale-DNS-Setup.md](../../docs/Tailscale-DNS-Setup.md).

## Secrets

| Variable | Purpose |
|---|---|
| `caddy_acme_token` | API token for the chosen DNS provider. Vault-encrypt. |

Generate and vault:

```bash
ansible-vault encrypt_string --encrypt-vault-id default --stdin-name 'caddy_acme_token'
```

## Firewall ports

- **80/tcp** (port-forward → `caddy_listen_port`) — Let's Encrypt's HTTP-01 challenge isn't used (we use DNS-01); port 80 is just for the standard `http://*` → `https://*` redirect Caddy serves automatically.
- **443/tcp** (port-forward → `caddy_listen_port_https`)

## Endpoints

- Dashboard: `https://<caddy_domain>/`
- Per-service: `https://<subdomain>.<caddy_domain>/` (one per
  `caddy_reverse_proxy_services` entry)

## Volumes

- `caddy-data` — TLS certificates issued by Let's Encrypt and
  auto-renewed. Re-issued from scratch on a fresh install — no
  backup needed.
- `caddy-config` — runtime config. Regenerated.
- `caddy-etc` — staged `Caddyfile` (rendered from Jinja2 template).

## Deployment

```bash
ansible-playbook playbooks/caddy.yml --limit homeserver
```

The role:
1. Asserts `caddy_acme_provider` + `caddy_acme_token` are set.
2. Creates `/var/www/dashboard` with SELinux label `container_file_t`.
3. Stages the templated `Caddyfile` into `caddy-etc`.
4. Opens firewall ports 80 + 443.
5. Runs `caddy reload` at the end so config changes apply without a
   container restart.

On first deploy Caddy contacts Let's Encrypt, writes a temporary
`_acme-challenge.<domain>` TXT record at the DNS provider, waits
for DNS propagation (2 min, to give recursive resolvers time to
clear any negative cache), then gets the wildcard cert issued.
HTTPS for every site is live ~3 min after the play finishes.

## Cross-role dependencies

Pairs with [dashboard](../dashboard/README.md). Caddy is the public
face; dashboard is the content. Either can be deployed first.

When reverse proxy is enabled, pairs with
[pihole](../pihole/README.md) for the LAN-side wildcard DNS record
(so `*.<caddy_domain>` resolves to the homeserver's LAN IP without
going to public DNS).
