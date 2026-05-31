# NAS setup (Synology, DSM 7.x)

One-time operator setup so the project's backup script can write to
the NAS, and trigger a consistency snapshot after each successful
nightly run. Repeat for every home-server host.

Prereq: NAS volume must be **Btrfs** (Storage Manager → Storage shows
the underlying filesystem). Without Btrfs there are no snapshots.

## 1. Create a per-host shared folder

DSM → Control Panel → Shared Folder → **Create**:

| Field | Value |
|---|---|
| Name | `backup-<host>`  (e.g. `backup-homeserver`, `backup-homeserver2`) |
| Volume | the Btrfs volume |
| Description | "Home-server backup target — <host>" |
| Hide this shared folder in 'My Network Places' | yes (preference) |
| Enable Recycle Bin | **no** — useless for NFS deletes, just wastes space |
| Encrypt this shared folder | no (operator preference; backups already include vault secrets) |

After create → **Edit** → **NFS Permissions** → Create:
| Field | Value |
|---|---|
| Hostname or IP | the host's IP (e.g. `192.168.1.231`) |
| Privilege | Read/Write |
| Squash | `Map all users to admin` *(no_root_squash equivalent — needed because the backup script runs as root)* |
| Security | `sys` |
| Enable async | yes |
| Allow connections from non-privileged ports | no |

Repeat the NFS rule for each home-server host that should write to
this share (typically only one — the host the share is named after).

## 2. Install Snapshot Replication

Package Center → install **Snapshot Replication**. No configuration
yet — we set policy in step 3.

## 3. Per-share snapshot policy

Snapshot Replication → **Snapshots** tab → select `backup-<host>` →
**Settings**:

- **Schedule** tab — disable the hourly default. Add one custom rule:
  - Daily at **05:00** (well after the 02:00 backup completes —
    generous margin for slow nights). This is the fallback in case
    the script-triggered snapshot fails.
- **Retention** tab — **Advanced**:
  - Latest snapshots: **24**
  - Daily: **7**
  - Weekly: **4**

Save. Retention applies to all snapshots on the share — both DSM-
scheduled and script-triggered.

## 4. NAS-side user for the snapshot trigger

Control Panel → User & Group → **Create**:

| Field | Value |
|---|---|
| Username | `homeserver-backup` |
| Password | (random, doesn't matter — we use SSH key auth) |
| Description | "Home-server backup script — snapshot trigger only" |
| Disallow the user to change account password | yes |
| User groups | `users` (default) |

Application permissions → restrict everything (no DSM web, no File
Station, etc.). Only SSH is needed.

## 5. Enable SSH on the NAS

Control Panel → Terminal & SNMP → **Enable SSH service**. Take note
of the configured port — many Synology setups use **1022** (default
when DSM auto-configures around an existing service on 22). If yours
isn't 22, set `backup_nas_snapshot_port` in inventory accordingly.

## 6. Sudoers entry for the snapshot CLI

`synosharesnapshot` requires root. SSH in to the NAS as your admin
user one time and add a sudoers drop-in for the new user — one line
per share to keep the wildcard tight:

```
echo 'homeserver-backup ALL=(root) NOPASSWD: /usr/syno/sbin/synosharesnapshot create backup-homeserver*' \
    | sudo tee /etc/sudoers.d/snapshot-trigger > /dev/null
echo 'homeserver-backup ALL=(root) NOPASSWD: /usr/syno/sbin/synosharesnapshot create backup-homeserver2*' \
    | sudo tee -a /etc/sudoers.d/snapshot-trigger > /dev/null
sudo chmod 0440 /etc/sudoers.d/snapshot-trigger
```

(Add one line per home-server host. The trailing `*` lets the
hardcoded `--retry 3 desc=…` flags through without weakening the
share-name lock.)

## 7. SSH key pair per host

On each home-server host (as root):

```bash
ssh-keygen -t ed25519 -N '' -C "$(hostname)-backup-snapshot" -f /root/.ssh/nas-snapshot
chmod 0400 /root/.ssh/nas-snapshot
cat /root/.ssh/nas-snapshot.pub
```

Copy the printed public key. On the NAS, append it to
`homeserver-backup`'s `authorized_keys` with the locked command
matching that host's share. SSH in to the NAS, then:

```bash
mkdir -p /var/services/homes/homeserver-backup/.ssh
chmod 0700 /var/services/homes/homeserver-backup/.ssh
chown -R homeserver-backup:users /var/services/homes/homeserver-backup/.ssh

# Edit and append one line per host (replace the AAAA… key blob):
sudo tee -a /var/services/homes/homeserver-backup/.ssh/authorized_keys <<'EOF'
command="sudo /usr/syno/sbin/synosharesnapshot create backup-homeserver --retry 3 desc=home-server-backup",no-port-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA… homeserver
command="sudo /usr/syno/sbin/synosharesnapshot create backup-homeserver2 --retry 3 desc=home-server-backup",no-port-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA… homeserver2
EOF

sudo chown homeserver-backup:users /var/services/homes/homeserver-backup/.ssh/authorized_keys
sudo chmod 0600 /var/services/homes/homeserver-backup/.ssh/authorized_keys
```

(DSM may require enabling "User Home" service first — Control Panel →
User & Group → Advanced → User Home.)

## 8. Smoke test from the host

```bash
ssh -p <nas-ssh-port> -i /root/.ssh/nas-snapshot homeserver-backup@nas
```

(`<nas-ssh-port>` defaults to 22; many Synology setups use 1022 — match what step 5 showed.)

Should print a `Snapshot created` line and exit 0. Snapshot Replication
in DSM should immediately show one new snapshot in the share's history.

If it fails, check:
- `sudo tail /var/log/auth.log` on the NAS for the SSH attempt
- `synosharesnapshot list backup-<host>` to confirm whether it created
  anything

## 9. Inventory wiring

In `inventory/host_vars/<host>/20-extras.yml` (operator-managed,
never touched by `homeserver.sh install`):

```yaml
backup_nas_snapshot_user: homeserver-backup
# Override if NAS sshd isn't on the default port 22:
backup_nas_snapshot_port: 1022
# backup_nas_snapshot_key_path: defaults to /root/.ssh/nas-snapshot
```

Without `backup_nas_snapshot_user`, the snapshot-trigger step is
skipped (the deploy is otherwise identical).

## Future hosts

For each new home-server host: repeat steps 1 (create share + NFS
perms), 6 (sudoers — append one line), 7 (key + authorized_keys —
append one line), 9 (inventory).
