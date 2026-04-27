# music-assistant

[Music Assistant](https://www.music-assistant.io) — music library
controller and SlimProto server. Deployed as a rootless Podman pod
with two containers: the Music Assistant server and a `squeezelite`
player driving the host's USB DAC, so the home server can play music
without a client device.

> **Bare-metal only.** Same constraint as the
> [jukebox](../jukebox/README.md) role: the `squeezelite` player
> needs real audio hardware and permissive device ownership to open
> ALSA. It does **not** work inside a VM with virtio-snd.

## Container images

| Container               | Image                                            |
|-------------------------|--------------------------------------------------|
| music-assistant-server  | `ghcr.io/music-assistant/server:latest`          |
| music-assistant-player  | `docker.io/giof71/squeezelite`                   |

## Service user

`music-assistant` (UID/GID configured via `my_linux_users`) — rootless.
Added to the host `audio` group for `/dev/snd` access.

## Variables

| Variable                              | Default                                       | Purpose                                                                            |
|---------------------------------------|-----------------------------------------------|------------------------------------------------------------------------------------|
| `music_assistant_server_image`        | `ghcr.io/music-assistant/server:latest`       | MA server container image.                                                         |
| `music_assistant_player_image`        | `docker.io/giof71/squeezelite`                | Squeezelite player image.                                                          |
| `music_assistant_web_port`            | `8095`                                        | Host port for the MA web UI (Caddy proxies it).                                    |
| `music_assistant_squeezelite_preset`  | `default`                                     | Squeezelite preset matching your DAC. Override per-host.                           |
| `music_assistant_squeezelite_name`    | `MA-Player-{{ ansible_facts['hostname'] }}`   | Player name shown in the MA UI.                                                    |
| `music_assistant_squeezelite_mac`     | `""` *(empty)*                                | Stable MAC. **Must differ** from `jukebox_squeezelite_mac` if jukebox is also deployed. |

## Secrets

None. All MA configuration (admin email/password, library providers,
streaming-service credentials, player setup) is done through the web
UI on first visit and persisted in the `music-assistant-data` volume.

## Firewall ports

None. The web UI is reverse-proxied by Caddy at
`https://music.<caddy_domain>`. The internal SlimProto port (3483)
stays pod-private — the player connects to the server via pod-local
DNS, no host opening required.

## Endpoints

- Web UI: `https://music.<caddy_domain>`

## Volumes

- `music-assistant-data` — MA's SQLite database, provider config,
  player config, queue state, cache. Small (well under 1 GB).

## Deployment

```bash
ansible-playbook playbooks/music-assistant.yml --limit homeserver
```

## First-run setup (manual)

1. Open `https://music.<caddy_domain>` and complete the wizard.
2. Add a **library provider**:
   - **Jellyfin**: provider URL = your Jellyfin Caddy URL, API key
     generated in Jellyfin → Admin → Dashboard → API Keys.
   - or **Filesystem**: point at a host bind mount you've prepared.
3. Wait for the library scan.
4. The Squeezelite player in the same pod will be auto-discovered by
   MA's built-in SlimProto server. Rename it if desired.
5. Test: pick a track → "Play on `MA-Player-<hostname>`" — audio
   should come out of the USB DAC.

## Audio path

```
Client (web/iOS) ── HTTP ──► MA server ── SlimProto (pod-local) ──► Squeezelite ── ALSA ──► USB DAC
```

For lossless sources (FLAC) the server streams the original file to
the player and Squeezelite decodes locally — bit-perfect to the DAC,
no transcoding.

## Coexistence with jukebox (LMS)

Both roles can run side-by-side during evaluation. Each has its own
pod, rootless user, and Squeezelite container. The two players
register with different controllers (LMS vs MA) under their respective
`SQUEEZELITE_NAME` and `SQUEEZELITE_MAC_ADDRESS` values — make sure
those are distinct in your inventory.

To retire LMS afterwards: drop `jukebox` from `deploy_services`,
re-run the site playbook, and (optionally) reclaim disk by removing
the `jukebox-server-music` volume.

## Cross-role dependencies

Imports [os-audio](../os-audio/README.md) — same as jukebox, for the
optional `/etc/asound.conf` override on systems without playback on
ALSA card 0.

Pairs with [caddy](../caddy/README.md): the web UI is only reachable
via the reverse proxy. Pi-hole DNS records must include
`music.<caddy_domain>` pointing at the server IP.
