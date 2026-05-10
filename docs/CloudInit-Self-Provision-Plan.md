# Cloud-init self-provisioning plan

This document captures the design for one-paste cloud-init
self-provisioning of a homeserver on any common VPS provider. Today
the deployment flow is two-step: SSH into a fresh box → run
`bootstrap-host.sh` → drive Ansible from your laptop. For a cloud
VPS where the user just wants "buy a VPS, end up with a homeserver",
we want to collapse that to one paste of a cloud-init `user-data`
blob into the provider's "Create VM" form.

This is the path to flipping the `Ready-made VPS image at common
hosters` cell in the comparison table from `−` to `+`, without
publishing per-provider images.

## Context — why cloud-init

- Every mainstream VPS provider (Hetzner, OVH, DigitalOcean, Linode,
  Vultr, Scaleway, AWS Lightsail, …) ships AlmaLinux 9 cloud images
  with `cloud-init` enabled and accepts a `user-data` field at VM
  create time.
- `cloud-init` is the de-facto standard for first-boot host
  configuration in cloud images. We don't need to publish or maintain
  per-provider images — a single `user-data` template covers all of
  them.
- The user-data field is one paste. Provider account access can
  read it back, so it must be designed assuming visibility.

## End-state user experience

```
1. Pick AlmaLinux 9 cloud image at <any common provider>
2. Paste prepared user-data blob into the "Cloud-init" field
   (filled with: your SSH pubkey, your private-inventory git URL +
    deploy token, your vault password, chosen hostname + ssh port)
3. Click "Create VM"
4. ~15–30 minutes later: visit https://<hostname>.<caddy_domain>
   and the dashboard is up.
```

No SSH session opened, no laptop-side commands run.

## Architecture

### cloud-init flow

```
[boot]
  ↓
[cloud-init: bootcmd / users / packages / write_files]
  - install ansible, git, podman, dnf-automatic, …
  - create `ansible` user, install user's pubkey, NOPASSWD sudoers
  - write /tmp/vault.pw (or fetch from one-shot URL — see Secrets)
  - write /tmp/git-creds (deploy token for private repo)
  ↓
[cloud-init: runcmd phase 1 — pre-reboot]
  - inline equivalent of bootstrap-host.sh:
    * harden sshd onto chosen non-default port
    * firewalld + SELinux port label
    * (no need to create the user — cloud-init already did)
  - git clone <public repo> /opt/home-server
  - git clone https://<token>@<host>/<user>/home-server-private \
        /opt/home-server-private
  - symlink private inventory into public clone
  - ansible-galaxy install -r roles/requirements.yml
  - ansible-playbook playbooks/site.yml \
        --connection=local \
        --limit <hostname> \
        --skip-tags audio-blacklist-reboot
  ↓
[reboot — if any kernel/blacklist task changed something]
  ↓
[systemd one-shot unit: cloud-init-resume.service]
  - re-runs the playbook, this time WITHOUT the skip-tag, so the
    audio + reboot-required tasks complete cleanly
  - disables itself after success
  ↓
[ready: dashboard reachable, all services running]
```

### Why two ansible passes (pre/post-reboot)

Today, the `os-audio` role blacklists kernel modules and waits for
SSH to come back after a reboot. With `--connection=local` the
playbook is *running on the target* — a reboot kills the running
process. The clean way: split into two phases via a self-disabling
systemd one-shot that runs after boot and re-enters ansible.

Roles that need a reboot to fully settle:
- `os-audio` (kernel module blacklist) — likely irrelevant on a cloud
  VPS, but the pattern matters.
- `os-base` if it grows kernel-tunable changes that need persisting
  via initramfs.

For most cloud VPS deploys this two-phase dance can be avoided by
just not deploying the audio-touching roles. But the framework
should support it for completeness.

### Connection model: `--connection=local`

