# Bootstrap a fresh host as an Ansible target

`scripts/bootstrap-host.sh` prepares a freshly-installed AlmaLinux 9
(or RHEL 9 / Rocky 9) machine to be managed by this project's Ansible
playbooks.

The script is a **remote driver**: you run it on your laptop (or any
Ansible-control machine), it SSHs to the new host as root, runs the
hardening payload, prompts you to update any external firewall, then
reconnects via the new port and user to verify everything works.

Symmetric layout with the rest of the project:

| Script | Run on | What it does |
|---|---|---|
| `setup.sh` | The **control machine** | Installs Ansible, clones the repo, walks you through inventory + vault + first deploy. |
| `scripts/bootstrap-host.sh` | The **control machine** | SSHs to a fresh managed host as root and prepares it for Ansible. |

Idempotent — safe to re-run.

---

## Prerequisites

**On the new host** (fresh install):

- Network reachability with sshd listening on port 22.
- Root login enabled with either a password or an SSH key you control.
  Most cloud providers (Hetzner, Netcup, OVH, Contabo, AWS, GCP, …)
  give you one of these by default.

**On your laptop**:

- `bash`, `ssh`. That's it.
- Your SSH **public** key file at hand (`~/.ssh/id_ed25519.pub`).
- The matching private key loaded in your ssh-agent (or available at a
  known path) so the verification step at the end can connect.

---

## Quick start

```bash
bash scripts/bootstrap-host.sh \
  -H 1.2.3.4 \
  -k "$(cat ~/.ssh/id_ed25519.pub)" \
  -n new-server
```

That's the whole interaction:

1. The script prints what it's about to do, then SSHs to root@1.2.3.4
   on port 22. If you don't have key auth as root, ssh prompts you for
   the password (one time).
2. Hardening runs remotely; the new sshd port (default 2222) is added
   to the host's local firewalld and SELinux. **Port 22 stays open**
   as a safety net.
3. The script pauses with a prompt: "Update any external firewall now
   (cloud security group, edge router, …) — open the new port,
   close 22 — then press Enter."
4. You press Enter. The script SSHs back in via the new port as the
   new user and runs `hostnamectl --static` to confirm.
5. If verification works, the script offers to also close port 22 in
   the host's **local** firewalld via the new SSH connection. Press
   `y` to do it now, or `n` and run that command later.

---

## Options

```
bootstrap-host.sh -H <host> -k <ssh-pubkey> [-u <user>] [-p <port>] [-n <hostname>]
```

| Flag | Default | Description |
|---|---|---|
| `-H <host>` | (required) | Target hostname or IP. The script connects as `root@<host>:22`. |
| `-k <pubkey>` | (required) | SSH public key (full string) to install for the new user. The key is installed in `~<user>/.ssh/authorized_keys` **before** sshd is hardened, so the verification step can authenticate. |
| `-u <user>` | `myuser` | Linux username to create. Validated against `^[a-z_][a-z0-9_-]{0,31}$`. |
| `-p <port>` | `2222` | SSH port to harden onto. firewalld + SELinux are updated to match. Validated as an integer 1–65535. |
| `-n <hostname>` | (unchanged) | Hostname to set via `hostnamectl`. RFC 1123 charset. Omit to leave the current hostname untouched. |
| `-h` | — | Show help and exit. |

The console keymap is set to `de` by default. If you want a different
layout, edit `NEW_KEYMAP` at the top of the script.

---

## What runs on the target (in order)

The remote payload performs these nine steps as root, all in a single
SSH session, all idempotent:

| # | Step |
|---|---|
| 1 | Enables EPEL, runs `dnf -y update`, installs prerequisites: `sudo`, `openssh-server`, `python3`, `python3-pip`, `policycoreutils-python-utils`, `firewalld`, `podman`, `bpytop`. Enables and starts `firewalld`. |
| 2 | Sets the hostname (only if `-n` was passed). |
| 3 | Sets the console keymap to `de` via `localectl`. |
| 4 | Creates the user (default `myuser`) with a home directory and bash login shell. |
| 5 | Drops `/etc/sudoers.d/90-<user>` granting passwordless sudo. Validated with `visudo -cf` before being made effective. |
| 6 | Creates `~<user>/.ssh/`, installs the public key into `authorized_keys` (idempotent — appended only if not already present), and runs `restorecon -R` on the directory to ensure SELinux labels are correct. |
| 7 | Opens the new SSH port in firewalld (`firewall-cmd --permanent --add-port=<port>/tcp`) and reloads. Port 22 stays open until phase 4. |
| 8 | Adds the new SSH port to SELinux's `ssh_port_t` set via `semanage`. Skipped if already labeled. |
| 9 | Writes `/etc/ssh/sshd_config.d/99-bootstrap.conf` with `Port`, `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`. Validates with `sshd -t` before restarting `sshd`. Runs `restorecon` on the file. |

