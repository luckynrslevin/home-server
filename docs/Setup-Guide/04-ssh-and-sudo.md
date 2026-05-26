# Step 4 — SSH in & verify sudo

> **Setup Guide** · Step 4 of 6 · ▰▰▰▰▱▱ 67% · ~30 min spent · ~25 min to go
> [← Step 3: Install OS](03-install-os.md) · **Step 4: SSH & sudo** · [Step 5: Run homeserver.sh →](05-run-setup.md)

The shortest step. ~3 minutes — confirm you can SSH in and that
your user can run `sudo` without a password.

## What you'll do

### 1. SSH in from your laptop

```bash
ssh youruser@<server-ip>
```

(Replace `youruser` and `<server-ip>` with what you set up in
Step 2. If you used a cloud VPS image with cloud-init's default
user, try `ssh almalinux@<server-ip>`.)

You should land at a shell prompt without being asked for a
password (key-based auth).

### 2. Verify passwordless sudo

In that SSH session, run:

```bash
sudo -n true && echo "OK"
```

If it prints **OK**, you're done — skip to the next step.

If it asks for a password, you need to configure passwordless
sudo:

```bash
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-$USER
sudo chmod 0440 /etc/sudoers.d/90-$USER
```

You'll be prompted for the sudo password *once* during this. After
that, re-run `sudo -n true && echo "OK"` — it should print **OK**
this time.

### Why passwordless sudo?

`homeserver.sh` in Step 4 runs a bunch of `sudo dnf install` /
`sudo systemctl` / etc. calls non-interactively. If sudo prompts
for a password mid-install, the script can't answer it from a
piped heredoc. NOPASSWD is the standard pattern for an admin user
that drives automation on their own box.

## Sanity check

You should now be:

- SSH'd into the server as your non-root user.
- Able to run `sudo -n true` without a prompt.

## Time check

| Step | Status | Time |
|---|---|---|
| 1 — deSEC account | ✅ done | ~5 min |
| 2 — SMTP account | ✅ done | ~5 min |
| 3 — Install OS | ✅ done | ~20–60 min |
| 4 — SSH & sudo | ✅ done | ~3 min |
| 5 — Run homeserver.sh | next | ~20 min |
| 6 — Verify & explore | | ~2 min |

➡️ **[Step 5: Run homeserver.sh](05-run-setup.md)**
