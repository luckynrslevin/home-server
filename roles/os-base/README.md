# os-base

Universal OS-baseline configuration for every host this project
manages. Runs unconditionally as the **first** role in
`playbooks/site.yml`.

The bootstrap script (`scripts/bootstrap-host.sh`) just opens an
Ansible path; this role is the next layer down: common tools,
security updates, podman 5, system DNS, locale, hostname.

Service roles (caddy, pihole, jellyfin, …) assume podman and the
common tools are present once they run — `os-base` provides that
guarantee.

## Supported distros

| Distro | Notes |
|---|---|
| **Fedora Server** (any current release) | Default repo already ships podman 5; nothing extra needed. |
| **AlmaLinux 9 / Rocky 9 / CentOS Stream 9 / RHEL 9** | Default repo only has podman 4.x. Role enables the upstream `rhcontainerbot/podman-next` COPR so `dnf install podman` resolves to 5.x — keeps quadlet / AutoUpdate behavior consistent with Fedora hosts. |

## Tasks (in order, all idempotent)

1. **podman 5 source** — enable `rhcontainerbot/podman-next` COPR on
   AlmaLinux/Rocky/CentOS 9. Skipped on Fedora.
2. **Common packages** — `bash-completion`, `vim-enhanced`, `tmux`,
   `bpytop`, `tree`, `jq`, `wget`, `curl`, `rsync`, `git`, `podman`.
   Configurable list.
3. **dnf-automatic** — installs and enables, configured for
   security-only updates, log to journal.
4. **Shell aliases** — `/etc/profile.d/zz-aliases.sh` (ll, la, ..,
   colors, systemd shortcuts).
5. **Timezone** — default `Europe/Berlin`.
6. **Console keymap** — default `de`.
7. **Hostname** — defaults to `inventory_hostname`.
8. **Rootful `podman-auto-update.timer`** — enabled.
9. **System DNS via systemd-resolved** — Mullvad base DNS
   (`base.dns.mullvad.net`, `194.242.2.4` / `2a07:e340::4`) with
   DoT. Pi-hole hosts get a higher-priority `20-pihole.conf`
   drop-in from the pihole role that supersedes this — net
   effect on those hosts is unchanged.

## Variables

See `defaults/main.yml`. Notable knobs:

| Variable | Default | Purpose |
|---|---|---|
| `os_base_packages` | listed above | Override or extend in host_vars. |
| `os_base_podman_extra_repo` | `rhcontainerbot/podman-next` | Set to `""` to skip COPR on RHEL-family (stay on podman 4.x). |
| `os_base_dnf_automatic_enabled` | `true` | Set to `false` per-host to opt out of auto security updates. |
| `os_base_dnf_automatic_apply` | `security` | Or `default` for everything. |
| `os_base_dns_servers` | Mullvad base IPv4+IPv6 | Set to `[]` to skip the resolved drop-in. |
| `os_base_dns_hostname` | `base.dns.mullvad.net` | DoT SNI hostname. |
| `os_base_dns_over_tls` | `true` | Set to `false` for plain DNS. |
| `os_base_aliases_enabled` | `true` | Set to `false` to skip the profile.d drop. |
| `os_base_timezone` | `Europe/Berlin` | Any tz database name. |
| `os_base_keymap` | `de` | Any keymap from `localectl list-keymaps`. |
| `os_base_hostname` | `inventory_hostname` | Override only when OS hostname must differ from Ansible inventory name. |

## Verifying the host

After a deploy:

```bash
systemctl is-enabled dnf-automatic-install.timer    # → enabled
podman --version                                    # → podman version 5.x.x
timedatectl | grep "Time zone"                      # → Europe/Berlin
localectl status | grep "VC Keymap"                 # → VC Keymap: de
hostnamectl --static                                # matches inventory
resolvectl status | grep "DNS Servers"              # Mullvad on non-Pi-hole hosts
ll                                                  # alias works in fresh shell
```

To confirm DNS is actually hitting Mullvad on a non-Pi-hole host:

```bash
resolvectl query --type=TXT id.dns.mullvad.net
```

## Deferred work (separate PRs)

- Refactor the 7 service roles that duplicate the rootless-user +
  linger + per-user `podman-auto-update.timer` block. Move that
  pattern into a reusable `tasks/create_rootless_user.yml` here and
  have service roles `include_tasks` it.
- Add Debian/Ubuntu support (alternate task file gated on
  `ansible_os_family`). Not needed yet — every host runs RHEL family.
