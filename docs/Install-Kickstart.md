# Install method: Kickstart (unattended bare-metal install)

Use this when:

- You have a physical machine in front of you (mini-PC, NUC,
  repurposed laptop, …).
- You want a **reproducible**, unattended OS install — no clicking
  through the Anaconda installer, every install identical.
- You'll likely re-install this box more than once (testing,
  hardware swap, recovery from a bad state).

End state: AlmaLinux 9 booted, your SSH key authorized for a
non-root user, that user has passwordless sudo. Ready for the
[Quickstart](Quickstart.md).

## What's included

The repo ships an example kickstart at
[`!Linux-kickstart/ks.cfg`](../!Linux-kickstart/ks.cfg). Copy and
adapt it to your hardware:

| Setting | Where to change |
|---|---|
| Network device name | `network --device=enp1s0` (likely `eno1`, `eth0`, `enp2s0`, … on your hardware) |
| Hostname | `network --hostname=homeserver` |
| Disk device | `ignoredisk --only-use=nvme0n1` (or `sda`, `sdb`, …) and the matching `clearpart` line |
| Partition sizes | the `part` lines further down |
| User account | the `user` line — set username, group, password hash |
| SSH public key | `sshkey --username=...` line |
| Timezone | `timezone Europe/Berlin` |

> [!IMPORTANT]
> The kickstart wipes the target disk. Double-check the disk
> device name (`nvme0n1` vs `sda`) before booting it against your
> hardware.

## Step 1 — Prepare the install media

1. Download the **AlmaLinux 9 boot ISO** from
   [almalinux.org/get-almalinux](https://almalinux.org/get-almalinux/).
2. Flash it to a USB stick:
   ```bash
   sudo dd if=AlmaLinux-9.x-x86_64-boot.iso of=/dev/sdX bs=4M status=progress
   ```
   (replace `/dev/sdX` with your actual USB device — careful, this
   wipes it).

There's a helper script at
[`scripts/prepare-installer-usb.sh`](../scripts/prepare-installer-usb.sh)
that automates the dd step.

## Step 2 — Host the kickstart file

The installer needs to fetch `ks.cfg` over the network. Two
options:

- **Web server** — host it at any URL (your laptop running
  `python3 -m http.server`, a GitHub raw URL, an internal
  webserver, …).
- **USB second partition / second stick** — boot with
  `inst.ks=hd:LABEL=<label>:/path/ks.cfg`.

## Step 3 — Boot and pass the kickstart URL

At the AlmaLinux installer boot screen, press `Tab` (or `e` for
GRUB) to edit the kernel command line and append:

```
inst.ks=https://your.host/ks.cfg
```

Hit Enter. The installer runs unattended: partitions the disk,
installs packages, configures the user, reboots into the new
system.

## Step 4 — Verify SSH access

After reboot, from your laptop:

```bash
ssh youruser@<server-ip>
sudo -n true && echo "OK"
```

If `OK` prints, you're done. Continue with
[Quickstart](Quickstart.md) → Step 2.

## When to pick a different method

- Need a **cloud** box, not a physical one: see
  [Install-VPS.md](Install-VPS.md).
- Want the **fully-automated, paste-once** path on a cloud VPS: see
  [Install-CloudInit.md](Install-CloudInit.md).
- Doing a one-off hand-installed box where reproducibility doesn't
  matter: [Install-Manual.md](Install-Manual.md) is faster.
