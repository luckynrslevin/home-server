# jukebox

[Lyrion Music Server](https://lyrion.org) (formerly Logitech Media
Server) plus a `squeezelite` player in the same Podman pod, so the
host plays music from its own library through its sound card.

## Container images

| Container       | Image                                  |
|-----------------|----------------------------------------|
| jukebox-server  | `docker.io/lmscommunity/lyrionmusicserver` |
| jukebox-player  | `docker.io/giof71/squeezelite`         |

## Service user

`jukebox` (UID/GID 1006) — rootless. Added to the `audio` group for
`/dev/snd` access.

## Variables

None. Configuration lives entirely in the staged `server.prefs`
patches and the deployed Material Skin plugin.

## Secrets

| Variable                  | Purpose                                                  |
|---------------------------|----------------------------------------------------------|
| `jukebox_security_secret` | Internal LMS API token, written to `prefs/server.prefs`. |

Generate and vault:

```bash
openssl rand -hex 16 | ansible-vault encrypt_string \
  --encrypt-vault-id default --stdin-name 'jukebox_security_secret'
```

Inspect a stored secret:

```bash
ansible -i inventory/hosts.yml homeserver -m debug -a "var=jukebox_security_secret"
```

## Firewall ports

- **9100/tcp** — Web UI (Material Skin).

(Optional, commented out in [tasks/main.yml](tasks/main.yml#L88-L91):
`9090/tcp` for external Squeezebox-protocol clients,
`3483/tcp+udp` for player ↔ server — not needed when both run in the
same pod.)

## Endpoints

- Web UI: `http://<server-ip>:9100`

## Volumes

- `jukebox-server-config` — LMS prefs + Material Skin plugin.
- `jukebox-server-music` — your music library.
- `jukebox-server-playlist` — playlists.

## Deployment

```bash
ansible-playbook playbooks/jukebox.yml --limit homeserver
```

## Post-install behaviour

[postinstall.yml](tasks/postinstall.yml) downloads the latest
[Material Skin](https://github.com/CDrummond/lms-material) release
from GitHub, unzips it into the config volume, and restarts the pod
so LMS picks it up. Reruns are no-ops once the plugin is present —
re-deploy the role to refresh it.

## Tips and troubleshooting

### Squeezelite doesn't see `/dev/snd` on first install

Known issue (see TODO in [tasks/main.yml](tasks/main.yml#L27-L29)):
on a fresh install the `squeezelite` container starts before the
audio device is fully available to the rootless user. Reboot the host
once after the first deployment — subsequent boots work.

## Cross-role dependencies

Imports [os-audio](../os-audio/README.md) on systems that need a
default-card override (typical for VMs).
