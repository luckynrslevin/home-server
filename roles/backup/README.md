# backup

Deploys an autonomous nightly backup of every other role's volumes to
an NFS share on a NAS. Runs as a `systemd` service driven by a timer
— no Ansible needed once installed.

## Container image

None. Pure host-level systemd unit + bash script.

## Service user

None. The backup script runs as root via systemd so it can read
rootless container volumes via `podman unshare`.

## Variables

| Variable              | Default       | Purpose                                             |
|-----------------------|---------------|-----------------------------------------------------|
| `backup_time`         | `02:00:00`    | systemd `OnCalendar` time-of-day (HH:MM:SS).        |
| `backup_nas_hostname` | `nas`         | Short hostname pinned in `/etc/hosts`.              |
| `backup_nas_ip`       | `192.168.x.x` | NAS IP — pinned in `/etc/hosts` so backups don't depend on DNS. |
| `backup_nas_volume`   | `/volume1`    | Path prefix on the NAS (Synology uses `/volume1`).  |

Override all NAS variables per-host in inventory.

## Secrets

None.

## Firewall ports

None. Backup traffic is outbound NFS on the LAN.

## What gets backed up

Per service, the script picks the cheapest correct method:

| Service     | Volume(s)                                                       | Method                  |
|-------------|-----------------------------------------------------------------|-------------------------|
| caddy       | `caddy-data`, `caddy-config`, `caddy-etc`                       | `podman volume export`  |
| pihole      | `systemd-pihole-etc`, `systemd-pihole-dnsmasq`                  | `podman volume export`  |
| samba       | `systemd-samba-data`                                            | `rsync`                 |
| syncthing   | `systemd-syncthing-config` / `systemd-syncthing-data`           | tar config, rsync data  |
| jukebox     | `jukebox-server-config`, `jukebox-server-playlist`, `…-music`   | tar config + rsync data |
| entephoto   | `entephoto-postgres-data`, `…-minio-data`, `…-museum-config`    | `pg_dump` + `rsync`     |

Retention: last **7 days** kept on the NAS; older snapshots rotated
out by the script.

## Deployment

```bash
ansible-playbook playbooks/backup-deploy.yml --limit homeserver
```

## Restore

1. Re-run the service's playbook to recreate the container and empty
   volume:
   ```bash
   ansible-playbook playbooks/syncthing.yml --limit homeserver
   ```
2. Import the backup tarball:
   ```bash
   sudo -u syncthg podman volume import systemd-syncthing-config \
       /mnt/nas-backup/syncthing-config-YYYY-MM-DD.tar
   ```
3. For PostgreSQL (entephoto), restore by piping `pg_dump` output
   into `psql` inside the running container.
