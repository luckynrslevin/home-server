# pihole

[Pi-hole](https://pi-hole.net) v6 — DNS-level ad blocker for the LAN.
Runs as a rootless container; the host's `systemd-resolved` is
reconfigured to use it.

## Container image

`ghcr.io/pi-hole/pihole:latest` (override via `pihole_image`). GHCR
mirror is the default to avoid Docker Hub anonymous pull rate limits.

## Service user

`pihole` (UID/GID 1005) — rootless.

## Variables

| Variable                   | Default                              | Purpose                                                                |
|----------------------------|--------------------------------------|------------------------------------------------------------------------|
| `pihole_web_port_https`    | `8443`                               | HTTPS port for the admin UI.                                           |
| `pihole_image`             | `ghcr.io/pi-hole/pihole:latest`      | Container image.                                                       |
| `pihole_dns_upstreams`     | `9.9.9.9;149.112.112.112` (Quad9)    | Upstreams (semicolon-separated).                                       |
| `pihole_container_dns`     | `9.9.9.9`                            | DNS used by the container itself, not by clients.                      |
| `pihole_domain_name`       | `lan`                                | Local domain suffix for conditional forwarding.                        |
| `pihole_hostname`          | `pihole.lan`                         | Container hostname.                                                    |
| `pihole_local_network`     | `192.168.x.0/24`                     | Override per-host. Used for conditional forwarding.                    |
| `pihole_local_router`      | `192.168.x.1`                        | Override per-host.                                                     |
| `pihole_adlists`           | one Turtlecute list                  | **Extra** lists. StevenBlack is auto-added by Pi-hole on first run.    |
| `pihole_local_dns_records` | `[]`                                 | Custom A records (`{ip, hostname}` dicts) written to `pihole.toml`.    |

## Secrets

| Variable              | Purpose                              |
|-----------------------|--------------------------------------|
| `pihole_api_password` | Admin / API password for the web UI. |

Generate and vault:

```bash
openssl rand -base64 24 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'pihole_api_password'
```

Inspect a stored password:

```bash
ansible -i inventory/hosts.yml homeserver -m debug -a "var=pihole_api_password"
```

## Firewall ports

- **53/tcp** and **53/udp** (port-forwarded to `1053` for the
  rootless container)
- **8443/tcp** — HTTPS admin UI

## Endpoints

- Admin UI: `https://<server-ip>:8443/admin`

## Volumes

- `systemd-pihole-etc` — `/etc/pihole`, including `gravity.db`.
- `systemd-pihole-dnsmasq` — `/etc/dnsmasq.d`, including conditional
  forwarding rules.

## Deployment

```bash
ansible-playbook playbooks/pihole.yml --limit homeserver
```

The role pre-pulls the image **before** restarting the container —
without this, restarting Pi-hole would take down its own DNS
upstream, and the new pull would fail.

After deploy it also writes `/etc/systemd/resolved.conf.d/pihole.conf`
so the host points at `127.0.0.1:1053` for DNS.

## Post-install behaviour

[postinstall.yml](tasks/postinstall.yml):

1. Polls `gravity.db` until the `adlist` table exists (FTL builds
   the schema asynchronously on first start).
2. Inserts each entry from `pihole_adlists` into the SQLite `adlist`
   table via `INSERT OR IGNORE` (Pi-hole v6 stopped reading the
   legacy `/etc/pihole/adlists.list` flat file).
3. Clears `listsCache` so the rootless user can write to it.
4. Runs `pihole -g` to download lists into `gravity`.
5. If `pihole_local_dns_records` is set, writes them via
   `pihole-FTL --config dns.hosts <json>`.

### Why `pihole_adlists` doesn't include StevenBlack

The Pi-hole container bootstrap creates an initial
`/etc/pihole/adlists.list` containing the StevenBlack unified hosts
list and migrates it into `gravity.db` on first start. Listing it
again here would just no-op via `INSERT OR IGNORE`.
