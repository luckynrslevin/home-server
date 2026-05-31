# Install method: VPS in the cloud

Use this when:

- You want a homeserver-style stack running in the **cloud**, not
  at home (e.g. a public-facing DNS resolver, a cheap test box, a
  service that needs to be reachable while you're travelling).
- You don't have or don't want to run physical hardware.

End state: AlmaLinux 9 booted at a hosting provider, you can SSH
in as a non-root sudo user. Ready for the
[Quickstart](Quickstart.md).

> [!NOTE]
> The future [cloud-init self-provisioning](Install-CloudInit.md)
> path will combine the steps below with the full Ansible deploy
> in a single paste. Until that lands, this is the manual route.

## Picking a provider

Any provider that offers AlmaLinux 9 cloud images works. As of
today (2026):

| Provider | AL 9 images | Notes |
|---|:---:|---|
| Hetzner Cloud | ✓ | Cheapest mainstream EU host. €4–8/mo gets you a comfortable mini-homeserver. |
| DigitalOcean | ✓ | Marketplace + base images both available. |
| OVH / OVHcloud | ✓ | Usually the cheapest if you can tolerate the UI. |
| Linode (Akamai) | ✓ | Solid US/EU coverage. |
| Vultr | ✓ | Wide region selection. |
| Scaleway | ✓ | Strong EU privacy story. |
| AWS Lightsail | ✓ | Most expensive of the bunch for the same specs. |
| Google Cloud / Compute Engine | ✓ | Pay for what you use, more setup overhead. |

Pick on price + region + your existing accounts.

## Sizing

For the full default stack (Pi-hole + Caddy + Syncthing + Music
Assistant + Ente + Paperless + Jellyfin):

- **Minimum**: 4 GB RAM, 2 vCPU, 80 GB disk. Tight; works for one
  user.
- **Comfortable**: 8 GB RAM, 4 vCPU, 160 GB disk. Recommended.

For a **focused subset** (e.g. just DNS + Caddy + Syncthing):
1 GB RAM, 1 vCPU, 20 GB disk is enough. (See `dnsvserver` in
the example inventory for a small-footprint deploy.)

## Step 1 — Provision the VM

At the provider's "Create VM" page:

1. **OS image**: AlmaLinux 9.x.
2. **SSH key**: paste your laptop's `~/.ssh/id_ed25519.pub`. Most
   providers add it to the default cloud user's `authorized_keys`
   automatically via cloud-init.
3. **Cloud-init / user-data** field (optional but cleaner): paste
   a minimal block that creates a non-root user with passwordless
   sudo. See the snippet below.

Most providers' AlmaLinux 9 images create a default cloud user
called `almalinux` with passwordless sudo via cloud-init. If
that's the case, you can skip the user-data block — just SSH in
as `almalinux@<ip>`.

### Optional cloud-init snippet for a custom user

If you want a user with a name other than `almalinux`:

```yaml
#cloud-config
users:
  - name: ds
    groups: wheel
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... your-laptop-key
```

## Step 2 — SSH in and verify sudo

```bash
ssh almalinux@<vm-ip>      # or ds@<vm-ip> if you used the snippet
sudo -n true && echo "OK"
```

## Step 3 — Open the right inbound ports

For a public-facing homeserver you'll need at least:

- **22/tcp** during initial setup (move to a non-default port via
  `bootstrap-host.sh` after first deploy).
- **80/tcp + 443/tcp** for Caddy (web UIs).
- Whatever **Tailscale** needs (UDP 41641 for direct connections;
  most providers don't filter outbound, so usually nothing
  inbound to open).

Most cloud providers have a separate firewall layer (security
groups). Configure those alongside the host's `firewalld`.

## Step 4 — Continue with Quickstart

You now have an AlmaLinux 9 VPS with SSH access via a sudo user.
Continue with **[Quickstart](Quickstart.md)** → Step 2.

## Caveats for cloud deploys

The default `platform_services` + `apps` lists assume a home-LAN
context (NAS mounts, AirPlay, USB DAC, etc.). On a cloud VPS,
you'll want to pare them down. The example `dnsvserver` host in
the inventory is a good template for a small cloud-only deploy.
