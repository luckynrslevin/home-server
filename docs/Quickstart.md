# Quickstart

The fast path: get a working homeserver in under an hour, running
the setup directly on the server itself. No separate Ansible
control machine needed.

> [!TIP]
> Looking for a step-by-step wizard with progress bars instead of
> a single long page? Start with the
> **[Setup Guide](Setup-Guide/README.md)**.

## Prerequisites

You need an **AlmaLinux 9** machine you can SSH into, with these
two properties:

1. SSH login as a **non-root user** (e.g. `ds`, `admin`, your
   first name — anything but `root`).
2. That user has **passwordless sudo** (`ALL=(ALL) NOPASSWD:ALL` in
   `/etc/sudoers.d/`).

If you don't have that yet, pick one of the install methods below
and come back when you do:

- **[Kickstart on bare metal](Install-Kickstart.md)** — unattended
  AlmaLinux 9 install from USB or PXE on a mini-PC / NUC / repurposed
  laptop. Best when you have hardware in front of you and want
  reproducibility.
- **[Cloud-init self-provision](Install-CloudInit.md)** — paste a
  `user-data` blob into your VPS provider's "Create VM" form.
  *(Coming soon — see the [implementation plan](CloudInit-Self-Provision-Plan.md).)*
- **[VPS in the cloud](Install-VPS.md)** — pick AlmaLinux 9 at
  Hetzner / DigitalOcean / OVH / Linode, configure SSH access at
  VM-create time. Manual today; cloud-init route above will
  automate it.
- **[Manual install on hardware](Install-Manual.md)** — the
  AlmaLinux 9 Anaconda installer, click-through. Slowest but
  works on any hardware.

## Networking

Whichever install path you pick, the box must be a **direct host on
your home network** — not behind an additional NAT layer. If you're
using a VM (UTM, VirtualBox, Proxmox, …), configure it with
**bridged networking** so it gets its own IP address from your home
router, just like a physical machine.

Services like AirPlay (Shairport-sync) and DNS (Pi-hole) rely on
mDNS / Bonjour discovery and direct LAN connectivity, and won't work
correctly behind a NAT or on a virtual host-only network.

Also: pin the server's IP via a **DHCP reservation on your router**.
Several roles assume the server's LAN IP is stable (Caddy reverse
proxy hostnames, Pi-hole local DNS records). Lease drift will
eventually break them.

## Step 1 — SSH in as your sudo user

```bash
ssh youruser@<server-ip>
```

Confirm passwordless sudo works:

```bash
sudo -n true && echo "OK: sudo without password works"
```

If that prints `OK`, you're good. If it asks for a password,
configure the `NOPASSWD:ALL` sudoers drop-in first.

## Step 2 — Run the interactive setup script

> [!IMPORTANT]
> Run this **on the server** (i.e. via the SSH session you opened
> in Step 1) — **not on your laptop.** The script provisions the
> machine it runs on.

```bash
curl -fsSL https://raw.githubusercontent.com/luckynrslevin/home-server/main/setup.sh \
  -o /tmp/setup.sh && bash /tmp/setup.sh
```

The script is interactive — it walks you through:

1. Installs Ansible, podman, dependencies.
2. Clones the public repo into `~/home-server`.
3. Installs the Galaxy role dependency
   (`luckynrslevin.podman_quadlet`).
4. Walks you through inventory + host_vars setup, generates
   vault-encrypted secrets.
5. Lets you pick which services to deploy.
6. Runs `ansible-playbook playbooks/site.yml --connection=local
   --limit <hostname>` against the local box.

The server acts as **its own Ansible controller** — no separate
workstation needed.

When it finishes, open `https://<caddy_domain>/` in your browser to
see the dashboard. You should see a green padlock — Caddy issues
real Let's Encrypt certificates via DNS-01 against your deSEC
subdomain, so every device trusts them out of the box (no per-device
CA install).

## Step 3 — Hand off to Ansible from your laptop (optional)

If you'd rather drive the host from your laptop instead of staying
on the server, the project also supports the classic
"Ansible-host pushes to managed host" model. See the project
[README](../README.md) for that flow:

1. Run `scripts/bootstrap-host.sh` on the server to harden sshd
   (move off port 22, disable root login, disable password auth).
2. Set up the `home-server-private` overlay on your laptop with
   your inventory and vault.
3. Symlink the overlay into the public repo clone.
4. `ansible-playbook playbooks/site.yml --limit <host>` from the
   laptop.

## Troubleshooting

If `setup.sh` aborts mid-deploy, the partial state is safe to
re-run from — every role is idempotent. Re-running `setup.sh` from
the same checkout picks up where it left off.

For role-specific issues, each role has its own README under
`roles/<name>/README.md` with debugging notes.

## Resetting the host

To wipe all home-server artifacts and start fresh (does **not**
remove system packages or your primary user):

```bash
bash ~/home-server/scripts/clean-host.sh
```
