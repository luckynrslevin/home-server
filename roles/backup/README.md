# backup

Deploys an autonomous nightly backup of every other role's volumes to
a single per-host NFS share on a NAS. Runs as a `systemd` service
driven by a timer — no Ansible needed once installed.

After a successful run, the script triggers a Synology Btrfs snapshot
of the host's NAS share (via SSH) so off-site copies are taken at a
moment of known point-in-time consistency across every volume of every
service. On failure, an email alert is sent via the project SMTP
config.

## Container image

None. Pure host-level systemd unit + bash script.

## Service user

None. The backup script runs as root via systemd so it can read
rootless container volumes via `podman unshare`.

## Variables

| Variable                       | Default                | Purpose                                                            |
|--------------------------------|------------------------|--------------------------------------------------------------------|
| `backup_time`                  | `02:00:00`             | systemd `OnCalendar` time-of-day (HH:MM:SS).                       |
| `backup_nas_hostname`          | `nas`                  | Short hostname pinned in `/etc/hosts`.                             |
| `backup_nas_ip`                | `192.168.x.x`          | NAS IP — pinned in `/etc/hosts` so backups don't depend on DNS.    |
| `backup_nas_volume`            | `/volume1`             | Path prefix on the NAS (Synology uses `/volume1`).                 |
| `backup_alert_recipient`       | `{{ smtp_from }}`      | Email address that receives failure alerts.                        |
| `backup_nas_snapshot_user`     | *empty (off)*          | SSH username on the NAS for the post-backup snapshot trigger. Empty = no snapshot. |
| `backup_nas_snapshot_key_path` | `/root/.ssh/nas-snapshot` | Path to the private key authenticating as `backup_nas_snapshot_user`. |

Override all NAS variables per-host in inventory.

> **`backup_nas_ip` must be a reserved address** — pin it on your
> router (DHCP reservation by MAC). Lease drift will silently
> break the NFS mount and abort the backup at the first volume.

## Secrets

`smtp_password` is read from the project-level `smtp_*` vault entries
(shared with Ente, Paperless, Nextcloud) and rendered into the deployed
backup script. File mode is `0700` root-owned to keep it out of
unprivileged hands; same trust boundary as the rendered `museum.yaml`.

## Firewall ports

None. Backup traffic is outbound NFS + SSH on the LAN.

## NAS layout

Every host writes to **one dedicated NFS share** — `backup-<host>`. The
share is one Btrfs subvolume, so one snapshot captures everything that
host has backed up. Layout inside the share:

```
backup-<host>/
  <app>/
    tar/
      <volume>/<volume>-YYYYMMDD-HHMMSS.tar.gz
    rsync/
      <volume>/...
    pgdump/
      <container>/<container>-YYYYMMDD-HHMMSS.sql.gz
```

`<app>` is the role name (entephoto, paperless-ngx, …). One share per
host eliminates the prior cross-share consistency problem (DB dump on
`backup-tar` could end up out of sync with rsync mirror on
`backup-photos` since DSM snapshots were per-share and unaware of the
backup window).

See [docs/NAS-Setup.md](../../docs/NAS-Setup.md) for the one-time NAS
configuration (per-host share, NFS perms, snapshot policy, SSH key for
the snapshot trigger).

## Backup methods

The script implements three methods. Each service's volumes are
assigned the right one based on size, mutability, and whether the
data is a database.

### 1. `tar` — `podman volume export | gzip`

Used for **small, mostly-config volumes** where keeping a daily
history is cheap and useful.

- The container is stopped first (consistent on-disk state).
- `podman volume export <vol>` streams the volume contents as tar,
  piped through `gzip`, saved as
  `backup-<host>/<app>/tar/<vol>/<vol>-YYYYMMDD-HHMMSS.tar.gz`.
- **Retention:** last 7 daily snapshots are kept on the share.
  Older NAS-side snapshots (Snapshot Replication) extend history
  further.
