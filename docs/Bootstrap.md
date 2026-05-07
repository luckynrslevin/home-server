# Open an Ansible path to a fresh host

`scripts/bootstrap-host.sh` does the bare minimum needed for Ansible to
take over on a freshly-installed AlmaLinux 9 / RHEL 9 / Rocky 9 host:

- Creates an `ansible` user with passwordless sudo
- Installs your SSH public key for that user
- Hardens sshd onto a non-default port, disables root login + password auth
- Opens the new port in firewalld and SELinux

That's it. Everything else (packages, hostname, container runtime,
services, monitoring) belongs in Ansible roles, where it stays
idempotent and reviewable. The bootstrap is intentionally a thin wedge.

The script is a **remote driver**: you run it on your laptop / control
machine, it SSHs to the new host as root, runs the hardening, prompts
you to update any external firewall, then verifies via the new
connection.

| Script | Run on | What it does |
|---|---|---|
| `setup.sh` | Control machine | Installs Ansible, clones the repo, walks you through inventory + vault + first deploy. |
| `scripts/bootstrap-host.sh` | Control machine | SSHs to a fresh managed host as root and prepares it for Ansible. |

Idempotent — safe to re-run.

---

## Prerequisites

**On the new host** (fresh install):

- Network reachability with sshd listening on port 22
- Root login enabled with either a password or an SSH key you control
- `python3` (default on AlmaLinux 9; the script installs it if missing)

**On your laptop**:

- `bash`, `ssh`
- Your SSH **public** key file at hand (`~/.ssh/id_ed25519.pub`)
- The matching private key loaded in your ssh-agent (or available at a
  known path) so the verification step can authenticate

---

## Quick start

```bash
bash scripts/bootstrap-host.sh -H 1.2.3.4 -k "$(cat ~/.ssh/id_ed25519.pub)"
```

The whole interaction:

1. The script SSHs to root@1.2.3.4 on port 22. If you don't have key
   auth as root, ssh prompts you for the password (one time).
2. Hardening runs remotely; the new sshd port (default 2222) is added
   to the host's local firewalld and SELinux. **Port 22 stays open**
   as a safety net.
3. The script pauses with a prompt: "Update any external firewall now
   (cloud security group, edge router, …) — open the new port,
   close 22 — then press Enter."
4. You press Enter. The script SSHs back as `ansible` on the new port
   and runs `whoami` + `hostnamectl --static` to confirm.
5. If verification works, the script offers to also close port 22 in
   the host's **local** firewalld via the new SSH connection.

---

## Options

```
bootstrap-host.sh -H <host> -k <ssh-pubkey> [-u <user>] [-p <port>]
```

| Flag | Default | Description |
|---|---|---|
| `-H <host>` | (required) | Target hostname or IP. The script connects as `root@<host>:22`. |
| `-k <pubkey>` | (required) | SSH public key (full string) to install for the new user. Installed in `~<user>/.ssh/authorized_keys` **before** sshd is hardened, so the verification step can authenticate. |
| `-u <user>` | `ansible` | Linux username to create. Validated against `^[a-z_][a-z0-9_-]{0,31}$`. |
| `-p <port>` | `2222` | SSH port to harden onto. firewalld + SELinux are updated to match. Validated as an integer 1–65535. |
| `-h` | — | Show help and exit. |

