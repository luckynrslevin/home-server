# shairportsync

[shairport-sync](https://github.com/mikebrady/shairport-sync) AirPlay
audio receiver. The host appears on iOS/macOS devices as an AirPlay
target and streams audio to the local sound card.

Runs **rootful** (not rootless) and uses host networking — required
for mDNS/Bonjour to work end-to-end.

## Container image

`docker.io/mikebrady/shairport-sync`

## Service user

None — rootful container running as root.

## Variables

| Variable                       | Default                            | Purpose                                                                |
|--------------------------------|------------------------------------|------------------------------------------------------------------------|
| `shairportsync_airplay_name`   | `{{ ansible_facts['hostname'] }}`  | Name shown on iPhones, Macs, etc.                                      |
| `shairportsync_audio_device`   | `/dev/snd`                         | ALSA device passed to the container. Override to a specific card path. |

## Secrets

None.

## Firewall ports

- **5353/udp** — mDNS / Bonjour discovery (without this, AirPlay
  devices are invisible)
- **7000/tcp** — AirPlay control
- **3689/tcp** — DAAP / service advertising
- **5000/tcp** — AirPlay audio timing
- **319-320/udp** — PTP timing
- **6000-6009/udp** — control protocol
- **32768-60999/tcp** + **32768-60999/udp** — RTP audio streams

## Endpoints

No web UI. Discoverable via Bonjour mDNS as
`<shairportsync_airplay_name>` on iOS/macOS.

## Volumes

None.

## Deployment

```bash
ansible-playbook playbooks/shairportsync.yml --limit homeserver
```

The role first checks `shairportsync_audio_device` exists. If it
doesn't (e.g. headless server with no sound card), the deploy is
skipped with a debug message — the container is not installed.

## Cross-role dependencies

Imports [os-audio](../os-audio/README.md) before deploying the
container. That role:
- installs `alsa-utils`,
- detects the playback ALSA card,
- writes `/etc/asound.conf` if playback isn't on `card 0` (common in
  VMs).

If `/etc/asound.conf` exists after `os-audio` runs, the shairport
quadlet bind-mounts it read-only into the container so the container
inherits the override.

## Tips and troubleshooting

### Debugging audio devices

If the AirPlay target is visible but won't connect or makes no sound,
inspect the audio setup on the host:

```bash
# Sound cards visible to the kernel
cat /proc/asound/cards

# PCM devices — look for `playback` entries
cat /proc/asound/pcm

# Test playback directly (1 s sine tone)
sudo dnf install -y alsa-utils
speaker-test -t sine -f 440 -l 1 -D default

# Confirm the container sees the same devices
sudo podman exec shairport-sync sh -c 'cat /proc/asound/cards'
sudo podman exec shairport-sync sh -c 'cat /proc/asound/pcm'
```

### Wrong default audio device (typical for VMs)

On VMs (especially virtio-snd), `card 0` is often capture-only
(microphone) and `card 1` has the playback PCM. shairport-sync starts
fine but every AirPlay connection drops with `output_device_error_2`.

[os-audio](../os-audio/README.md) detects this and writes
`/etc/asound.conf` automatically. To do it by hand:

```bash
sudo tee /etc/asound.conf > /dev/null << 'EOF'
defaults.pcm.card 1
defaults.ctl.card 1
EOF

# Mount it into the container
sudo sed -i '/^AddDevice=/a Volume=/etc/asound.conf:/etc/asound.conf:ro' \
    /etc/containers/systemd/shairport-sync/shairport-sync.container
sudo systemctl daemon-reload
sudo systemctl restart shairport-sync
```

### AirPlay device not visible on iPhone/Mac

- Server must be on the **same LAN subnet** as your Apple devices —
  no NAT, no host-only network. For VMs, use **bridged networking**.
- Confirm the firewall ports above are open:
  ```bash
  sudo firewall-cmd --list-ports
  ```
  At minimum: `5353/udp`, `7000/tcp`, `319-320/udp`, `3689/tcp`,
  `5000/tcp`.
- Restart the container to re-broadcast on Avahi/Bonjour:
  ```bash
  sudo systemctl restart shairport-sync
  ```
