# `dnsvserver` deployment plan

This document captures **two alternative architectures** for the
public-IP `dnsvserver` (1 core / 1 GB RAM / AlmaLinux 9, currently
bootstrapped via `os-base` only). They differ in two big ways: **how
DNS reaches the clients**, and **which DNS engine** runs on the
vserver.

- **Option 1** keeps Pi-hole + Unbound as the engine and tunnels home
  + roaming clients in over WireGuard. Nothing DNS-related is
  internet-exposed.
- **Option 2** uses AdGuard Home + Unbound as the engine and exposes
  a public DoH endpoint, gated by per-device ClientID tokens, with
  Caddy + Let's Encrypt in front of the admin UI.

Pick one, archive the other. Both are open-source, fully self-hosted,
no paid tier.

## Quick comparison

| Dimension | Option 1: WireGuard + Pi-hole | Option 2: Public DoH + AdGuard Home |
|---|---|---|
| Public ports on dnsvserver | 22, 51820/udp | 22, 80, 443 |
| DNS engine on dnsvserver | Pi-hole + Unbound | AdGuard Home + Unbound |
| DNS engine on homeserver (home) | unchanged (Pi-hole if currently deployed) | unchanged |
| DNS authentication | implicit (only WG peers reach it) | per-device ClientID token (AGH-native) |
| Admin UI access | private over WG, `tls internal` | public hostname, Caddy basic-auth + LE + AGH login |
| Roaming devices | each device joins WG | each device gets its own ClientID token |
| Home router config required | one static route + DHCP DNS swap | none |
| Per-device dashboard stats | yes (Pi-hole sees real IPs) | yes (AGH groups by ClientID) |
| Let's Encrypt | not needed | required (HTTP-01 → port 80) |
| New Ansible roles | `wireguard` | `adguardhome` (+ `caddy` LE knobs) |
| Open-resolver risk | none | none (port 53 closed; only allow-listed ClientIDs reach AGH) |
| Bootstrap risk for *home* DNS | tunnel must come up before DHCP DNS flip | none — public endpoint immediately reachable |
| Failure mode if dnsvserver dies | home DNS dies until WG fallback | home DNS dies (or falls back to DHCP secondary) |
| Resource estimate (dnsvserver) | ~250 MB resident (Pi-hole stack) | ~390 MB resident (Caddy + AGH + Unbound) |

**Recommendation**: Option 1 is the cleaner, smaller, lower-attack-
surface path; pick it unless you have a concrete reason to expose DNS
to the public internet (e.g., friends/family using your filter
without a VPN client, or you simply don't want every device to be a
WireGuard peer). Option 2 is the right answer when public reachability
matters — and AGH is the right engine for it because ClientIDs are
first-class in AGH, while Pi-hole has no equivalent.

## Client-side DNS strategy (orthogonal to either option)

Either option above only solves "where DNS *can* be served from." A
separate decision is "what each client *uses*" depending on which
network it's on. The cleanest pattern, which composes with Option 1
in particular, is a three-state setup:

