# Open an Ansible path to a fresh host

`scripts/bootstrap-host.sh` runs from your **laptop** and prepares a
freshly-installed RHEL-family host so Ansible can take over. Supported
targets: RHEL, AlmaLinux, Rocky, CentOS Stream, Oracle Linux (8 or 9),
and Fedora. The script checks `/etc/os-release` and refuses to run on
anything else (Debian/Ubuntu/Arch/…).

It does only what's needed for the handoff:

- creates an `ansible` user with passwordless sudo
- installs your SSH public key for that user
- hardens sshd onto a non-default port (no root login, no password auth)
- opens the new port in firewalld and SELinux

Everything else (packages, hostname, services) belongs in Ansible
roles. Idempotent — safe to re-run.

## Quick start

```bash
bash scripts/bootstrap-host.sh -H 1.2.3.4 -k "$(cat ~/.ssh/id_ed25519.pub)" -p 2222
```

The script SSHs from your laptop to `root@1.2.3.4:22` (password or key
auth), runs the hardening, pauses for you to update any external
firewall (cloud security group: open the new port, close 22), then
SSHs back as `ansible` on the new port to verify. Optionally also
closes port 22 in the host's local firewalld at the end.

## Options

```
bootstrap-host.sh -H <host> -k <ssh-pubkey> [-u <user>] [-p <port>]
```

| Flag | Default | Description |
|---|---|---|
| `-H <host>` | required | Target hostname or IP. |
| `-k <pubkey>` | required | SSH public key (full string) for the new user. |
| `-u <user>` | `ansible` | Username to create. |
| `-p <port>` | `2222` | New SSH port. |
| `-h` | — | Help. |

## What runs on the target

Six idempotent steps inside one SSH session as root:

| # | Step |
|---|---|
| 1 | Ensure `python3`, `firewalld`, `policycoreutils-python-utils` are installed (only the missing ones). |
| 2 | Enable + start `firewalld`. |
| 3 | Create the user with passwordless sudo via `/etc/sudoers.d/90-<user>`. |
| 4 | Append the public key to `~<user>/.ssh/authorized_keys`, `restorecon -R`. |
| 5 | Open the new port in firewalld and label it `ssh_port_t` via `semanage`. |
| 6 | Write `/etc/ssh/sshd_config.d/99-bootstrap.conf` (Port + no root + no password), `sshd -t`, restart. |

Port 22 stays open in local firewalld as a safety net until you
explicitly accept the close-22 prompt at the end.

## After it finishes

Add to `~/.ssh/config` on your laptop:

```
Host new-server
  HostName 1.2.3.4
  User ansible
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
```

Sanity-check + deploy:

```bash
ansible -i inventory/hosts.yml new-server -m ping
ansible-playbook -i inventory/hosts.yml playbooks/site.yml --limit new-server
```

## Topology

```
+----------+   bootstrap-host.sh   +------------------+
|  laptop  |  ───────────────────► | managed host #1  |
|          |                       +------------------+
|          |   bootstrap-host.sh   +------------------+
|          |  ───────────────────► | managed host #2  |
+----------+                       +------------------+
     │                                      │
     └─────── ansible playbooks ────────────┘
            (ssh -p <port> ansible@host)
```
