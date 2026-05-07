# Bootstrap a fresh host as an Ansible target

`scripts/bootstrap-host.sh` prepares a freshly-installed AlmaLinux 9
(or RHEL 9 / Rocky 9) machine to be managed by this project's Ansible
playbooks. It's the symmetric counterpart to `setup.sh` at the repo
root:

| Script | Run on | What it does |
|---|---|---|
| `setup.sh` | The **control machine** | Installs Ansible, clones the repo, walks you through inventory + vault + first deploy. |
| `scripts/bootstrap-host.sh` | A **fresh managed host** | Creates the `ds` user, installs your SSH key, hardens sshd, installs Python (for Ansible) and Podman. |

The script is idempotent — safe to re-run.

---

## Prerequisites

- A freshly installed AlmaLinux 9, RHEL 9, or Rocky 9 host with network
  reachability and root login (typically via the provider's web VNC
  console for cloud VMs, or via the physical console for self-hosted
  hardware).
- Your laptop's SSH **public** key, accessible somehow. Usual options:
  - GitHub `.keys` endpoint (paste your public key into Settings →
    SSH and GPG keys, then `curl https://github.com/<user>.keys`).
  - A public gist (`gh gist create ~/.ssh/id_ed25519.pub --public`)
    optionally shortened via `is.gd`.
  - The provider's "send text" feature if VNC clipboard works.

> **Why this matters**: the script disables password authentication
> on sshd as a hardening step. If your key isn't in place when sshd
> restarts, you can be locked out. The script always installs the key
> *before* it disables passwords, but it can only do that if you
> actually pass it the key.

---

## Quick start (single command)

On the new host, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/luckynrslevin/home-server/main/scripts/bootstrap-host.sh \
  | sudo bash -s -- -k "$(curl -fsSL https://github.com/<your-gh-user>.keys | head -1)" \
                    -n new-server