Each step prints a `[N/9]` header so a partial failure is easy to
localize.

---

## Phases as the script itself sees them

| Phase | Where | What happens |
|---|---|---|
| 1 | `ssh root@host:22` | Run the nine remote-payload steps above. sshd is restarted onto the new port at the end. The active SSH session keeps running until the script ends because Linux preserves established connections across a daemon restart. |
| 2 | Local pause | Print a banner asking the user to update any external firewall (cloud security group, etc.). User presses Enter. |
| 3 | `ssh -p <new-port> <user>@host` | Verify connectivity with the new credentials. `hostnamectl --static` is run to confirm the host's identity. |
| 4 | `ssh -p <new-port> <user>@host` (optional) | If the user answers `y` to a final prompt, removes the `ssh` service from local firewalld so port 22 is no longer reachable. |

---

## SELinux notes

The script keeps SELinux **Enforcing** (the AlmaLinux/RHEL default) and
makes the necessary policy adjustments:

- A pre-flight check inside the remote payload reads `getenforce` and
  prints a warning (but does not abort) if SELinux is not currently
  Enforcing. Re-enable with `setenforce 1` and edit
  `/etc/selinux/config`.
- `semanage port -a -t ssh_port_t -p tcp <port>` allows sshd to bind
  the new port. Without this, `systemctl restart sshd` would fail
  even though the firewall rule and config look fine.
- `restorecon` is run on the files the script writes
  (`authorized_keys` and the sshd drop-in) so they get the correct
  policy-defined labels (`ssh_home_t` and `sshd_config_t`). Removes
  the "sometimes mysterious AVC denial" failure mode common when
  files are created via shell redirection rather than by the
  expected daemon.

If something fails with a permission-denied error after a clean run,
on the target check `ausearch -m avc -ts recent` for AVC denials.

---

## Failure recovery

The script uses `set -euo pipefail`, so it stops at the first error.

| Failure mode | What to check |
|---|---|
| `ssh root@<host>` rejects connection | Is the host actually up? Provider firewall blocking your IP from port 22? Wrong root password / key? |
| dnf install errors | Network reachability **from the target**, EPEL availability for the target's version. |
| `visudo -cf` fails | Should never happen with the generated content; if it does, inspect `/etc/sudoers.d/90-<user>` for damage. |
| `sshd -t` fails | Look at the printed message; the only file the script touched is `/etc/ssh/sshd_config.d/99-bootstrap.conf`. |
| `systemctl restart sshd` fails after `sshd -t` succeeded | Almost always SELinux — `journalctl -u sshd -n 50` and `ausearch -m avc -ts recent` on the target. |
| Phase 3 verification fails | External firewall not yet updated, ssh-agent missing the matching private key, or DNS/IP propagation delay. The banner walks through each. Port 22 on the target is still open at this point — you can ssh back in as root and remove `/etc/ssh/sshd_config.d/99-bootstrap.conf` to undo. |

The script keeps **port 22 open in local firewalld** until phase 4 is
explicitly accepted. That's your safety net: even if the new port
configuration breaks somehow, you can SSH in via the original port,
inspect, and fix.

---

## When to use this vs setup.sh

- Use **`setup.sh`** to turn a Fedora Server into the Ansible *control
  machine* (the one that runs `ansible-playbook`).
- Use **`scripts/bootstrap-host.sh`** to add a new *managed host* the
  control machine will then reach over SSH.

Some servers will be both — your control machine is also the host
running services. That's fine; run `setup.sh` and skip the bootstrap
script.

A typical multi-host topology after running both:

```
+--------------+    bootstrap-host.sh    +-------------------+
| control host |  ─────────────────────► | managed host #1   |
| (setup.sh)   |    bootstrap-host.sh    | (sshd hardened    |
|              |  ─────────────────────► | by remote driver) |
|              |                         +-------------------+
|              |    bootstrap-host.sh    +-------------------+
|              |  ─────────────────────► | managed host #2   |
+--------------+                         | (sshd hardened)   |
                                         +-------------------+
        ↑                                         │
        └─────── ansible playbooks ───────────────┘
              (ssh -p <new-port> <user>@host)
```

---

## After it finishes

The script ends with a banner that reminds you to add a `~/.ssh/config`
entry on your laptop and add the new host to your Ansible inventory:

```
Host new-server
  HostName 1.2.3.4
  User myuser
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
```

Then add to `inventory/hosts.yml` and deploy services:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --limit new-server
```
