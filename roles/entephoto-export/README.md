# entephoto-export

Periodic decrypted export of an Ente Photos library to a plain-files
folder on the NAS. Runs alongside the existing encrypted backup
(`roles/entephoto`'s `backup_manifest`), not as a replacement.

## Why this exists

Ente Photos is end-to-end encrypted: the museum API stores ciphertext
blobs in MinIO, and only a client holding the user's master key can
decrypt them. The encrypted backup pipeline (rsync of MinIO + pg_dump)
is restorable into another Ente instance but is **useless without the
user's password** and not readable by any other tool.

This role gives you a portable plain-files mirror — original filenames,
album-folder structure, JSON metadata sidecars in Google Takeout format
— that you can browse, back up, or migrate into any other photo
manager (Immich, PhotoPrism, just `find`/`rsync`) at any time, without
running Ente at all.

## How it works

1. Clones the upstream Ente repo (`github.com/ente-io/ente`) and builds
   the official CLI from `cli/Dockerfile` into a local podman image
   (`localhost/ente-cli:latest`). Upstream doesn't publish a pre-built
   CLI image.
2. Mounts a NAS NFS share (e.g. `ds9:/volume1/photos-export`) on the
   host as the export destination.
3. Builds a combined CA bundle (system trust + Caddy internal CA) so
   the CLI trusts `https://photos-api.eddie.lan` (same pattern as
   `roles/music-assistant`).
4. Deploys a one-shot quadlet container plus a systemd timer firing
   daily at 03:00. Each fire runs `ente export` against the local
   museum, which fetches & decrypts only what's new (incremental).

## Required inventory

In your host's host_vars (`inventory/host_vars/<host>/main.yml`):

```yaml
my_linux_users:
  entephoto-export:
    uid: 1015
    gid: 1015

deploy_services:
  - entephoto-export       # add to your existing list

entephoto_export_nas_mount:
  src: "ds9:/volume1/photos-export"
  path: /srv/photos-export
  opts: "rw,noatime,vers=4,_netdev,async"

# Only set this if your museum is reverse-proxied behind a private CA
# (e.g. Caddy with caddy_seed_internal_ca). Leave empty if museum is
# on a public LE-issued cert.
entephoto_export_caddy_ca_cert_path: "/etc/pki/caddy-internal/root.crt"
```

## Pre-deploy: NFS export on the NAS

The role mounts the NAS share but assumes the export already exists.
On a Synology DSM, in **Control Panel → File Services → NFS**:

1. Create folder `/volume1/photos-export/` (e.g. owner `dsadmin:users`,
   mode `0755`).
2. Add an NFS export rule for the eddie host's IP, allowing
   read/write. Map anonymous writes to the role's user so files land
   owned correctly:

   ```
   /volume1/photos-export 192.168.1.231(rw,sync,no_subtree_check,all_squash,anonuid=1015,anongid=1015)
   ```

3. Apply the export.

## Bootstrap (one-time after first deploy)

The CLI needs an authenticated account to know what to download. Do
this **once** interactively after the role's first apply:

```bash
ssh eddie

# Run an interactive ente account add against the same volumes the
# timer-fired container uses. State persists in ente-export-state.volume.
sudo -u entephoto-export -i bash -c '
  XDG_RUNTIME_DIR=/run/user/$(id -u) \
  podman run --rm -it \
    --network host \
    -v ente-export-state.volume:/cli-data:Z \
    -v /srv/photos-export:/data \
    -v /home/entephoto-export/ca-trust/full-bundle.pem:/etc/ssl/certs/ca-bundle-with-caddy.pem:ro \
    -e SSL_CERT_FILE=/etc/ssl/certs/ca-bundle-with-caddy.pem \
    -e ENTE_CLI_CONFIG_DIR=/cli-data \
    -e ENTE_CLI_SECRETS_PATH=/cli-data/secrets \
    localhost/ente-cli:latest \
    account add
'
```

Prompts: app type (`photos`), export directory (`/data`), email,
password, optional 2FA OTP.

The first export can be hours-to-days for a large library. Run it
manually once so it doesn't hit the timer's `TimeoutStartSec=4h` cap:

```bash
sudo -u entephoto-export -i systemctl --user start ente-export.service
journalctl --user -u ente-export.service -f       # follow progress
```

After that, the daily timer takes over and only transfers new files.

## Verify

```bash
# NFS share is mounted on the host
mount | grep photos-export

# Timer is enabled and shows next firing time
sudo -u entephoto-export -i systemctl --user list-timers ente-export.timer

# Plain decrypted photos visible on the NAS share
ls /srv/photos-export/         # or browse on ds9 directly via SMB

# Disaster-recovery sanity test: stop the entephoto pod and confirm
# the photos in /srv/photos-export are still openable independently.
```

## Trade-offs

- **Reduced zero-knowledge property**: by design, this role stores the
  user's password-derived secrets in `ente-export-state.volume`.
  Anyone with root on the host can read every photo. The volume is
  owned by uid `1015` (entephoto-export) and not world-readable, but
  the trade-off vs. true E2E is unavoidable for an automated server-side
  decrypted export.
- **First-run disk usage**: a multi-thousand-photo library is tens of
  GB. Make sure the NAS has headroom on `/volume1` before kicking off
  the first run.
- **Image rebuild cadence**: the CLI image is built from `main` once,
  on first deploy. Rerun the role to pull/rebuild a newer CLI version.
