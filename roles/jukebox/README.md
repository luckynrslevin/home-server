# jukebox

[Lyrion Music Server](https://lyrion.org) (formerly Logitech Media
Server) plus a `squeezelite` player in the same Podman pod, so the
host plays music from its own library through its sound card.

> **Bare-metal only.** The `squeezelite` player needs real audio
> hardware (typically a USB DAC) and permissive device ownership to
> open ALSA. It does **not** work inside a VM with virtio-snd — the
> rootless user namespace strips the host's `audio` group, and ALSA
> then only exposes the `null` sink inside the container, so the
> player connects to LMS as "no player". On VMs, leave `jukebox` out
> of `deploy_services` (use [shairportsync](../shairportsync/README.md)
> for audio testing instead).

## Container images

| Container       | Image                                  |
|-----------------|----------------------------------------|
| jukebox-server  | `docker.io/lmscommunity/lyrionmusicserver` |
| jukebox-player  | `docker.io/giof71/squeezelite`         |

## Service user

`jukebox` (UID/GID 1006) — rootless. Added to the `audio` group for
`/dev/snd` access.

## Variables

| Variable                       | Default     | Purpose                                                                                  |
|--------------------------------|-------------|------------------------------------------------------------------------------------------|
| `jukebox_squeezelite_preset`   | `default`   | Squeezelite preset matching your DAC (e.g. `topping-D10s`, `x20`, `aune-s6`, `default`). |

The squeezelite container ships a catalogue of presets for specific
DACs. `default` falls back to ALSA's default device, which is fine
for built-in audio but won't work in a VM without a real DAC. Set
the preset matching your hardware in your host_vars.

## Secrets

None. All LMS configuration (admin password, skin, language, library
paths, plugins) is done through the web UI on first visit — whatever
you choose there is persisted in the `jukebox-server-config` volume
and therefore captured by the backup role.

## Firewall ports

- **9100/tcp** — Web UI.

(Optional, commented out in [tasks/main.yml](tasks/main.yml):
`9090/tcp` for external Squeezebox-protocol clients,
`3483/tcp+udp` for player ↔ server — not needed when both run in the
same pod.)

## Endpoints

- Web UI: `http://<server-ip>:9100`

## Volumes

- `jukebox-server-config` — LMS prefs, installed plugins (e.g. Material
  Skin when you enable it via the UI), library database.
- `jukebox-server-music` — your music library.
- `jukebox-server-playlist` — playlists saved from LMS.

## Deployment

```bash
ansible-playbook playbooks/jukebox.yml --limit homeserver
```

The role stages `favorites.opml` into the config volume so LMS starts
with your curated radio favourites, pre-pulls both container images
to avoid first-deploy systemd timeouts, and then starts the pod.
Everything else (enabling Material Skin, setting the admin password,
language, library paths, etc.) is done interactively in the LMS web
UI on first access and persisted in the config volume.

## Tips and troubleshooting

### Squeezelite doesn't see `/dev/snd` on first install

Known issue (see TODO in [tasks/main.yml](tasks/main.yml#L27-L29)):
on a fresh install the `squeezelite` container starts before the
audio device is fully available to the rootless user. Reboot the host
once after the first deployment — subsequent boots work.

## Cross-role dependencies

Imports [os-audio](../os-audio/README.md) on systems that need a
default-card override (typical for VMs).
