# Open an Ansible path to a fresh host

`scripts/bootstrap-host.sh` runs **on the target itself** (you SSH or
console in first) and prepares a freshly-installed RHEL-family host so
Ansible can take over from your laptop. Supported targets: RHEL,
AlmaLinux, Rocky, CentOS Stream, Oracle Linux (8 or 9), and Fedora.
The script checks `/etc/os-release` and refuses to run on anything
else (Debian/Ubuntu/Arch/…).

It does only what's needed for the handoff:

- ensures there is an admin user with passwordless sudo (creates one
  in root mode, promotes the invoking user in sudo mode — see below)
- installs your SSH public key for that user
- hardens sshd onto a non-default port (no root login, no password auth)
- opens the new port in firewalld and SELinux

Everything else (packages, hostname, services) belongs in Ansible
roles. Idempotent — safe to re-run.

## Two modes, decided automatically

The script branches on who runs it:

| Invoked as | Mode | Behaviour |
|---|---|---|
| `root` (e.g. you SSH'd in with the root password) | **root** | Creates a new sudo user (default name `ansible`, override with `-u`) and installs the key for them. |
| Any user via `sudo` (e.g. cloud-init's `fedora` / `almalinux` / `opc`) | **sudo** | Uses *that* user as the ansible user — installs the key into their `authorized_keys` and writes a permanent NOPASSWD sudoers drop-in. No new user is created. `-u` is ignored with a warning. |

Run without sudo and the script bails fast with an error.

## Quick start

SSH (or console) into the fresh target first, then on the target:

```bash
curl -fsSL https://raw.githubusercontent.com/luckynrslevin/home-server/refs/heads/main/scripts/bootstrap-host.sh \
  | sudo bash -s -- -k "ssh-ed25519 AAAA... you@laptop"
```

Always pipe through `sudo bash` — the script needs root and `sudo` is
a harmless no-op when you're already root. If you forget it, the
script exits with a clear error pointing you at this exact command.

The `-k` value is your **laptop's** public key — paste it as a string,
or `cat ~/.ssh/id_ed25519.pub` on the laptop and copy the output.

## Options

```
bootstrap-host.sh -k <ssh-pubkey> [-u <user>] [-p <port>]
```

| Flag | Default | Description |
|---|---|---|
| `-k <pubkey>` | required | SSH public key (full string) for the ansible user. |
| `-u <user>` | `ansible` | Username to create. **Root mode only** — ignored in sudo mode (the invoking user is used). |
| `-p <port>` | `2222` | New SSH port. |
| `-h` | — | Help. |

## What runs on the target

Six idempotent steps:

| # | Step |
|---|---|
| 1 | Ensure `python3`, `firewalld`, `policycoreutils-python-utils` are installed (only the missing ones). |
| 2 | Enable + start `firewalld`. |
| 3 | Root mode: create the user. Sudo mode: skip user creation. Both: write `/etc/sudoers.d/90-<user>` granting NOPASSWD. |
| 4 | Append the public key to `~<user>/.ssh/authorized_keys`, `restorecon -R`. |
| 5 | Open the new port in firewalld and label it `ssh_port_t` via `semanage`. |
| 6 | Write `/etc/ssh/sshd_config.d/99-bootstrap.conf` (Port + no root + no password), `sshd -t`, restart. |

Port 22 stays open in local firewalld as a safety net. Close it
yourself once you've verified the new port works (the script prints
the exact one-liner at the end).

## After it finishes

The script does not verify — it prints the exact next steps for you
to run from your laptop:

1. **External firewall** (cloud security group, edge router, hosting
   panel) — open `<port>/tcp`, close `22/tcp`. Skip if you have none.
2. **Verify**: `ssh -p <port> <user>@<host>` from your laptop.
3. **`~/.ssh/config`** — add a `Host` block (the script prints a
   ready-to-paste template).
4. **Close port 22** in local firewalld:
   `sudo firewall-cmd --permanent --remove-service=ssh && sudo firewall-cmd --reload`

Then hand off to Ansible:

```bash
ansible -i inventory/hosts.yml <host> -m ping
ansible-playbook playbooks/site.yml --limit <host>
```

## Topology

```
+----------+   ssh / console        +------------------+
|  laptop  |  ───────────────────►  | fresh host       |
|          |                        |  (you run        |
|          |                        |   bootstrap-host |
|          |                        |   here)          |
|          |   ssh -p <port>        +------------------+
|          |  ◄───────────────────  ssh listening on   |
|          |       (verify)          new port           |
|          |                                            |
|          |   ansible playbooks                        |
|          |  ───────────────────►                      |
+----------+                                            |
```