- **Restore:** see [Restore](#restore).

### 2. `rsync` — file-level mirror

Used for **large data volumes** where a full daily tarball would be
wasteful and history isn't needed (the data is the data).

- The container is stopped first.
- `podman volume inspect` gives the mount path on the host.
- `rsync -rltD --delete --no-owner --no-group --numeric-ids` mirrors
  the volume's contents into `backup-<host>/<app>/rsync/<vol>/`.
- Ownership is **not** preserved (NFS `all_squash` rejects chowns;
  rootless container UIDs differ per host). On restore, ownership is
  re-applied with `podman unshare chown`.
- **No retention on the live mirror** — current state only. Pair with
  NAS-side Btrfs snapshots for point-in-time recovery.

### 3. `pgdump` — logical PostgreSQL dump

Used for **PostgreSQL databases**.

- Runs **with the container up** (`pg_dump` is a consistent logical
  snapshot, no need to stop the database).
- `podman exec <container> pg_dump …` is piped through gzip and saved
  as `backup-<host>/<app>/pgdump/<container>/<container>-YYYYMMDD-HHMMSS.sql.gz`.
- **Retention:** last 7 daily snapshots on the share.

## Cross-volume consistency (and why)

Each role's backup_manifest may declare multiple volumes plus a
database. The script stops the service, dumps the DB, copies all tar
volumes, rsyncs all rsync volumes, then starts the service. During
that window the on-disk state across all of the service's volumes is
mutually consistent.

The post-backup NAS snapshot fires immediately after this — capturing
everything written in this run as one atomic point-in-time across the
host's entire `backup-<host>` share. A restore against any snapshot
picks a known-good cross-volume state, eliminating the "DB rows
reference object keys not present in the rsync mirror" failure mode.

## NAS snapshot trigger

After the last role is processed (and only when `$ERRORS -eq 0`), the
script SSHs to the NAS:

```bash
ssh -i $NAS_SNAPSHOT_KEY $NAS_SNAPSHOT_USER@$NAS_HOST
```

The NAS user's `~/.ssh/authorized_keys` locks that connection to a
single command (per host, hardcoded share):

```
command="sudo /usr/syno/sbin/synosharesnapshot create backup-<host> --retry 3 desc=home-server-backup",no-port-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA…
```

If the trigger fails (NAS rebooting, SSH key broken, etc.), the script
logs an error but exits successfully — the data is already on the NAS;
only the consistency marker is missing. A DSM-scheduled fallback
snapshot at 05:00 (operator-configured) catches up.

Set `backup_nas_snapshot_user` to enable; leave empty to skip the
trigger on hosts that haven't been provisioned with the SSH key yet.

## Email alert on failure

When `$ERRORS -gt 0`, the script sends a single email via the
project-level SMTP config (reuses `smtp_host`, `smtp_port`,
`smtp_username`, `smtp_password`, `smtp_from`). Subject:
`[home-server backup] FAILED on <host>`. Body: tail of
`/var/log/home-server-backup.log`. Recipient defaults to `smtp_from`;
override with `backup_alert_recipient`.

If `smtp_host` isn't set on a host, the email step is omitted at
render time (no email, exit non-zero still).

## What gets backed up per service

Derived automatically from each role's `backup_manifest`. Current set
across the project:

| Service        | Volume / DB                       | Method  |
|----------------|-----------------------------------|---------|
| pihole         | `systemd-pihole-etc`              | tar     |
| pihole         | `systemd-pihole-dnsmasq`          | tar     |
| syncthing      | `systemd-syncthing-config`        | tar     |
| syncthing      | `systemd-syncthing-data`          | rsync   |
| entephoto      | `ente_db` (Postgres)              | pgdump  |
| entephoto      | `entephoto-museum-config`         | tar     |
| entephoto      | `entephoto-garage-data`           | rsync   |
| entephoto      | `entephoto-garage-meta`           | rsync   |
| paperless-ngx  | `paperless` (Postgres)            | pgdump  |
| paperless-ngx  | `paperless-redis-data`            | tar     |
| paperless-ngx  | `paperless-data`                  | tar     |
| paperless-ngx  | `paperless-export`                | tar     |
| paperless-ngx  | `paperless-media`                 | rsync   |
| jellyfin       | `systemd-jellyfin-config`         | tar     |
| jellyfin       | `systemd-jellyfin-media`          | rsync (restore_opt_in) |
| nextcloud      | `nextcloud` (Postgres)            | pgdump  |
| nextcloud      | `nextcloud-config`                | tar     |
| nextcloud      | `nextcloud-data`                  | rsync   |
| music-assistant| `music-assistant-data`            | tar     |
| caddy          | `caddy-data`                      | tar     |

## Deployment

```bash
ansible-playbook playbooks/backup.yml --limit homeserver
```

Operator one-time prerequisite per host: NAS-side share + SSH key
setup per [docs/NAS-Setup.md](../../docs/NAS-Setup.md).

## Restore

```bash
ansible-playbook playbooks/restore.yml --limit <host>
```

Mounts `nas:/<vol>/backup-<host>/` once, then for each service: stops
the unit, restores tar volumes (`podman volume import`), rsyncs rsync
volumes via `podman unshare`, restores pgdumps, runs the role's
optional `post_restore_tasks` hook, starts the unit.

To restore from a specific snapshot rather than the live mirror,
DSM-side: Snapshot Replication → select share → Browse → pick
timestamp → Restore to a sibling folder, then point `restore_root` at
that folder for the play.
