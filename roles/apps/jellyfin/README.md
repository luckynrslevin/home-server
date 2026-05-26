# jellyfin

[Jellyfin](https://jellyfin.org) — free and open-source media server.
Stream movies, TV shows, music, and photos to any device. Runs as a
single rootless container with host networking (for DLNA discovery).

## Container image

`docker.io/jellyfin/jellyfin:latest`

## Service user

`jellyfin` (UID/GID 1012) — rootless.

## Variables

| Variable                          | Default                     | Purpose |
|-----------------------------------|-----------------------------|---------|
| `jellyfin_enable_hw_transcoding`  | `false`                     | Enable VAAPI hardware transcoding via `/dev/dri`. |
| `jellyfin_time_zone`              | `Europe/Berlin`             | Timezone for metadata and scheduled tasks. |
| `jellyfin_admin_user`             | `jellyadmin`                | Admin username created during first-run automation. |
| `jellyfin_admin_password`         | `""` *(vaulted)*            | Admin password. Empty disables postinstall (manual wizard). |
| `jellyfin_metadata_language`      | `en`                        | Default metadata language for new libraries. |
| `jellyfin_metadata_country`       | `US`                        | Default metadata country code. |
| `jellyfin_libraries`              | *(four standard libraries)* | List of `{name, type, path}` dicts auto-created on deploy. |

### Library list (default)

```yaml
jellyfin_libraries:
  - { name: "Music",       type: "music",      path: "/media/music" }
  - { name: "Movies",      type: "movies",     path: "/media/movies" }
  - { name: "Shows",       type: "tvshows",    path: "/media/tv" }
  - { name: "Home Videos", type: "homevideos", path: "/media/home-videos" }
```

Override the whole list in your host_vars to drop entries (e.g.
omit Home Videos) or add libraries (e.g. an audiobooks library
mapped at `/media/audiobooks`). Each path's subdirectory is
pre-created inside the `jellyfin-media` volume on deploy.

## First-run automation

When `jellyfin_admin_password` is set, the role's `postinstall.yml`
walks Jellyfin's REST API after the container is healthy:

1. Configures metadata locale (`UICulture` / `MetadataCountryCode`).
2. Creates the admin user (`/Startup/User`).
3. Sets remote-access defaults (Caddy fronts; UPnP off).
4. Marks the wizard complete (`/Startup/Complete`).
5. Authenticates as admin and registers any libraries from
   `jellyfin_libraries` that don't already exist.
6. Triggers a single library scan if any new libraries were added.

Idempotent: subsequent runs detect the wizard-complete state via a
403 from `/Startup/User` and skip; libraries already present are
left untouched.

## Secrets

| Variable                  | Purpose                                  |
|---------------------------|------------------------------------------|
| `jellyfin_admin_password` | Admin password for the auto-created user.|

`homeserver.sh` generates this as a vault-encrypted random string. Inspect
the stored value with:

```bash
ansible -i inventory/hosts.yml homeserver -m debug -a "var=jellyfin_admin_password"
```

## Firewall ports

None. The web UI is reverse-proxied by Caddy at
`https://jellyfin.<caddy_domain>` — direct LAN access on 8096
intentionally not exposed.

## Endpoints

- Web UI: `https://jellyfin.<caddy_domain>`

## Volumes

The `.volume` files declare no explicit `VolumeName=`, so podman
auto-prefixes them with `systemd-`. The on-disk names (and the names
the backup manifest references) are:

- `systemd-jellyfin-config` — SQLite database, server settings, metadata.
- `systemd-jellyfin-cache` — transcoding cache and image cache
  (regenerable, not backed up).
- `systemd-jellyfin-media` — your media library (movies, TV, music).

## Backup prerequisites

The Jellyfin media volume is mirrored to NFS share
`backup-jellyfin-media` on the project NAS via the `backup` role.
Before the first nightly run will succeed, **create the share on the
NAS** (e.g. Synology DSM → File Services → NFS → New Folder named
`backup-jellyfin-media`, allow the home-server's IP, squash to
`admin`). Same shape as the existing `backup-paperless-media` share.

## Deployment

```bash
ansible-playbook playbooks/jellyfin.yml --limit homeserver
```

After deployment, open `http://<server-ip>:8096` and complete the
setup wizard (language, admin account, media library paths).

Media goes into the `jellyfin-media` volume at `/media` inside the
container. Organize by type:

```
/media/
  movies/
  tv/
  music/
```

## Hardware transcoding

Set `jellyfin_enable_hw_transcoding: true` in host_vars if the host
has an Intel iGPU or dedicated GPU with VAAPI support. This:

1. Passes `/dev/dri` into the container.
2. Disables SELinux labeling (`SecurityLabelDisable=true`) so the
   rootless container can access the device.

Verify in Jellyfin: Dashboard → Playback → Transcoding → select
"Video Acceleration API (VAAPI)".

## Tips and troubleshooting

### Media not showing up

After adding files to the media volume, trigger a library scan:
Dashboard → Libraries → Scan All Libraries.

### DLNA not discoverable

Jellyfin uses host networking for DLNA/SSDP discovery. If devices
on your LAN can't find the DLNA server, verify the firewall allows
UDP on port 1900:

```bash
sudo firewall-cmd --add-port=1900/udp --permanent
sudo firewall-cmd --reload
```
