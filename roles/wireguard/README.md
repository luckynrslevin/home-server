# wireguard

[WireGuard](https://www.wireguard.com) VPN server. Lets you reach
your home network — or just route Internet traffic — from outside.

The container does **not** request `SYS_MODULE`; the kernel's
`wireguard` module is expected to already be loaded on the host
(default on modern Fedora).

## Container image

`lscr.io/linuxserver/wireguard:latest` (override via
`wireguard_image`). LinuxServer's actively maintained image, served
from their own registry — no Docker Hub rate limits.

## Service user

`wireguard` (UID/GID 1004) — rootless.

## Variables

| Variable                | Default                              | Purpose                                              |
|-------------------------|--------------------------------------|------------------------------------------------------|
| `wireguard_image`       | `lscr.io/linuxserver/wireguard:latest` | Container image.                                   |
| `wireguard_srv_port`    | `61000`                              | UDP port exposed on the host.                        |
| `wireguard_srv_address` | `10.10.10.1/32`                      | Server end of the tunnel.                            |
| `wireguard_srv_dns`     | `""`                                 | Optional DNS pushed to clients via `wg0.conf`.       |
| `wireguard_peers`       | `[]`                                 | List of `{name, public_key, allowed_ips}` peer dicts.|

## Secrets

| Variable                 | Purpose                       |
|--------------------------|-------------------------------|
| `wireguard_srv_privkey`  | Server-side WireGuard private key. |

Generate and vault:

```bash
# WireGuard expects a base64-encoded 32-byte key
wg genkey | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'wireguard_srv_privkey'
```

Inspect:

```bash
ansible -i inventory/hosts.yml homeserver -m debug -a "var=wireguard_srv_privkey"
```

Peer **public** keys go into `wireguard_peers`. They aren't secrets,
but if you'd prefer to keep client identities private, vault them too.

## Firewall ports

- **`wireguard_srv_port`/udp** — VPN traffic (default `61000/udp`).

## Endpoints

No web UI. Configuration is in `wg0.conf` inside the
`wireguard-config` volume.

## Volumes

- `wireguard-config` — `/config`, including `wg0.conf`, server
  private key, and per-peer config files.

## Deployment

```bash
ansible-playbook playbooks/wireguard.yml --limit homeserver
```

The role renders `wg_confs/wg0.conf.j2` with the vaulted private
key, server address, optional DNS, and the peer list, then stages it
into the config volume.

## Choosing what the tunnel can reach

WireGuard itself only routes packets — what they're allowed to
reach is decided on the **router/firewall side**, not in this role.

- **Full tunnel (LAN + Internet):** allow forwarding from the VPN
  zone to both `lan` and `wan`.
- **Internet-only (insecure-wifi mode):** put `wg0` in its own
  firewall zone with masquerading on, and allow forwarding only to
  `wan` — not `lan`. Set the client's `AllowedIPs = 0.0.0.0/0, ::/0`.
