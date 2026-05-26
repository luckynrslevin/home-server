# os-tailscale

Install and join [Tailscale](https://tailscale.com) — a mesh VPN that
gives every node a stable IP and DNS name on a private overlay,
without router config, NAT punching, or per-network setup. Free for
small tailnets (up to 100 devices, 3 users on the personal plan;
generous limits for self-hosting).

Use this role when you want a host reachable from your other
Tailscale-connected devices anywhere in the world, or to extend the
home LAN to roaming Macs / iPhones / Linux laptops.

## Supported distros

| Distro | Source |
|---|---|
| Fedora (any current release) | `pkgs.tailscale.com/stable/fedora` |
| AlmaLinux 9 / Rocky 9 / CentOS Stream 9 / RHEL 9 | `pkgs.tailscale.com/stable/rhel/9` |

Other distros: the role refuses to run. Tailscale ships its own RPMs
so no COPR / EPEL is involved.

## What it does

1. Adds the Tailscale repo (Fedora or RHEL-9 path picked
   automatically).
2. `dnf install tailscale`.
3. Enables and starts `tailscaled`.
4. Reads `tailscale status --json` to detect login state.
5. **First run** — if not yet logged in:
   - With `os_tailscale_auth_key` set → runs `tailscale up
     --auth-key=… --hostname=… [--advertise-routes …] …`
     unattended.
   - Without an auth key → emits a debug line telling you to run
     `sudo tailscale up` manually, then re-apply the role.
6. **Subsequent runs** — applies route / exit-node / accept-dns /
   accept-routes / ssh settings via `tailscale set`. Lets you flip
   knobs without re-authenticating. Tag changes still need a manual
   `tailscale up --reset`.

## Variables

See `defaults/main.yml`. Common knobs:

| Variable | Default | Purpose |
|---|---|---|
| `os_tailscale_auth_key` | `""` | Vault-encrypted reusable / single-use auth key from the admin console. Empty = manual login. |
| `os_tailscale_hostname` | `inventory_hostname` | The label that appears in the admin console. |
| `os_tailscale_advertise_routes` | `[]` | List of CIDRs to advertise as subnet routes (e.g. `["192.168.1.0/24"]`). Routes also need approval in the admin console. |
| `os_tailscale_tags` | `[]` | Tags to apply at first login, e.g. `["tag:server"]`. Must be pre-declared in the tailnet ACL. |
| `os_tailscale_advertise_exit_node` | `false` | Set true to offer this node as an exit node. |
| `os_tailscale_accept_dns` | `true` | Accept the tailnet's DNS push (MagicDNS, override resolvers). Lets homeserver-hosted Pi-hole serve the whole tailnet when configured in admin DNS settings. |
| `os_tailscale_accept_routes` | `true` | Accept routes advertised by other nodes. Required if you want to reach LANs subnet-routed through other tailnet nodes. |
| `os_tailscale_ssh` | `false` | Enable Tailscale-mediated SSH (replaces public-key auth with tailnet identity). Off by default — opt in per host. |

## First-time setup

1. **Generate an auth key** in the
   [admin console](https://login.tailscale.com/admin/settings/keys)
   — Reusable + Ephemeral or single-use, your call. Optionally
   pre-tag it (`tag:server`) so the node lands with that tag.
2. **Stash it in vault**:
   ```bash
   ansible-vault encrypt_string '<paste-key>' --name vault_os_tailscale_auth_key
   ```
3. **Set host_vars**:
   ```yaml
   os_tailscale_auth_key: "{{ vault_os_tailscale_auth_key }}"
   os_tailscale_advertise_routes: ["192.168.1.0/24"]   # optional
   ```
4. **Apply** as part of `playbooks/site.yml` (this role is in the
   default role list once added) or with a one-off:
   ```bash
   ansible-playbook -i ../home-server-private/inventory/hosts.yml \
     playbooks/site.yml --limit homeserver --tags os-tailscale
   ```
5. **Approve routes** in the admin console under Machines → homeserver →
   Edit route settings (subnet routes don't enable themselves).

## Manual login (no auth key)

If you'd rather not put an auth key in vault, leave the variable
empty and complete login interactively after the role applies:

```bash
ssh homeserver sudo tailscale up
```

The command prints a `https://login.tailscale.com/a/...` URL — open
on any device already logged into your tailnet, click Connect.
Re-run the role afterwards to push the runtime settings.

## Verification

```bash
ssh homeserver tailscale status      # node listed, status "active"
ssh homeserver tailscale ip          # prints the 100.x.y.z IP
# from any other tailnet device:
tailscale ping homeserver            # round-trip succeeds
ssh user@homeserver                  # if --ssh enabled, no password prompt
```

If Tailscale's MagicDNS is enabled in the admin console, the node is
also reachable as `homeserver.<your-tailnet>.ts.net` from every tailnet
device.

## Common follow-ups

- **Use homeserver's Pi-hole as the tailnet resolver** — admin console →
  DNS → add homeserver's Tailscale IP → "Override local DNS." Now
  `*.homeserver.lan` resolves on every tailnet device, anywhere.
- **Subnet routing for the home LAN** — set
  `os_tailscale_advertise_routes: ["192.168.1.0/24"]`, run the
  role, approve in admin console. Mac/iPhone via Tailscale can
  then reach `192.168.1.x` directly.
- **Replace `caddy_domain: homeserver.lan` with a real public name** —
  not required, just an option once tailnet covers all clients.
