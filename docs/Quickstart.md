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

## Step 3 — Day-2 lifecycle commands

`setup.sh` is also the entry point for everything after the initial
install. Operators rarely need to invoke ansible directly.

```bash
setup.sh add <service>          # add a service that wasn't picked at install
setup.sh add                    # (no args) list available services + descriptions
setup.sh remove <service>       # remove a service; data volumes preserved
setup.sh remove <service> --purge   # remove + delete data volumes
setup.sh upgrade                # bump within current major release, re-deploy
setup.sh backup                 # trigger the backup systemd service now
setup.sh restore                # restore from latest NAS backup
setup.sh uninstall              # full wipe (= scripts/clean-host.sh)
setup.sh --help                 # all verbs + flags
```

Examples:

```bash
# I picked syncthing during install but actually want Paperless too:
setup.sh add paperless-ngx

# Upgrade to the latest v2.x release after a few weeks:
setup.sh upgrade

# Decommission Jellyfin but keep its media volume for now:
setup.sh remove jellyfin
```

Each verb is idempotent and prints the underlying ansible command on
error so power users can drop down to `ansible-playbook` if they want
to debug deeper. Adding a brand-new service to the project (writing a
new role) is the only flow that doesn't go through `setup.sh`.

## Hand off to Ansible from your laptop (optional)

If you'd rather drive the host from your laptop instead of staying
on the server, the project also supports the classic
"Ansible-host pushes to managed host" model. See the project
[README](../README.md) for that flow.

## Troubleshooting

If `setup.sh install` aborts mid-deploy, the partial state is safe to
re-run from — every role is idempotent. Re-running picks up where it
left off.

For role-specific issues, each role has its own README under
`roles/<name>/README.md` with debugging notes.

## Resetting the host

To wipe all home-server artifacts and start fresh (does **not**
remove system packages or your primary user):

```bash
setup.sh uninstall
```