```

`bash -s --` reads the script body from stdin and forwards everything
after `--` as positional arguments to that script.

If you prefer to inspect before running:

```bash
curl -fsSL -o /tmp/bootstrap.sh https://raw.githubusercontent.com/luckynrslevin/home-server/main/scripts/bootstrap-host.sh
less /tmp/bootstrap.sh        # optional: read what's about to run
sudo bash /tmp/bootstrap.sh -k "ssh-ed25519 AAAA... user@laptop"
```

---

## Options

```
bootstrap-host.sh -k <ssh-pubkey> [-u <user>] [-p <port>] [-n <hostname>]
```

| Flag | Default | Description |
|---|---|---|
| `-k <pubkey>` | (required) | SSH public key (full string) to install for the new user. The script installs this in `~<user>/.ssh/authorized_keys` **before** disabling password auth. |
| `-u <user>` | `ds` | Linux username to create. Validated against `^[a-z_][a-z0-9_-]{0,31}$`. |
| `-p <port>` | `2222` | SSH port to harden onto. firewalld + SELinux are updated to match. Validated as an integer 1–65535. |
| `-n <hostname>` | (unchanged) | Hostname to set via `hostnamectl`. RFC 1123 charset. Omit to leave the current hostname untouched. |
| `-h` | — | Show help and exit. |

The console keymap is set to `de` by default. If you want a different
layout, edit `NEW_KEYMAP` at the top of the script.

---

## What it does (in order)

| # | Step |
|---|---|
| 1 | Enables EPEL, runs `dnf -y update`, installs prerequisites: `sudo`, `openssh-server`, `python3`, `python3-pip`, `policycoreutils-python-utils`, `firewalld`, `podman`, `bpytop`. Enables and starts `firewalld`. |
| 2 | Sets the hostname (only if `-n` was passed). |
| 3 | Sets the console keymap to `de` via `localectl`. |
| 4 | Creates the user (default `ds`) with a home directory and bash login shell. |
| 5 | Drops `/etc/sudoers.d/90-<user>` granting passwordless sudo. Validated with `visudo -cf` before being made effective. |
| 6 | Creates `~<user>/.ssh/`, installs the public key into `authorized_keys` (idempotent — appended only if not already present), and runs `restorecon -R` on the directory to ensure SELinux labels are correct. |
| 7 | Opens the new SSH port in firewalld (`firewall-cmd --permanent --add-port=<port>/tcp`) and reloads. **Port 22 stays open** until you manually close it after verifying the new port works. |
| 8 | Adds the new SSH port to SELinux's `ssh_port_t` set via `semanage`. Skipped if already labeled. |
| 9 | Writes `/etc/ssh/sshd_config.d/99-bootstrap.conf` with `Port`, `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`. Validates with `sshd -t` before restarting `sshd`. Runs `restorecon` on the file to ensure correct SELinux labels. |

The script prints `[N/9]` headers for each step so a partial failure
is easy to localize.

---

## SELinux notes

This script keeps SELinux **Enforcing** (the AlmaLinux/RHEL default) and
makes the necessary policy adjustments:

- A pre-flight check reads `getenforce` and prints a warning (but does
  not abort) if SELinux is not currently Enforcing. Re-enable with
  `setenforce 1` and edit `/etc/selinux/config`.
- `semanage port -a -t ssh_port_t -p tcp <port>` allows sshd to bind
  the new port. Without this, `systemctl restart sshd` would fail
  even though the firewall rule and config look fine.
- `restorecon` is run on the files the script writes
  (`authorized_keys` and the sshd drop-in) so they get the correct
  policy-defined labels (`ssh_home_t` and `sshd_config_t`). Removes
  the "sometimes mysterious AVC denial" failure mode common when
  files are created via shell redirection rather than by the
  expected daemon.

If something does fail with a permission-denied error after a clean
run, check `ausearch -m avc -ts recent` for AVC denials.

---

## After it finishes

The script ends with a banner that recaps the verification and
lockdown steps:

### 1. Verify the new SSH port works

From your laptop (or any other machine that holds the matching
private key):

```bash
ssh -p <new-port> <user>@<host>
```

Test that key auth works and that root login + password auth are both
refused:

```bash
ssh -p <new-port> root@<host>            # → refused
ssh -p <new-port> -o PreferredAuthentications=password <user>@<host>   # → refused
```

### 2. Close port 22 in the firewall

Once the new port is verified working, on the host:

```bash
sudo firewall-cmd --permanent --remove-service=ssh
sudo firewall-cmd --reload
```

Done. The host is now reachable only via the new port.

### 3. (If applicable) Add a host alias on your laptop

Optional convenience. In `~/.ssh/config`:

```
Host new-server
  HostName <ip>
  User ds
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
```

Then `ssh new-server` works directly.

### 4. Add the host to your inventory

Edit `inventory/hosts.yml` (in your private inventory if you use the
two-repo split) and add the new host alongside the existing
`homeserver` / `homeserver-test` entries. Then deploy services:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --limit <new-host>
```

---

## Failure recovery

The script uses `set -euo pipefail`, so it stops at the first error.
If it fails partway through:

| Failure mode | What to check |
|---|---|
| dnf install errors | Network reachability, EPEL availability for your version. |
| `visudo -cf` fails | Should never happen with the generated content; if it does, inspect `/etc/sudoers.d/90-<user>` for damage. |
| `sshd -t` fails | Look at the printed message; the drop-in file in `/etc/ssh/sshd_config.d/99-bootstrap.conf` is the only file the script touched. |
| `systemctl restart sshd` fails after `sshd -t` succeeded | Almost always SELinux — `journalctl -u sshd -n 50` and `ausearch -m avc -ts recent`. |
| `semanage port -a` says port already labeled | Idempotency — already handled, the script continues. |

The fact that the script keeps **port 22 open** until you manually
close it is your safety net: even a bug that makes the new port
unreachable still leaves you able to SSH in via the original port.
Fix from there.

---

## When to use this vs setup.sh

- Use **`setup.sh`** when you want to turn a Fedora Server into the
  Ansible *control machine* (the one that runs `ansible-playbook`).
- Use **`scripts/bootstrap-host.sh`** when you want to add a new
  *managed host* that the control machine will then reach over SSH.

Some servers will be both — your control machine is also the host
running services. That's fine; run `setup.sh` and skip the bootstrap
script.

A typical multi-host topology:

```
+--------------+        SSH         +-------------------+
| control host |  ───────────────►  | managed host #1   |
| (setup.sh)   |        SSH         | (bootstrap-host)  |
|              |  ───────────────►  +-------------------+
|              |        SSH         +-------------------+
|              |  ───────────────►  | managed host #2   |
+--------------+                    | (bootstrap-host)  |
                                    +-------------------+
```