Things this script does **not** do (Ansible's job):

- Install `bpytop`, `podman`, or any other application
- Run `dnf -y update`
- Set hostname (use Ansible host_vars + a small role)
- Set console keymap

---

## What runs on the target (in order)

The remote payload performs these six steps as root, all in a single
SSH session, all idempotent:

| # | Step |
|---|---|
| 1 | Ensure prerequisites: `python3`, `firewalld`, and `policycoreutils-python-utils` (for `semanage`). Conditional install — only the missing ones get fetched. |
| 2 | Enable + start `firewalld`. |
| 3 | Create the user (default `ansible`) with home + bash + passwordless sudo via `/etc/sudoers.d/90-<user>` (validated with `visudo -cf`). |
| 4 | Create `~<user>/.ssh/`, append the public key to `authorized_keys` (idempotent), `restorecon -R`. |
| 5 | Open the new SSH port in firewalld (`firewall-cmd --permanent --add-port=<port>/tcp`) and label it `ssh_port_t` via `semanage`. Port 22 stays open until phase 4. |
| 6 | Write `/etc/ssh/sshd_config.d/99-bootstrap.conf` (`Port`, `PermitRootLogin no`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`), `restorecon`, validate with `sshd -t`, restart sshd. |

Each step prints a `[N/6]` header so a partial failure is easy to
localize.

---

## Phases as the script itself sees them

| Phase | Where | What |
|---|---|---|
| 1 | `ssh root@host:22` | Run the six remote-payload steps. sshd is restarted onto the new port at the end. The active SSH session keeps running because Linux preserves established connections across a daemon restart. |
| 2 | Local pause | Print a banner asking to update any external firewall (cloud security group, etc.). User presses Enter. |
| 3 | `ssh -p <new-port> <user>@host` | Verify connectivity with the new credentials. |
| 4 | `ssh -p <new-port> <user>@host` (optional) | If accepted, removes the `ssh` service from the host's local firewalld. |

---

## Failure recovery

The script uses `set -euo pipefail`, so it stops at the first error.

| Failure mode | What to check |
|---|---|
| `ssh root@<host>` rejects connection | Is the host actually up? Provider firewall blocking your IP from port 22? Wrong root password / key? |
| dnf install fails | Network reachability **from the target**, AppStream availability for the target's version. |
| `visudo -cf` fails | Should never happen with the generated content; if it does, inspect `/etc/sudoers.d/90-<user>` for damage. |
| `sshd -t` fails | The only file the script touched is `/etc/ssh/sshd_config.d/99-bootstrap.conf`. |
| `systemctl restart sshd` fails after `sshd -t` succeeded | Almost always SELinux — `journalctl -u sshd -n 50` and `ausearch -m avc -ts recent` on the target. |
| Phase 3 verification fails | External firewall not yet updated, ssh-agent missing the matching private key, or DNS/IP propagation delay. The banner walks through each. Port 22 on the target is still open at this point — you can ssh back in as root and remove `/etc/ssh/sshd_config.d/99-bootstrap.conf` to undo. |

The script keeps **port 22 open in local firewalld** until phase 4 is
explicitly accepted. That's your safety net: even if the new port
configuration breaks somehow, you can SSH in via the original port,
inspect, and fix.

---

## After it finishes

Add a `~/.ssh/config` entry on your laptop:

```
Host new-server
  HostName 1.2.3.4
  User ansible
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
```

Sanity-check Ansible can reach the host:

```bash
ansible -i inventory/hosts.yml new-server -m ping
```

Expect `pong`. Then deploy services as usual:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --limit new-server
```

---

## When to use this vs setup.sh

- Use **`setup.sh`** to turn a Fedora Server into the Ansible *control
  machine* (the one that runs `ansible-playbook`).
- Use **`scripts/bootstrap-host.sh`** to add a new *managed host* the
  control machine will then reach over SSH.

Some servers will be both — your control machine is also the host
running services. That's fine; run `setup.sh` and skip the bootstrap
script.

```
+--------------+    bootstrap-host.sh    +-------------------+
| control host |  ─────────────────────► | managed host #1   |
| (setup.sh)   |    bootstrap-host.sh    | (sshd hardened    |
|              |  ─────────────────────► | + ansible user)   |
|              |                         +-------------------+
|              |    bootstrap-host.sh    +-------------------+
|              |  ─────────────────────► | managed host #2   |
+--------------+                         | (sshd hardened)   |
                                         +-------------------+
        ↑                                         │
        └─────── ansible playbooks ───────────────┘
              (ssh -p <new-port> ansible@host)
```
