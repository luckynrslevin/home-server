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

## Backup methods

The script implements three methods. Each service's volumes are
assigned the right one based on size, mutability, and whether the
data is a database.

### 1. `tar` — `podman volume export | gzip`

Used for **small, mostly-config volumes** where keeping a daily
history is cheap and useful.

- The container is stopped first (so the on-disk state is consistent).
- `podman volume export <vol>` streams the volume contents as tar,
  piped through `gzip`, and saved as
  `<vol>-YYYYMMDD-HHMMSS.tar.gz` on the NAS.
- **Retention:** the last 7 daily snapshots are kept; older ones
  are deleted.
- **Restore:** re-create the empty volume (re-run the role's
  playbook), then
  ```bash
  gunzip -c <snapshot>.tar.gz | sudo -u <user> podman volume import <vol> -
  ```

Used for: pihole (`systemd-pihole-etc`, `systemd-pihole-dnsmasq`),
syncthing config (`systemd-syncthing-config`), jukebox config + playlist
(`jukebox-server-config`, `jukebox-server-playlist`),
entephoto museum config (`entephoto-museum-config`).

### 2. `rsync` — mirror to a dedicated NFS share

Used for **large data volumes** where a full daily tarball would be
wasteful and history isn't needed (the data is the data).

- The container is stopped first.
- `podman volume inspect` gives the mount path on the host.
- `rsync -rltD --delete --no-owner --no-group --numeric-ids`
  mirrors the volume's contents into a dedicated share on the NAS
  (`backup-photos`, `backup-syncthing`, `backup-xchange`,
  `backup-music`).
- Ownership is **not** preserved — NFS `all_squash` would reject
  chowns anyway, and rootless container UIDs differ between hosts.
  On restore, ownership is re-applied with `podman unshare chown`.
- **No retention / no history** — the share always reflects the
  latest mirror. Pair with NAS-side snapshots (Btrfs, ZFS, Synology
  Snapshot Replication) if you want point-in-time recovery.
- **Restore:**
  ```bash
  rsync -a --no-owner --no-group --numeric-ids \
      /mnt/backup/<share>/ <volume mount path>/
  sudo -u <user> podman unshare chown -R 0:0 <volume mount path>
  ```

Used for: syncthing data (`systemd-syncthing-data` → `syncthing`),
jukebox music (`jukebox-server-music` → `music`), entephoto MinIO
(`entephoto-minio-data` → `photos`).

### 3. `pgdump` — logical PostgreSQL dump

Used for **PostgreSQL databases**, where the right unit of backup
is a SQL dump, not the on-disk files.

- Runs **with the container up** (`pg_dump` is a consistent logical
  snapshot, no need to stop the database).
- `podman exec <container> pg_dump -U <user> <db>` is piped through
  `gzip` and saved as `<container>-YYYYMMDD-HHMMSS.sql.gz`.
- **Retention:** last 7 daily snapshots; older ones deleted.
- **Restore:**
  ```bash
  gunzip -c <snapshot>.sql.gz \
      | sudo -u <user> podman exec -i <container> psql -U <user> <db>
  ```

Used for: entephoto Postgres (`entephoto-postgres` / `ente_db`).

## What gets backed up per service

| Service   | Volume / DB                       | Method  |
|-----------|-----------------------------------|---------|
| pihole    | `systemd-pihole-etc`              | tar     |
| pihole    | `systemd-pihole-dnsmasq`          | tar     |
| syncthing | `systemd-syncthing-config`        | tar     |
| syncthing | `systemd-syncthing-data`          | rsync   |
| jukebox   | `jukebox-server-config`           | tar     |
| jukebox   | `jukebox-server-playlist`         | tar     |
| jukebox   | `jukebox-server-music`            | rsync   |
| entephoto | `ente_db` (Postgres)              | pgdump  |
| entephoto | `entephoto-museum-config`         | tar     |
| entephoto | `entephoto-minio-data`            | rsync   |

> Caddy volumes are not backed up. `caddy-etc` (Caddyfile) and
> `caddy-config` (runtime state) are regenerated from the role.
> Caddy's internal ACME root CA lives in `caddy-data` — it is
> persisted via `caddy_seed_internal_ca` staging from the
> `home-server-private` overlay, not via NAS backup. See
> [roles/caddy/README.md](../caddy/README.md#internal-ca-persistence).

## Deployment

```bash
ansible-playbook playbooks/backup.yml --limit homeserver
```

## Restore

The exact command depends on the backup method — see the per-method
"Restore" snippets above. The common shape is:

1. Re-run the service's playbook to recreate the container and an
   empty volume.
2. Restore the data using the method matching how it was backed up
   (`podman volume import`, `rsync`, or `psql`).
