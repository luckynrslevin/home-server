# jellyfin

[Jellyfin](https://jellyfin.org) — free and open-source media server.
Stream movies, TV shows, music, and photos to any device. Runs as a
single rootless container with host networking (for DLNA discovery).

## Container image

`docker.io/jellyfin/jellyfin:latest`

## Service user

`jellyfin` (UID/GID 1012) — rootless.

## Variables

| Variable                        | Default        | Purpose |
|---------------------------------|----------------|---------|
| `jellyfin_enable_hw_transcoding`| `false`        | Enable VAAPI hardware transcoding via `/dev/dri`. |
| `jellyfin_time_zone`            | `Europe/Berlin`| Timezone for metadata and scheduled tasks. |

## Secrets

None. The admin account is created via the web UI wizard on first
access — no vault-encrypted variables needed.

## Firewall ports

- **8096/tcp** — Web UI and API.

## Endpoints

- Web UI: `http://<server-ip>:8096`
- With reverse proxy: `https://jellyfin.<caddy_domain>`

## Volumes

- `jellyfin-config` — SQLite database, server settings, metadata.
- `jellyfin-cache` — transcoding cache and image cache (regenerable,
  not backed up).
- `jellyfin-media` — your media library (movies, TV, music).

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
