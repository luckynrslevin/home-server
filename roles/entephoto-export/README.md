# entephoto-export

Daily decrypted export of the Ente Photos library to a NAS NFS share.

The companion to `roles/entephoto`. The encrypted pipeline (museum +
MinIO + Postgres) stays in place; this role adds plain-file copies of
every photo (album folders + Google-Takeout-style metadata sidecars)
on the NAS, independent of Ente.

Without this, the encrypted backup is unrestorable without the user's
master password — a portability concern that's been open since
[issue #73](https://github.com/luckynrslevin/home-server/issues/73).

## How it works

1. Builds the official Ente CLI from upstream (`ente-io/ente/cli/Dockerfile`)
   into a local podman image. Upstream publishes no pre-built CLI image.
2. Mounts `nas:/volume1/backup-photos-export/<hostname>/` at
   `/srv/photos-export` via NFS — same per-host backup-* layout used
   by `backup-jellyfin-media`.
3. Deploys a one-shot quadlet container fired by a systemd timer
   (daily 03:00 by default) that runs `ente export --dir /export`.
4. CLI state (auth tokens + per-account sync cursor) lives in the
   `entephoto-export-state` volume so subsequent runs are incremental.

## One-time bootstrap

The first export needs `ente account add`, which is interactive
(asks for email, password, OTP). Run it once as the `entephoto` user
after the role has deployed:

```bash
sudo -iu entephoto podman run --rm -it \
    -v entephoto-export-state:/data \
    -e ENTE_CLI_CONFIG_DIR=/data \
    localhost/ente-cli:latest \
    account add
```

After the auth state is persisted in the volume, the timer drives
all subsequent exports unattended.

## NAS-side prep

Create the share on the NAS and seed the per-host subdirectory:

```bash
# On the NAS (Synology DSM example)
# 1. Control Panel → Shared Folder → Create `backup-photos-export`
# 2. NFS Permissions: add the home-server's IP, sec=sys, rw, no_root_squash
# 3. mkdir <share>/<hostname>   # e.g. /volume1/backup-photos-export/homeserver
```

## Verifying

After the first scheduled run (or a manual `systemctl --user start
entephoto-export.service` as the `entephoto` user), browse the NAS
share — every album should appear as a folder of plain JPG/HEIC/MOV
files with `.json` metadata sidecars. Opening one in Preview / any
image viewer confirms it's decrypted; no Ente client required.

## Out of scope

- Restoring back into a fresh Ente instance from the export
  (`ente import` is a separate effort).
- Migrating off Ente (the export makes a future migration feasible
  but is not part of this role).