In the inventory, the cloud-deployed host needs `ansible_connection:
local` (or be invoked via `--connection=local` on the command line).
That short-circuits SSH and runs tasks against `127.0.0.1`. All
existing tasks should work — the few that explicitly reference
`ansible_host` for waiting on the host (e.g. the post-reboot wait in
`os-audio` post-PR-#92) need to also handle the local-connection
case (skip the wait when the playbook itself is on the target —
the wait is meaningless because the process won't survive the
reboot anyway).

## Secrets handling

Three things are sensitive: the **vault password**, the **private
repo deploy token**, and the **SSH host key seed** (less important,
but worth pinning so the host's identity is stable across reboots
when re-creating the VM from snapshot).

The user-data field is **stored plaintext on the provider side** and
is visible to anyone with provider-account access. So embedding the
vault password and deploy token directly is risky — they get logged
in provider audit trails forever.

### Recommended pattern

**One-shot fetch URL.** The user uploads vault.pw + deploy-token to
a one-shot signed URL (e.g. a private GitHub gist whose URL is
rotated, or a `https://0x0.st`-style ephemeral bin, or their own
S3-presigned URL with a short expiry). cloud-init `curl`s the URL
during runcmd phase 1; the URL becomes invalid afterward.

Pro: provider only ever sees the URL, not the secrets themselves.
Token-rotation discipline forces "secret-of-the-day", which limits
blast radius.

Con: more steps for the user. Slightly fragile if the upload host
flakes.

### Alternative — provider metadata services

AWS SSM, GCP Secret Manager, etc. provide first-class secret
delivery via the metadata service. Strongest security, but locks
into one provider per cloud-init template. Each provider gets its
own template variant. **Out of scope** for v1.

### Default-safe rule

Whatever pattern the user picks, the user-data instructions must
include: **"rotate vault.pw and the deploy token immediately after
the first successful deploy."** That neutralises the worst case
where a provider account is compromised six months later.

## Service composition presets

Cloud VPS won't have a NAS, AirPlay receiver, USB DAC, or any LAN
clients. The current `deploy_services` lists make assumptions that
break on a cloud host:

| Role | Cloud VPS issue |
|---|---|
| `pihole` | DNS is for LAN clients; no LAN here. Could still run for the host's own queries, but likely not the use case. |
| `shairportsync` | AirPlay over UDP multicast — useless on a cloud VPS. |
| `music-assistant` | Squeezelite player needs ALSA + a DAC. (Toggle from PR #102 already disables the player.) |
| `jellyfin` | NFS media mount to a NAS — needs a NAS that's reachable. |
| `paperless-ngx` SFTP ingest | Designed for a LAN scanner — irrelevant on cloud. |
| `backup` to NAS | NAS isn't reachable from cloud — needs a different backup target (S3/B2/restic-rest). |

We need named **deploy presets** for the common use cases:

- `cloud-vserver-dns` — caddy + pihole + dashboard (matches today's
  `dnsvserver` purpose).
- `cloud-vserver-files` — caddy + dashboard + paperless-ngx +
  syncthing + (optional) entephoto with object-storage backend.
- `cloud-vserver-full` — caddy + dashboard + entephoto + paperless +
  syncthing + tailscale subnet router.

Implementation: ship as `inventory/presets/cloud-vserver-*.yml`
files. The cloud-init template lets the user pick one (or compose
their own) via a single `deploy_services_preset` variable.

## Files to add

- `cloud-init/user-data.example.yaml` — reference cloud-init template
  with placeholders. User copy/edits.
- `cloud-init/README.md` — step-by-step user guide:
  - generate one-shot upload URL
  - paste user-data
  - what to verify after first boot
  - how to recover if cloud-init failed (SSH in, read
    `/var/log/cloud-init-output.log`)
- `inventory/presets/cloud-vserver-*.yml` — preset deploy_services
  lists.
- `roles/os-base/tasks/main.yml` — small change: when
  `ansible_connection == 'local'`, register a self-disabling
  `cloud-init-resume.service` for the post-reboot ansible re-run.
- `roles/os-audio/tasks/main.yml` — already handles `ansible_connection
  == 'local'` correctly post-PR #92; verify no extra change needed.
- `docs/Quickstart.md` — add a "Cloud-init self-provision" section
  pointing at `cloud-init/README.md`.
- `README.md` — once shipped, flip the comparison-table cell from
  `−` to `+`.

## Implementation phases

### Phase 1 — minimal viable self-deploy
- Hand-author a `user-data.example.yaml` for one provider (Hetzner,
  cheapest for testing).
- Single preset: `cloud-vserver-dns` (smallest scope).
- No two-phase reboot (skip the audio role entirely on cloud).
- Manual secret pasting (vault.pw inline in user-data) — document
  the rotate-after-first-deploy rule.
- **Goal**: Hetzner VM goes from "Create" to working pihole admin
  UI in one paste.

### Phase 2 — secret hygiene
- Document the one-shot URL pattern with a worked example.
- Add a `cloud-init/secret-fetch.sh` helper that the runcmd block
  calls.
- Test that a leaked user-data field doesn't give an attacker the
  vault password.

### Phase 3 — multi-preset + multi-provider
- Add `cloud-vserver-files` and `cloud-vserver-full` presets.
- Test on at least 3 providers (Hetzner, DigitalOcean, OVH).
- Test on AlmaLinux 9 cloud image *and* whatever AlmaLinux 10 cloud
  image looks like once stable.

### Phase 4 — the two-phase reboot dance
- Implement `cloud-init-resume.service` for roles that genuinely
  need a reboot mid-deploy.
- Verify `--connection=local` works end-to-end including the resume.

### Phase 5 — polish
- Pre-rendered cloud-init templates per provider in `cloud-init/`
  (Hetzner uses a slightly different YAML schema than DigitalOcean,
  for example).
- Update README comparison cell to `+`.
- Quickstart doc gets a "5-minute cloud deploy" section at the top.

## Out of scope

- Publishing pre-built VPS images to specific providers' marketplaces.
- Provider-specific Terraform / OpenTofu modules.
- A web UI to generate the user-data blob.
- Multi-host cloud deployments (HA, blue-green, etc.) — explicitly a
  non-goal of this project.

## Verification

End-to-end smoke test for each preset:

1. Spin up a fresh AlmaLinux 9 cloud VM at the provider with the
   example user-data filled in.
2. Wait the deploy-time budget (15–30 min).
3. From a laptop, `curl -k https://<hostname>` and confirm the
   dashboard / Caddy default page responds.
4. Per-preset functional smoke tests:
   - DNS preset: `dig @<vm-ip> example.com` resolves; a known-blocked
     domain returns 0.0.0.0.
   - Files preset: paperless web UI loads, admin login works with the
     vault-encrypted password.
5. Inspect `/var/log/cloud-init-output.log` on the VM for any task
   that was reported as failed but didn't propagate to a non-zero
   exit.

## Open questions to resolve during implementation

- **Hostname**: user picks in user-data, or we derive from cloud
  metadata? Answer probably: user picks (to match inventory).
- **caddy_domain** for cloud hosts: needs a real public DNS name
  pointing at the VM IP. Document the expected DNS-record-first
  workflow.
- **Backup target on cloud**: keep using NAS via Tailscale (homeserver
  acts as subnet router), or accept that cloud presets need
  S3/B2/restic-rest support added to the backup role?
- **Tailscale auth on cloud**: ephemeral auth keys vs. reusable —
  ephemeral is safer (single-use), but the os-tailscale role needs to
  not break re-runs.
