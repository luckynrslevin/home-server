# samba

SMB/CIFS file server. Today exposes a single hardcoded guest-writable
share called `exchange`.

> **Heads-up:** the share configuration is hardcoded and
> world-writable. See
> [issue #2](https://github.com/luckynrslevin/home-server/issues/2)
> for the planned rework that will make shares declarative via
> `samba_shares` host_vars and add password auth.

## Container image

`ghcr.io/servercontainers/samba:latest`

## Service user

`samba` (UID/GID 1010) — rootless.

## Variables

| Variable              | Default               | Purpose                                    |
|-----------------------|-----------------------|--------------------------------------------|
| `samba_smb_port`      | `1445`                | Internal port (firewall forwards 445).     |
| `samba_netbios_port`  | `1139`                | Internal port (firewall forwards 139).     |
| `samba_share_path`    | `/home/samba/share`   | Currently unused; will matter post-#2.     |
| `samba_timezone`      | `UTC`                 | Override to your local TZ.                 |
| `samba_workgroup`     | `WORKGROUP`           | Windows workgroup name.                    |
| `samba_server_string` | `Samba Server`        | Description shown by browsers.             |
| `samba_netbios_name`  | `HOMESERVER`          | NetBIOS name.                              |

## Secrets

None. (No auth — anonymous guest writes are allowed on `exchange`.)

## Firewall ports

- **445/tcp** (port-forward → `samba_smb_port`)
- **139/tcp** (port-forward → `samba_netbios_port`)

## Endpoints

No web UI. Mount the share:

```bash
# Linux
sudo mount -t cifs //<server-ip>/exchange /mnt/exchange -o guest

# macOS Finder / Windows Explorer
\\<server-ip>\exchange    smb://<server-ip>/exchange
```

## Volumes

- `systemd-samba-data` — backing store for the `exchange` share.

## Deployment

```bash
ansible-playbook playbooks/samba.yml --limit homeserver
```
