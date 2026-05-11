# Step 2 — Install the OS

> **Setup Guide** · Step 2 of 5 · ▰▰▱▱▱ 40% · ~5 min spent · ~45 min to go
> [← Step 1: deSEC account](01-deSEC-account.md) · **Step 2: Install OS** · [Step 3: SSH & sudo →](03-ssh-and-sudo.md)

You'll install **AlmaLinux 9** on your hardware (or VPS). Pick the
sub-method that fits your situation — each is a separate detailed
doc; come back here when finished.

## Pick your path

### A — Bare-metal, unattended (recommended for repeat installs)

You have a mini-PC, NUC, or repurposed laptop and want a
reproducible install. The kickstart file does it without
clicking through the installer.

⏱️ **~20 min** (5 min USB prep + 15 min unattended install).

➡️ **[Install-Kickstart.md](../Install-Kickstart.md)**

---

### B — Bare-metal, click-through (one-off install)

Same hardware story but you'd rather use the Anaconda installer
GUI. Slightly slower; useful for a one-off.

⏱️ **~45 min** (5 min USB prep + 40 min click-through + first-boot).

➡️ **[Install-Manual.md](../Install-Manual.md)**

---

### C — Cloud VPS (Hetzner / DigitalOcean / OVH / Linode / …)

You don't want physical hardware — just a virtual server in the
cloud.

⏱️ **~15 min** (provider-side click-through; no flashing).

➡️ **[Install-VPS.md](../Install-VPS.md)**

---

### D — Cloud-init self-provision _(coming soon)_

Paste a `user-data` blob into a cloud provider's "Create VM"
form, walk away, come back to a fully-deployed homeserver. Not
yet implemented — tracked in
[issue #106](https://github.com/luckynrslevin/home-server/issues/106).

## What you'll have when you come back

Whichever path you pick, you should end Step 2 with:

- AlmaLinux 9 booted on the machine.
- An **IP address** for the server (note it down).
- An SSH-reachable **non-root user account** on the server, with
  your laptop's SSH public key in its `~/.ssh/authorized_keys`.

## Time check

| Step | Status | Time |
|---|---|---|
| 1 — deSEC account | ✅ done | ~5 min |
| 2 — Install OS | in progress | ~20–60 min |
| 3 — SSH & sudo | next | ~3 min |
| 4 — Run setup.sh | | ~20 min |
| 5 — Verify & explore | | ~2 min |

➡️ **[Step 3: SSH in & verify sudo](03-ssh-and-sudo.md)**
