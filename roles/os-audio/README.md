# os-audio

Host-level audio prerequisite for any role that talks to ALSA. Not
deployed standalone — imported by [shairportsync](../shairportsync/README.md)
and [jukebox](../jukebox/README.md).

## What it does

1. Installs `alsa-utils` (so `speaker-test`, `aplay`, etc. are
   available for debugging).
2. Detects the lowest-numbered ALSA card with a `playback` PCM by
   parsing `/proc/asound/pcm`.
3. If that card isn't `card 0`, writes `/etc/asound.conf` to set
   `defaults.pcm.card` and `defaults.ctl.card`. Common on VMs (e.g.
   virtio-snd) where `card 0` is capture-only and `card 1` has
   playback. Without this override, ALSA-aware containers fail with
   `output_device_error_2`.
4. Adds `blacklist snd_hda_intel` to `/etc/modprobe.d/blacklist.conf`
   to keep the on-board codec out of the way. **Reboots the host** if
   the line was newly added (skipped for `ansible_connection: local`
   — rebooting the controller would kill the playbook).

After this role runs, [shairportsync](../shairportsync/README.md)'s
quadlet template bind-mounts `/etc/asound.conf` into the container if
the file exists.

## Container image

None.

## Service user

None — runs as root.

## Variables

None.

## Secrets

None.

## Firewall ports

None.

## Deployment

Not invoked directly. To re-run, deploy a role that imports it:

```bash
ansible-playbook playbooks/shairportsync.yml --limit homeserver
```

## Cross-role dependencies

Required by [shairportsync](../shairportsync/README.md) and
[jukebox](../jukebox/README.md). Both `import_role` it as their first
real task.
