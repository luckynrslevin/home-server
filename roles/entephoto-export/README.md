# entephoto-export

Daily decrypted export of the Ente Photos library to a NAS NFS share.

The companion to `roles/entephoto`. The encrypted pipeline (museum +
MinIO + Postgres) stays in place; this role adds plain-file copies of
every photo (album folders + Google-Takeout-style metadata sidecars)
on the NAS, independent of Ente.

Without this, the encrypted backup is unrestorable without the user's
account password — a portability concern that's been open since
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

## Bootstrap (automated)

`homeserver.sh add entephoto-export` prompts once for your Ente account
email + account password, vault-encrypts them into inventory, then
the role drives `ente account add` non-interactively on first run.
Subsequent re-runs detect that auth state is already seeded and skip
the bootstrap. No human intervention on the target after the initial
prompts.

### Security trade-off

The account password decrypts the photo blobs. Storing it in vault
means a `vault.pw` compromise also exposes the photos — the same
trust boundary as every other vault secret in this project. For the
standard threat model (vault.pw on a USB / in a password manager
off-host), this is acceptable; if your threat model is stricter,
leave the credentials empty in inventory and bootstrap manually:

```bash
sudo -iu entephoto podman run --rm -it \
    -v entephoto-export-state:/data \
    -e ENTE_CLI_CONFIG_DIR=/data \
    localhost/ente-cli:latest \
    account add
```

### Recovering the stored password

```bash
homeserver.sh secret entephoto_export_account_password
```

### 2FA

Currently unsupported in the automated path. If your account has
2FA enabled, expect the first run to fail; either disable 2FA on
the account, or do the manual bootstrap above (the CLI's interactive
prompt handles TOTP).

## NAS-side prep

Create the share on the NAS and seed the per-host subdirectory:

```bash
# On the NAS (Synology DSM example)
# 1. Control Panel → Shared Folder → Create `backup-photos-export`
# 2. NFS Permissions: add the home-server's IP, sec=sys, rw, no_root_squash
# 3. mkdir <share>/<hostname>   # e.g. /volume1/backup-photos-export/homeserver
```

## Verifying

After the first scheduled run, browse the NAS share — every album
should appear as a folder of plain JPG/HEIC/MOV files with `.json`
metadata sidecars. Opening one in Preview / any image viewer confirms
it's decrypted; no Ente client required.

## Operational helpers

Run via `homeserver.sh entephoto-export <action>` (the dispatcher
lists all helpers if you omit the action):

- `export-now [HOST]` — fire the export immediately instead of
  waiting for the 03:00 timer. Useful after first deploy or after
  a config change. Returns when systemctl has accepted the start
  request; the export itself runs in the background.

## Out of scope

- Restoring back into a fresh Ente instance from the export
  (`ente import` is a separate effort).
- Migrating off Ente (the export makes a future migration feasible
  but is not part of this role).
