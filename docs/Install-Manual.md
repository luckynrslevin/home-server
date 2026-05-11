# Install method: Manual install on hardware

Use this when:

- You have physical hardware and want to install **without** a
  kickstart file (one-off, exploratory, or you just prefer
  click-through).
- You're doing a single-shot install and don't expect to
  re-provision this box.

End state: AlmaLinux 9 booted on the hardware, you can SSH in as a
non-root sudo user. Ready for the [Quickstart](Quickstart.md).

If you'll be doing this more than once, the
**[Kickstart route](Install-Kickstart.md)** is faster and gives
you reproducible installs.

## Step 1 — Prepare the install media

1. Download the **AlmaLinux 9 DVD** ISO (full installer, ~10 GB)
   or the **boot ISO** (~900 MB, fetches packages over the
   network) from
   [almalinux.org/get-almalinux](https://almalinux.org/get-almalinux/).
2. Flash to a USB stick:
   ```bash
   sudo dd if=AlmaLinux-9.x-x86_64-dvd.iso of=/dev/sdX bs=4M status=progress
   ```
   (replace `/dev/sdX` carefully — this wipes the device).

There's a helper at
[`scripts/prepare-installer-usb.sh`](../scripts/prepare-installer-usb.sh).

## Step 2 — Boot the installer and click through

Insert the USB, boot the box, pick "Install AlmaLinux 9" at the
GRUB menu. The Anaconda installer comes up.

Walk through the installation steps:

1. **Language / keyboard / timezone** — set to your locale.
2. **Software selection** — pick **"Server"** (text-mode admin
   tools, no GUI). The Quickstart doesn't need GNOME or KDE.
3. **Installation destination** — pick the target disk. Use
   automatic partitioning unless you have a specific layout in
   mind.
4. **Network & host name** — connect the network interface, set
   the hostname to something memorable (e.g. `homeserver`).
5. **Root account** — set a strong root password. You'll disable
   root SSH later via `bootstrap-host.sh`, so this only matters
   for emergency console access.
6. **User creation** — **important**:
   - Create a normal user (e.g. `ds`, `admin`, your name).
   - **Tick "Make this user administrator"** — this adds the user
     to the `wheel` group and grants sudo access.
   - Set a password (you can disable password auth later via
     `bootstrap-host.sh`).
7. **Begin installation**, wait for it to finish, reboot.

## Step 3 — Configure passwordless sudo

By default, `wheel` group members can sudo *with* their password.
The setup script needs **passwordless** sudo. SSH in:

```bash
ssh youruser@<server-ip>
```

Then create a sudoers drop-in:

```bash
echo "youruser ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-youruser
sudo chmod 0440 /etc/sudoers.d/90-youruser
```

Verify:

```bash
sudo -n true && echo "OK"
```

## Step 4 — Install your SSH key

If you didn't add it during the installer:

From your **laptop**:

```bash
ssh-copy-id youruser@<server-ip>
```

Test that key auth works without prompting for a password:

```bash
ssh youruser@<server-ip> 'whoami'
```

## Step 5 — Continue with Quickstart

You now have an AlmaLinux 9 box with SSH-key access and
passwordless sudo. Continue with **[Quickstart](Quickstart.md)**
→ Step 2.