- **On public Wi-Fi / cellular** → encrypted DNS to a trusted public
  resolver (e.g. Mullvad's filtered DoH/DoT). Configured once on the
  device and used automatically wherever the device roams.
- **On home Wi-Fi** → DHCP-pushed DNS = home Pi-hole / AGH. The
  device's own override yields to the local network.
- **Roaming + want home filtering** → bring up the WireGuard tunnel.
  WG's `DNS =` directive points at the home resolver and overrides
  everything else for the duration.

**Apple devices (iPhone, iPad, Mac).** Use a `.mobileconfig` profile
(iOS 14+ / macOS 11+) to enforce DoH/DoT system-wide. Mullvad
publishes ready-made profiles at
[mullvad.net/.../dns-over-https-and-dns-over-tls](https://mullvad.net/en/help/dns-over-https-and-dns-over-tls).
For "Mullvad everywhere except home" behaviour, generate the profile
yourself (Apple Configurator 2 or any online generator) with an SSID
exclusion rule (`EvaluateConnection` → `SSIDMatch`) for the home
SSID. While the WireGuard tunnel is up, its `DNS =` overrides the
profile.

**Linux laptops.** No single `.mobileconfig` equivalent, but the
standard stack covers it cleanly:

1. **systemd-resolved global DNS = Mullvad DoT** — exactly what
   `os-base` already drops at
   `/etc/systemd/resolved.conf.d/10-os-base-dns.conf`. On a laptop
   this becomes the default-when-no-other-DNS-applies.
2. **NetworkManager per-connection override for home Wi-Fi** — on
   the home SSID profile, `ipv4.dns 192.168.1.231` and
   `ipv4.ignore-auto-dns yes`. When connected to home Wi-Fi, Pi-hole
   wins; everywhere else, systemd-resolved's global Mullvad config
   wins. Configurable via `nmcli` or GNOME / KDE network settings.
3. **WireGuard `[Interface] DNS =`** — same as on iOS. While `wg0`
   is up, systemd-resolved registers that DNS as the per-link
   resolver for `wg0` with `Domains=~.` so it wins over the global
   default.

If you want this codified across multiple laptops, a small
`roles/laptop-dns/` Ansible role bundling the resolved drop-in +
NetworkManager connection profile + WG config would do it. Future
PR; not blocking the dnsvserver decision.

**Heavier alternative**: `dnscrypt-proxy` running locally on the
laptop, listening on `127.0.0.1:53` with cloak / forward / per-route
rules. More configurable, more moving parts. Rarely needed when
resolved + NetworkManager already cover the three states above.

**How this composes with the two server options:**

- **Option 1 + this client strategy** → the natural fit. Home
  resolver is private (only reachable via WG or home LAN). Public
  DNS while roaming uses Mullvad directly, not your home stack —
  fewer hops, simpler. Bring up WG only when you want home filtering.
- **Option 2 + this client strategy** → still works, but redundant.
  Your devices have a public DoH endpoint they could always use; the
  Mullvad fallback is just defence-in-depth for "what if my own
  endpoint is down." Worth having as a fallback regardless.

---


# Option 1 — WireGuard tunnel (no public DNS exposure)


## Context

`dnsvserver` is a 1-core / 1 GB RAM AlmaLinux 9 vserver at a public IP
(31.70.73.76). The goal: run Pi-hole + Unbound there as the home
network's DNS, with the admin UI reachable from home devices, **without
exposing any DNS or HTTP service to the public internet**.

Earlier drafts considered a public DoH endpoint with Let's Encrypt and
either a DDNS-refreshed firewall allowlist (Pi-hole has no ClientID
auth) or a switch to AdGuard Home. The user instead chose the cleaner
path: a WireGuard tunnel between `homeserver` (homeserver, WG client + LAN
gateway) and `dnsvserver` (WG server). Public attack surface drops to
SSH (2343) + the WireGuard UDP port. Caddy stays on `tls internal`. No
Let's Encrypt, no DDNS, no open-resolver risk.

## Architecture

```
            internet
               │
               │   only ports exposed:
               │      22  (SSH on 2343)
               │      51820/udp (WG)
               ▼
   ┌─────────────────────────┐
   │      dnsvserver         │   31.70.73.76
   │  WireGuard server       │   wg0 = 10.10.0.1/24
   │  Pi-hole on 10.10.0.1   │   (binds wg0 only)
   │  Unbound on 127.0.0.1   │
   │  Caddy (tls internal)   │
   └────────────┬────────────┘
                │ WireGuard tunnel
                │ AllowedIPs = 10.10.0.0/24
                ▼
   ┌─────────────────────────┐
   │       homeserver             │   192.168.1.231
   │  WG client + gateway    │   wg0 = 10.10.0.2/24
   │  net.ipv4.ip_forward=1  │
   │  firewalld masquerade   │
   └────────────┬────────────┘
                │ home LAN
                ▼
        home devices ─ DNS = 10.10.0.1 (via DHCP)
                       (home router static route:
                        10.10.0.0/24 → 192.168.1.231)
```

Roaming peers (phone, laptop) connect directly to `dnsvserver`'s WG
endpoint when off home Wi-Fi; their `AllowedIPs` carries 10.10.0.0/24
and their DNS is set to 10.10.0.1. Off-WG, they use whatever DNS their
carrier provides.

The home router needs **one static route** added by hand: `10.10.0.0/24
via 192.168.1.231`. That's the only manual step outside Ansible.

## Approach

### 1. New role: `roles/wireguard/`

Single role, two modes via `wireguard_role: server | client`. Modeled
after `roles/os-audio/` (small, focused, idempotent).

Server mode (dnsvserver):
- Install `wireguard-tools`.
- Generate / load a server key from vault (don't auto-rotate — server
  pubkey shows up in every peer config).
- Render `/etc/wireguard/wg0.conf` from a template iterating over
  `wireguard_peers` (each peer: name, pubkey, allowed_ips,
  preshared_key from vault).
- Open the listen port (default 51820/udp) in firewalld.
- Add `wg0` to firewalld's `internal` zone so peer-to-peer and peer-to-
  service traffic is allowed without per-port rules.
- `systemctl enable --now wg-quick@wg0`.
- Set `net.ipv4.ip_forward = 1` only if `wireguard_forward: true`
  (off by default; we don't need this for our use case).

Client mode (homeserver):
- Install `wireguard-tools`.
- Render `/etc/wireguard/wg0.conf` from the same template, with
  `[Peer]` pointing at `dnsvserver`'s public endpoint.
- `systemctl enable --now wg-quick@wg0`.
- `net.ipv4.ip_forward = 1` (we DO need this — homeserver is the LAN
  gateway for the WG subnet).
- firewalld: add `wg0` to the `trusted` zone (trust intra-tunnel
  traffic), and add masquerading on the LAN-facing zone so home-LAN
  return packets find their way back through homeserver. (`firewall-cmd
  --zone=public --add-masquerade` if not already on; verify it
  doesn't break existing services.)

Variables:
```yaml
wireguard_role: ""                  # "server" or "client" — required
wireguard_listen_port: 51820        # server only
wireguard_subnet_v4: 10.10.0.0/24
wireguard_address: ""               # this host's WG address, e.g. 10.10.0.1/24
wireguard_private_key: "{{ vault_wireguard_private_key }}"
wireguard_peers: []                 # see below
wireguard_endpoint: ""              # client only — host:port of the server
wireguard_endpoint_pubkey: ""       # client only — server's pubkey
wireguard_endpoint_psk: ""          # client only — preshared key for that peer
wireguard_forward: false            # set true on hosts that act as gateways
```

A peer entry:
```yaml
- name: homeserver
  pubkey: "{{ vault_wireguard_homeserver_pubkey }}"
  allowed_ips: ["10.10.0.2/32", "192.168.1.0/24"]
  preshared_key: "{{ vault_wireguard_psk_homeserver }}"
- name: phone
  pubkey: "{{ vault_wireguard_phone_pubkey }}"
  allowed_ips: ["10.10.0.10/32"]
  preshared_key: "{{ vault_wireguard_psk_phone }}"
```

Note `homeserver`'s entry on the server includes `192.168.1.0/24` in
`allowed_ips` so dnsvserver knows packets *from* the home LAN are
legitimately routed via homeserver's WG endpoint. (Cross-routing is
optional and disabled by default; only enabled if a future use case
needs dnsvserver-initiated traffic into the home LAN.)

### 2. Pi-hole role: bind DNS to the WG interface

The current Pi-hole role uses `FTLCONF_dns_listeningMode=ALL` (binds on
every interface). On dnsvserver we'll override this per-host to bind
only on the WG IP — defense in depth on top of the firewall.

Pi-hole's quadlet exposes port 53 via podman port-forwarding; we change
the host-side bind to `10.10.0.1:53`. Concretely:

- Add a new role variable `pihole_dns_bind_ip: ""` (empty = default
  behavior, all interfaces).
- When set, the quadlet `PublishPort` becomes
  `{{ pihole_dns_bind_ip }}:53:1053/udp` and `:tcp` instead of
  `53:1053`.
- Set `pihole_dns_bind_ip: 10.10.0.1` in
  `host_vars/dnsvserver/main.yml`.

Caddy on dnsvserver reverse-proxies the Pi-hole admin UI as today
(8443 internal → `pihole.<caddy_domain>` on Caddy 443). Caddy itself
binds wherever `caddy_listen_port_https: 9443` is configured to map to
on the host; we override the host-side IP in the same way:
- Add `caddy_bind_ip: ""` in the caddy role; default empty.
- Set `caddy_bind_ip: 10.10.0.1` in `host_vars/dnsvserver/main.yml`.

For `caddy_domain` on dnsvserver, use a private name: `dns.lan` (or
whatever pattern you already use on homeserver). Pi-hole serves
`pihole.dns.lan` to peers as a local DNS record (auto-resolved to
10.10.0.1 because we add it via `pihole_local_dns_records`). Browsers
on home/roaming devices reach the admin UI via WG, and Caddy's
internal CA cert is trusted via the existing
`caddy-trust.mobileconfig` mechanism (or by importing the root cert
on each device).

### 3. firewalld on dnsvserver

Public zone (only):
- 22/tcp (the SSH port `bootstrap-host.sh` opened — actually 2343/tcp
  per inventory — verify and reuse, don't open standard 22).
- `wireguard_listen_port`/udp (default 51820).

Internal zone (`wg0`):
- All ports allowed for peers in the WG subnet. Pi-hole, Caddy,
  Unbound, etc., serve only via this interface.

The os-base / os-vserver pattern doesn't need changes: existing
firewalld+SELinux setup from the bootstrap script + service-role
quadlets covers what's needed.

### 4. firewalld on homeserver

Eddie now routes between LAN ↔ wg0:
- Add `wg0` to `trusted` zone.
- Enable masquerade on the `public` zone (or whatever `eth0`/lan zone
  is — verify on the host). Without masquerade, home LAN packets sent
  to 10.10.0.x get forwarded but return packets won't be SNAT'd, and
  dnsvserver replies will go straight back via WG to homeserver, then
  homeserver needs to relay to the original LAN client — which works only
  if dnsvserver knows the home subnet via `allowed_ips`. We're
  configuring it that way (above), so masquerade may not be strictly
  needed; but enabling it is safer and standard. **Verify both with
  and without** during deployment.

### 5. Inventory + playbook wiring

- `inventory/hosts.yml` — `dnsvserver` already in `vservers` ✅;
  `homeserver` in `homeservers`. No change to host membership.
- `host_vars/dnsvserver/main.yml` (private repo):
  ```yaml
  deploy_services: [caddy, pihole]
  wireguard_role: server
  wireguard_address: "10.10.0.1/24"
  wireguard_peers:
    - name: homeserver
      pubkey: "{{ vault_wireguard_homeserver_pubkey }}"
      allowed_ips: ["10.10.0.2/32", "192.168.1.0/24"]
      preshared_key: "{{ vault_wireguard_psk_homeserver }}"
    # roaming peers added later as needed
  caddy_domain: "dns.lan"
  caddy_bind_ip: "10.10.0.1"
  caddy_reverse_proxy_services:
    - { subdomain: pihole, port: 8443, proto: https }
  pihole_dns_bind_ip: "10.10.0.1"
  pihole_local_network: "10.10.0.0/24"
  pihole_local_router: "10.10.0.2"
  ```
- `host_vars/homeserver/main.yml` (private repo) — add WG client config:
  ```yaml
  wireguard_role: client
  wireguard_address: "10.10.0.2/24"
  wireguard_endpoint: "31.70.73.76:51820"
  wireguard_endpoint_pubkey: "{{ vault_wireguard_dnsvserver_pubkey }}"
  wireguard_endpoint_psk: "{{ vault_wireguard_psk_homeserver }}"
  wireguard_forward: true     # homeserver is LAN gateway for wg subnet
  ```
- `playbooks/site.yml` — add a second play for `hosts: vservers`
  that applies `os-base, wireguard, caddy, pihole`. Keep the existing
  `homeservers` play; just add `wireguard` to its role list (gated by
  the same `'wireguard' in deploy_services` pattern, OR
  unconditionally if `wireguard_role` is set). Simpler: condition the
  role on `wireguard_role | length > 0`. That way homeserver picks it up
  via host_vars without needing it in `deploy_services`.

### 6. Vault entries (private repo)

New vault keys to create with `ansible-vault encrypt_string`:
- `vault_wireguard_private_key` (per host: dnsvserver, homeserver)
- `vault_wireguard_dnsvserver_pubkey` (homeserver's view of the server)
- `vault_wireguard_homeserver_pubkey` (dnsvserver's view of homeserver)
- `vault_wireguard_psk_homeserver` (preshared key for that link)

Generation pattern (one-time, run locally):
```
wg genkey | tee dnsvserver.priv | wg pubkey > dnsvserver.pub
wg genkey | tee homeserver.priv      | wg pubkey > homeserver.pub
wg genpsk > homeserver.psk
ansible-vault encrypt_string "$(cat dnsvserver.priv)" --name vault_wireguard_dnsvserver_priv
# … and so on. Stuff into vars/vault.yml in private repo.
# Wipe the cleartext files afterward.
```

### 7. Home router static route (manual, documented)

Add a static route on the home router:
- `Destination: 10.10.0.0/24`
- `Gateway:     192.168.1.231`  (homeserver)

Without it, home devices that try to query `10.10.0.1:53` will send
packets to the default gateway (router), the router doesn't know
where 10.10.0.0/24 lives, and packets get dropped.

DHCP option for DNS server: change to `10.10.0.1`. Keep a fallback
(e.g., the router itself or 192.168.1.231) for the bootstrap window
while WG isn't yet up.

This step is documented in the new role's README — not automated.

## Files to modify

- `roles/wireguard/` — **new** (defaults, tasks, templates, README,
  handlers/main.yml for `wg-quick` reload).
- `roles/pihole/defaults/main.yml` — add `pihole_dns_bind_ip: ""`.
- `roles/pihole/templates/quadlets/pihole.container.j2` (or wherever
  PublishPort is rendered) — branch on `pihole_dns_bind_ip` to emit
  `<ip>:53:1053` vs `53:1053`.
- `roles/caddy/defaults/main.yml` — add `caddy_bind_ip: ""`.
- `roles/caddy/templates/quadlets/caddy.container.j2` — branch
  PublishPort on `caddy_bind_ip`.
- `playbooks/site.yml` — add `vservers` play; add `wireguard` role
  conditionally to both plays.
- `roles/wireguard/README.md` — document the manual home-router
  static route + the key-generation flow.

Private-repo additions (separate commit there):
- `inventory/host_vars/dnsvserver/main.yml` — populate as above.
- `inventory/host_vars/homeserver/main.yml` — append WG client section.
- `inventory/group_vars/all/vault.yml` (or wherever vault lives) —
  vault entries.

No changes needed to: `roles/os-base/`, `bootstrap-host.sh`, the
existing service-role list.

## What's deferred (separate PRs)

- **Onboarding script for new mobile peers** — generate keys, render
  a peer config + QR code, append to `wireguard_peers` in vault,
  re-run the role. A small `scripts/wg-add-peer.sh` is worth it once
  the third device joins.
- **Auto-restart on peer change** — currently a peer change requires
  re-running the role. wg-quick handlers already do `systemctl
  reload wg-quick@wg0`; verify that works without breaking active
  tunnels.
- **dnsvserver hardening beyond what bootstrap-host.sh did** —
  fail2ban, sshd MaxAuthTries, etc. Public IP is still exposed for
  SSH. Worth a follow-up.
- **AAAA / IPv6 handling** — left out for v1; everything here is v4.
  If the vserver hands out a /64 by default, we should at least
  document it and disable IPv6 on `wg0` rather than leaving an
  ambiguous half-config.

## Verification

1. **Syntax**: `ansible-playbook --syntax-check playbooks/site.yml`.
2. **Apply on dnsvserver first** (server side has to be up before
   homeserver can connect):
   ```
   ansible-playbook -i ../home-server-private/inventory/hosts.yml \
     playbooks/site.yml --limit dnsvserver
   ```
3. **Apply on homeserver**:
   ```
   ansible-playbook -i ../home-server-private/inventory/hosts.yml \
     playbooks/site.yml --limit homeserver
   ```
4. **Tunnel up**:
   ```
   ssh dnsvserver  'wg show wg0; ss -tlnp sport = :51820'
   ssh homeserver       'wg show wg0; ip route get 10.10.0.1'
   ssh homeserver       'ping -c2 10.10.0.1'
   ssh dnsvserver  'ping -c2 10.10.0.2'
   ```
5. **DNS via tunnel**:
   ```
   # From homeserver:
   dig @10.10.0.1 example.com +short
   # And the canary:
   dig @10.10.0.1 ad.doubleclick.net +short    # blocked by gravity
   # From a home LAN device (after router static route is in):
   dig @10.10.0.1 example.com +short
   ```
6. **Public surface**: from any non-home host on the internet,
   ```
   nmap -Pn -p 53,80,443,853 31.70.73.76    # all closed/filtered
   nmap -sU -Pn -p 53,51820 31.70.73.76     # 51820 open|filtered, 53 closed
   ```
7. **Pi-hole admin UI**: from a home device with the router route
   set, browse `https://pihole.dns.lan/admin/` — Caddy serves its
   internal CA cert, page loads, Pi-hole login appears.
8. **Idempotency**: re-run both playbooks; expect 0 changes.

## Risks and things to watch

- **Bootstrap chicken-and-egg**: the home router static route must
  exist before home devices can use Pi-hole as DNS, but you can't
  test the static route until WG is up. Order: deploy → verify with
  `dig @10.10.0.1` from homeserver (works without router route, since
  homeserver has the route in its kernel) → only then add the router
  route + flip DHCP DNS option.
- **WG stays up after reboot**: `wg-quick@wg0` is enabled, but
  systemd-networkd / NetworkManager interactions on RHEL are
  occasionally flaky. Verify with a deliberate `reboot` of each
  side after the initial deploy.
- **Pi-hole upstream chain**: the role's verify.yml resolves a few
  canary names. With Pi-hole binding only on wg0, the verify probe
  must run from somewhere reachable on wg0 — i.e., it queries from
  inside the Pi-hole container itself, which is fine. Watch for any
  task that tries `dig @<host-public-ip>`; rewrite to `@10.10.0.1`
  or `@127.0.0.1` (loopback inside the container).
- **MTU on the WG path**: default 1420 is usually fine, but if the
  home or dnsvserver provider has a low-MTU path (PPPoE, CGNAT
  tunneling), DNS UDP responses near 1500 bytes may fragment.
  Symptom: long answers (DNSSEC, AAAA-bundles) silently fail. Fix
  with `MTU = 1380` in `wg0.conf` if seen.
- **Single-link failure mode**: if dnsvserver's WG endpoint is
  unreachable (provider outage), home network has no DNS until
  failover. Mitigation: keep a secondary upstream (e.g., 9.9.9.9)
  in DHCP, or run a tiny `dnsmasq` quadlet on homeserver that forwards
  to 10.10.0.1 with 1.1.1.1 as fallback. Worth a small follow-up
  if uptime matters.
- **dnsvserver as an inbound-only firewall**: by default
  `wireguard_forward: false` on the server side, so a compromised
  peer can't pivot through dnsvserver to the public internet. Keep
  it that way unless a real use case appears.

---


# Option 2 — Public DoH endpoint via AdGuard Home, with ClientID auth + Caddy/Let's Encrypt admin UI

This option implements Sections 6.5 (per-device ClientID allowlist) and
6.6 (Caddy + Let's Encrypt admin UI hardening) from the Morpheus PDF.
The DNS engine for **dnsvserver** is **AdGuard Home (AGH)** rather
than Pi-hole — AGH has native DoH server, native ClientID allowlist,
and native bcrypt-hashed admin login, all of which Pi-hole only
approximates with extra moving parts. Pi-hole stays as the in-home
DNS engine on `homeserver` and is not affected by this option.

## Context

`dnsvserver` is a 1-core / 1 GB RAM AlmaLinux 9 vserver at a public IP
(31.70.73.76). The user wants:

1. A **public DoH endpoint** (`https://dns.<domain>/dns-query/<token>`)
   usable by stationary home and roaming mobile devices regardless of
   source IP — necessary because the home WAN IP is dynamic.
2. **Per-device authentication** via ClientID-style tokens. Public for
   reachability, private for *use*.
3. **Admin UI** reachable from the public internet over real Let's
   Encrypt TLS, with Caddy basic-auth in front of AGH's own login as
   defense in depth.
4. Open-source, free, self-hosted DNS engine — AGH (GPL-3.0,
   `github.com/AdguardTeam/AdGuardHome`) fits.

## Architecture

```
                   public internet
                         │
              dns.<domain> A → 31.70.73.76
                         │
       ┌─────────────────┴────────────────────┐
       │   firewalld (dnsvserver)              │
       │     22  (SSH 2343)        always      │
       │     80  (HTTP-01 ACME)    always      │
       │     443 (Caddy)           always      │
       │     53, 853  closed                   │
       └─────────────────┬────────────────────┘
                         ▼
              ┌─────────────────────────┐
              │  Caddy (public, LE)     │
              │                         │
              │  Routes:                │
              │  /dns-query/*    ───────┼──▶ AGH :8443  (no auth — AGH validates ClientID)
              │  *  (admin UI)   ───────┼──▶ basic_auth → AGH :8443
              └────────────┬────────────┘
                           ▼ loopback HTTP
              ┌─────────────────────────┐
              │  AdGuard Home           │
              │  ─ DoH at /dns-query/*  │
              │  ─ ClientID allowlist   │
              │  ─ Admin UI at /        │
              │  ─ Filter lists         │
              └────────────┬────────────┘
                           ▼ 127.0.0.1:5335
              ┌─────────────────────────┐
              │  Unbound (recursive,    │
              │  DNSSEC, loopback only) │
              └─────────────────────────┘
```

Public TCP ports: **22, 80, 443**. UDP: **none**. Port 80 stays open
for HTTP-01 ACME (and an http→https redirect Caddy serves). Port 53 is
never exposed — defeats open-resolver risk; AGH binds plain DNS on
loopback only, used only by AGH itself when it forwards to Unbound.

## How ClientID auth works (native to AGH)

AGH parses ClientIDs from the DoH URL path: `/dns-query/<clientid>`.
When `dns.allowed_clients` is set, only listed IDs (and IPs/CIDRs)
are accepted. Everything else returns SERVFAIL or 403 depending on
the path.

```yaml
# AdGuardHome.yaml (rendered by the role)
dns:
  allowed_clients:
    - cedric-iphone-7f3a
    - cedric-laptop-9c2e
    - familien-tablet-1a4d
```

Tokens go in vault under per-device names. The AGH role iterates over
`adguardhome_clientids` and renders the YAML. Token format: a
per-device random string (≥16 chars). Generation helper:
```
head -c 16 /dev/urandom | base32 | tr A-Z a-z | tr -d '='
```

Caddy doesn't need to know the tokens — it just forwards `/dns-query/*`
unconditionally, AGH does the actual allowlist check.

**Per-device visibility is preserved**: AGH's dashboard shows queries
broken out per ClientID, with separate stats, logs, and per-client
filter rules. This is the architectural reason AGH fits Option 2 and
Pi-hole doesn't.

## Approach

### 1. Add Let's Encrypt support to `roles/caddy/`

(Same change Option 1 doesn't need but Option 2 does.) Add per-host
knobs:

```yaml
# roles/caddy/defaults/main.yml
caddy_tls_mode: internal              # "internal" | "letsencrypt"
caddy_letsencrypt_email: ""           # required when mode=letsencrypt
caddy_letsencrypt_challenge: http     # "http" only for v1
```

Caddyfile template branches on `caddy_tls_mode`:
- `internal` → existing behavior (homeserver unchanged)
- `letsencrypt` → emit a global `email` directive, drop `tls internal`
  per site so Caddy auto-acquires per-site certs.

HTTP-01 only for v1. DNS-01 deferred until a registrar with API +
token is chosen.

### 2. Caddy: `proto: doh-agh` service kind + basic-auth on admin

Extend `caddy_reverse_proxy_services` with a new `proto` value:

```yaml
caddy_reverse_proxy_services:
  - subdomain: ""                # empty = root host (dns.<domain>)
    proto: doh-agh
    upstream_port: 8443          # AGH on loopback HTTP
    admin_basic_auth:
      user: admin
      password_hash: "{{ vault_dnsvserver_admin_caddy_hash }}"
```

The Caddyfile template gains a new branch for `proto: doh-agh`:

```
{{ caddy_domain }} {
    @doh path /dns-query/*
    handle @doh {
        reverse_proxy 127.0.0.1:8443
    }
    handle {
        basic_auth {
            admin <bcrypt-hash-from-vault>
        }
        reverse_proxy 127.0.0.1:8443
    }
}
```

Backwards compatible: existing `proto: http`/`https` entries on
homeserver keep their behavior.

Caddy's `basic_auth` directive expects bcrypt hashes; generate with
`caddy hash-password --plaintext '<pw>'` once and stash in vault.

### 3. New role: `roles/adguardhome/`

```
roles/adguardhome/
├── README.md
├── defaults/main.yml
├── tasks/main.yml
├── templates/
│   ├── AdGuardHome.yaml.j2          # full config
│   ├── unbound.conf.j2              # bundled, like pihole role does
│   ├── quadlets/adguardhome.container.j2
│   └── quadlets/unbound.container.j2
└── handlers/main.yml
```

Variables:
```yaml
adguardhome_image: "ghcr.io/adguardteam/adguardhome:latest"
adguardhome_listen_http: "127.0.0.1:8443"   # Caddy proxies in
adguardhome_dns_listen: "127.0.0.1:53"      # plain DNS, AGH-internal use
adguardhome_admin_user: admin
adguardhome_admin_password_hash: ""         # bcrypt; AGH stores it as-is
adguardhome_clientids: []                   # list of strings
adguardhome_filters:
  - "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"  # AGH default
  - "https://small.oisd.nl/"                                                # OISD small
adguardhome_enable_unbound: true
adguardhome_unbound_port: 5335
adguardhome_unbound_image: "docker.io/klutchell/unbound:latest"
adguardhome_run_verification: true
```

Pattern follows the existing `roles/pihole/` shape (rootless podman
quadlets, bundled Unbound container, verify-on-deploy task list).
Cleaner long-term: factor `roles/unbound/` out so both AGH and
Pi-hole roles include it; defer that to a follow-up PR to keep this
plan focused.

AGH HTTP listener binds loopback so only Caddy can reach it.

### 4. firewalld on dnsvserver

```
public zone:
  22/tcp     SSH (already opened by bootstrap-host.sh — verify port)
  80/tcp     HTTP-01 ACME
  443/tcp    Caddy
```

**Not** opened: 53, 853, anything UDP. Confirm with
`firewall-cmd --list-all`.

### 5. Inventory + playbook wiring

- `playbooks/site.yml` — add `vservers` play with role list
  `os-base, caddy, adguardhome`. Caddy stays mandatory in both plays.
- `inventory/host_vars/dnsvserver/main.yml` (private repo):
  ```yaml
  deploy_services: [caddy, adguardhome]
  caddy_domain: "<chosen-public-domain>"     # e.g. dns.example.com
  caddy_tls_mode: letsencrypt
  caddy_letsencrypt_email: "<user-email>"
  caddy_reverse_proxy_services:
    - subdomain: ""
      proto: doh-agh
      upstream_port: 8443
      admin_basic_auth:
        user: admin
        password_hash: "{{ vault_dnsvserver_admin_caddy_hash }}"
  adguardhome_admin_password_hash: "{{ vault_dnsvserver_agh_admin_hash }}"
  adguardhome_clientids:
    - "{{ vault_doh_clientid_cedric_iphone }}"
    - "{{ vault_doh_clientid_cedric_laptop }}"
  ```
- Vault entries (private repo):
  ```yaml
  vault_dnsvserver_admin_caddy_hash: "$2a$..."   # caddy hash-password
  vault_dnsvserver_agh_admin_hash: "$2a$..."     # AGH's own login (bcrypt)
  vault_doh_clientid_cedric_iphone: "abc123def4567890"
  vault_doh_clientid_cedric_laptop: "ghi456jkl0123456"
  ```

### 6. DNS A record (manual, prerequisite)

Before the first deploy, point an A record at dnsvserver's public IP
and wait for propagation:
```
dns.example.com.  3600  IN  A  31.70.73.76
```
HTTP-01 ACME will fail without this. If the registrar is Cloudflare,
the record must be **DNS only** (grey cloud) — proxy mode terminates
TLS and breaks end-to-end DoH privacy.

## Files to modify

- `roles/caddy/defaults/main.yml` — add `caddy_tls_mode`,
  `caddy_letsencrypt_email`, `caddy_letsencrypt_challenge`.
- `roles/caddy/templates/volumes/caddy-etc/Caddyfile.j2` — branch on
  `caddy_tls_mode`; add the new `proto: doh-agh` site block.
- `roles/caddy/README.md` — document new vars.
- `roles/adguardhome/` — **new** (defaults, tasks, templates, README,
  handlers, verify.yml).
- `playbooks/site.yml` — add `vservers` play.
- `inventory/host_vars/dnsvserver/main.yml` (private) — populate.
- `inventory/group_vars/all/vault.yml` (private) — add vault entries.

No changes to `roles/os-base/`, `roles/pihole/`, `bootstrap-host.sh`,
or other service roles.

## What's deferred (separate PRs)

- **DNS-01 ACME** — no port 80 needed, supports wildcards. Worth
  doing once a registrar with an API is chosen.
- **DoT support on 853** — AGH speaks DoT natively. With wildcard
  certs (DNS-01) you also get per-device DoT-subdomain ClientIDs
  cleanly. Both deferred until DNS-01 lands.
- **Token rotation script** — generate a new ClientID, append to
  vault, re-run the role. A `scripts/dns-add-client.sh` helper is
  worth it once devices >3.
- **Factor out `roles/unbound/`** — currently the pihole role
  bundles Unbound and this plan adds a second copy in the AGH role.
  Eventually one shared role. Not blocking.
- **fail2ban / sshd hardening on dnsvserver** beyond what the
  bootstrap script already did. Public-IP host worth additional care.

## Verification

1. **DNS A record live**: `dig +short dns.example.com → 31.70.73.76`.
2. **Syntax**: `ansible-playbook --syntax-check playbooks/site.yml`.
3. **Apply**:
   ```
   ansible-playbook -i ../home-server-private/inventory/hosts.yml \
     playbooks/site.yml --limit dnsvserver
   ```
4. **Cert acquired**:
   ```
   ssh dnsvserver
   sudo journalctl -u caddy --since '2 min ago' | grep "obtained certificate"
   curl -sI https://dns.example.com/                             # 401 (admin path)
   ```
5. **DoH with valid ClientID works**:
   ```
   kdig +https=/dns-query/<your-token> @dns.example.com cloudflare.com
   # Must return an answer with the "ad" flag (DNSSEC validated by Unbound).
   ```
6. **DoH with bad/missing ClientID is refused**:
   ```
   kdig +https=/dns-query @dns.example.com example.com           # SERVFAIL
   kdig +https=/dns-query/wrong-id @dns.example.com example.com  # SERVFAIL
   ```
7. **Admin UI reachable, both auth layers work**:
   ```
   curl -sI https://dns.example.com/                             # 401 (Caddy)
   curl -sI -u admin:<caddy-pw> https://dns.example.com/         # passes Caddy → AGH login
   ```
   Browse, log in via AGH UI with `vault_dnsvserver_agh_admin_hash`'s
   plaintext.
8. **No open DNS resolver**:
   ```
   dig @31.70.73.76 google.com                          # timeout
   nmap -sU -Pn -p 53 31.70.73.76                       # filtered
   nmap -Pn   -p 22,53,80,443,853 31.70.73.76           # only 22/80/443 open
   ```
9. **DNSSEC validation** (Unbound side):
   ```
   ssh dnsvserver
   podman exec unbound dig @127.0.0.1 -p 5335 dnssec-failed.org \
     | grep -E 'status:|flags:'
   # Expect status: SERVFAIL — proves DNSSEC enforcement.
   ```
10. **Per-ClientID stats in AGH**: log in, navigate to "Clients",
    confirm each ClientID appears with non-zero query counts after
    devices have used it briefly.
11. **Idempotency**: re-run; expect 0 changes.

## Risks and things to watch

- **Token-in-URL leakage**: any reverse-proxy / load-balancer / CDN /
  browser history / plaintext log between the client and Caddy will
  see the full URL including the ClientID. With direct device-to-Caddy
  TLS this isn't a concern; but don't put DoH through any third-party
  HTTPS proxy.
- **Public 443 attack surface**: Caddy's basic_auth + AGH's bcrypt
  login are both good, but the admin URL is at a well-known
  hostname. Worth setting up fail2ban-on-Caddy-401s as a follow-up.
- **Let's Encrypt rate limits**: 5 duplicate-cert failures per
  hostname earns a 168-hour ban. The HTTP-01 challenge needs port 80
  reachable on the **correct** IP — confirm the A record before first
  deploy.
- **Resource budget**: ~80 MB Caddy + ~80 MB AGH + ~80 MB Unbound +
  ~150 MB systemd/podman = ~390 MB resident, with 512 MB swap from
  os-base as fallback. Comfortably fits 1 GB; lighter than the
  Pi-hole+dnsdist alternative because AGH replaces both.
- **AGH config drift**: AGH writes back to `AdGuardHome.yaml` on UI
  changes. Re-running the role overwrites those changes. Two
  options: (a) treat the role-rendered file as authoritative (UI
  changes lost on next deploy — strict, predictable), or (b) only
  manage the file on first install and skip on subsequent runs
  (lossy, less reproducible). Default to (a); document loud, advise
  user to make config changes by editing host_vars + redeploying.
- **Switching engines later**: if Pi-hole at home (homeserver) and AGH on
  dnsvserver diverge in blocklists or per-client rules, they can drift.
  Worth standardizing on one filter set across both, or accepting
  drift as fine for the home/public split.
- **AGH upgrade cadence**: AGH releases monthly-ish. Fast-moving;
  occasionally introduces breaking config-format changes. The role's
  verify.yml should hard-fail on a broken render so a regression
  catches you before service downtime.
