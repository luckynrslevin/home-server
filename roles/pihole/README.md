# pihole

[Pi-hole](https://pi-hole.net) v6 — DNS-level ad blocker for the LAN.
Runs as a rootless container; the host's `systemd-resolved` is
reconfigured to use it.

Optionally includes [Unbound](https://www.nlnetlabs.nl/projects/unbound/about/)
as a recursive DNS resolver — replacing third-party upstreams (Quad9,
Cloudflare) with local recursive resolution from the DNS root servers.
Enabled by default (`pihole_enable_unbound: true`).

## Container images

| Container | Image |
|-----------|-------|
| pihole | `ghcr.io/pi-hole/pihole:latest` (override via `pihole_image`) |
| unbound | `docker.io/klutchell/unbound:latest` (when `pihole_enable_unbound` is true) |

GHCR mirror for Pi-hole avoids Docker Hub anonymous pull rate limits.

## Service user

`pihole` (UID/GID 1005) — rootless.

## Variables

| Variable                   | Default                              | Purpose                                                                |
|----------------------------|--------------------------------------|------------------------------------------------------------------------|
| `pihole_web_port_https`    | `8443`                               | HTTPS port for the admin UI.                                           |
| `pihole_image`             | `ghcr.io/pi-hole/pihole:latest`      | Container image.                                                       |
| `pihole_enable_unbound`    | `true`                               | Enable Unbound recursive resolver as Pi-hole's upstream.               |
| `pihole_unbound_port`      | `5335`                               | Unbound listen port (localhost).                                       |
| `pihole_dns_upstreams`     | `9.9.9.9;149.112.112.112` (Quad9)    | Upstreams (only used when Unbound is disabled).                        |
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

## Unbound architecture

When `pihole_enable_unbound: true` (default), an Unbound container runs
alongside Pi-hole using `Network=container:pihole` — both containers
share the same network namespace so Pi-hole reaches Unbound at
`127.0.0.1:5335` on their shared loopback.

```
LAN client ──► port 53 (firewalld forward) ──► Pi-hole :1053
                                                    │
                                                    ▼
                                              Unbound :5335
                                                    │
                                                    ▼
                                           DNS root servers
```

No third-party resolver sees your full query stream. Authoritative
servers each see only their piece (root sees TLD lookup, `.com` sees
domain name, etc.).

### Verifying Unbound works

Use the [Mullvad DNS leak test](https://mullvad.net/en/check) or
`curl -s https://am.i.mullvad.net/json`. The DNS server IP shown should
be your own public IP — not a third-party resolver like Quad9 (9.9.9.9)
or Cloudflare (1.1.1.1). Seeing your own IP confirms Unbound is
resolving recursively from the root servers.

## Verifying ad blocking

### Automated (runs at end of every deploy)

By default the role runs `tasks/verify.yml` after post-install. It
hard-fails the play if anything looks wrong:

- Pi-hole container is healthy and FTL is listening.
- `systemd-resolved` on the host points at `127.0.0.1:1053`.
- `gravity.db` has more than zero domains (catches a silent adlist
  download failure).
- A known legitimate canary (`pihole_verify_canary_legit`, default
  `example.com`) resolves normally.
- A known blocked canary (`pihole_verify_canary_blocked`, default
  `ad.doubleclick.net`) is sinkholed.
- `pihole_verify_random_count` domains (default 5) drawn live from
  gravity are all sinkholed.
- When `pihole_enable_unbound: true`: Unbound is active, listening on
  `127.0.0.1:{{ pihole_unbound_port }}`, and Pi-hole's effective
  upstream is exclusively that local Unbound (no Quad9/Cloudflare/
  Google leak).

Re-run the verification alone without redeploying:

```bash
ansible-playbook playbooks/pihole.yml --tags verify
```

Skip verification for a run:

```bash
ansible-playbook playbooks/pihole.yml --skip-tags verify
```

Disable permanently for a host by setting
`pihole_run_verification: false` in that host's vars.

#### Optional external-leak probe

Set `pihole_verify_online: true` to also run a Mullvad DNS-leak probe
(`https://am.i.mullvad.net/json`) from the Pi-hole host. Off by default
because it requires outbound internet — leave it off for CI or
disconnected environments. The probe fails if the answer shows a
well-known external resolver (Quad9/Cloudflare/Google).

### Quick test

Open [adblock.turtlecute.org](https://adblock.turtlecute.org/) in a
browser that uses Pi-hole for DNS (disable DNS-over-HTTPS in browser
settings first). The page tests requests against known ad/tracker
domains and shows which ones are blocked.

Note: some browser-level ad blockers (uBlock Origin, AdGuard) cancel
requests at the extension layer with an error code the tester does
not classify as "blocked", so the page can read "nothing filtered"
even when both DNS- and browser-level blocking are active. The
authoritative view is Pi-hole's own Query Log (admin UI → Query Log,
or `sudo -u pihole podman exec pihole pihole -t`).

### Command-line test

Query a known ad domain and confirm Pi-hole returns `0.0.0.0`:

```bash
nslookup ad.doubleclick.net <server-ip>
```

A legitimate domain should still resolve normally:

```bash
nslookup google.com <server-ip>
```

### Check gravity (adlists loaded)

Verify all configured adlists are present in gravity:

```bash
sudo -u pihole podman exec pihole \
  sqlite3 /etc/pihole/gravity.db "SELECT id, enabled, address FROM adlist;"
```

### Query log

Check recent blocked queries via the Pi-hole API:

```bash
# Top blocked domains
sudo -u pihole podman exec pihole pihole -t
```

Or use the admin UI at `https://<server-ip>:8443/admin` → Query Log.

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
3. Runs `pihole -g` to download lists into `gravity`.
4. If `pihole_local_dns_records` is set, writes them via
   `pihole-FTL --config dns.hosts <json>`.

### Why `pihole_adlists` doesn't include StevenBlack

The Pi-hole container bootstrap creates an initial
`/etc/pihole/adlists.list` containing the StevenBlack unified hosts
list and migrates it into `gravity.db` on first start. Listing it
again here would just no-op via `INSERT OR IGNORE`.
