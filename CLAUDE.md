# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Ansible automation for a single-host home server (Fedora Server on `homeserver`, AlmaLinux 9 on `dnsvserver`). Every workload runs in podman containers via systemd quadlets. There is no orchestrator — all "deployment" is `ansible-playbook` against one host. The guiding principle is **rebuild over repair**: roles are written so a from-scratch reinstall + restore-from-backup is the supported recovery path, not in-place fixes.

## Public/private repo split

This repo is the **public** half. Real inventory and secrets live in a sibling private overlay at `~/github/home-server-private/`. The public repo references private files via gitignored symlinks:

- `inventory/hosts.yml` → `../home-server-private/inventory/hosts.yml`
- `inventory/host_vars/homeserver.yml` → `../home-server-private/inventory/host_vars/homeserver.yml`
- (Optional) syncthing identity files under `roles/syncthing/{files,templates}/...`

`vault.pw` is also a symlink into the private repo. When working on a fresh clone these symlinks may not exist yet — see README.md "Getting Started" for the bootstrap. **Never put real hostnames, IPs, or secrets into the public repo, examples, or GitHub issues/PRs.**

## Common commands

```bash
# Deploy everything declared in a host's deploy_services list
ansible-playbook playbooks/site.yml --limit homeserver

# Deploy one service (every role also has a single-service playbook)
ansible-playbook playbooks/pihole.yml --limit homeserver

# Skip the verification block at the end of a role
ansible-playbook playbooks/pihole.yml --limit homeserver --skip-tags verify

# Backup / restore
ansible-playbook playbooks/backup.yml  --limit homeserver
ansible-playbook playbooks/restore.yml --limit homeserver

# Install role dependencies (currently just luckynrslevin.podman_quadlet)
ansible-galaxy install -r roles/requirements.yml -p .ansible/roles/

# Lint
ansible-lint
```

`ansible.cfg` already points at `inventory/hosts.yml` and `vault.pw`, so no `-i` / `--vault-password-file` flags are needed.

SSH to hosts by alias only (`ssh homeserver`, `ssh ans-test`) — never with raw IPs + key flags.

## Architecture

### site.yml is the contract

`playbooks/site.yml` is the only playbook that should grow when a new service is added. Each host declares a `deploy_services` list in its `host_vars`, and every optional role in `site.yml` is gated by `"<name>" in (deploy_services | default([]))`. **Caddy is mandatory and asserted** in pre_tasks — every web UI in the project is reverse-proxied through it on `https://*.<caddy_domain>` with a private CA. Per-service HTTP ports are not exposed on the LAN. `caddy_domain` is also asserted.

Single-service playbooks (`playbooks/pihole.yml` etc.) exist for fast iteration but `site.yml` is the source of truth.

### Roles follow one shape

Each app role under `roles/<name>/` looks like:

- `defaults/main.yml` — all tunables, including a `backup_manifest` (see below)
- `tasks/main.yml` — create rootless user + group, enable linger, enable `podman-auto-update.timer`, deploy quadlet templates, hand off to `luckynrslevin.podman_quadlet`
- `tasks/postinstall.yml` — first-boot configuration (API tokens, DB seeding, etc.)
- `tasks/verify.yml` — end-to-end smoke test that hard-fails the play on regression; gated by `<role>_run_verification` and tagged `verify`
- `tasks/restore.yml` — role-specific restore steps invoked by `playbooks/restore.yml`
- `templates/quadlets/*.container.j2`, `*.pod.j2`, `*.network.j2` — systemd quadlet units
- `templates/volumes/...` and `files/volumes/...` — content bind-mounted into containers

### Rootless-by-default container model

Each app gets its own dedicated Linux user (UID/GID pinned via `my_linux_users.<name>` in inventory). Quadlets are deployed under that user's `~/.config/containers/systemd/` and managed by `systemctl --user`. Linger is enabled so units survive logout. Image updates ride `podman-auto-update.timer`; quadlets that should auto-update declare `AutoUpdate=registry`. Rootful is used only when rootless is infeasible (e.g. shairport-sync needing host audio/network).

### luckynrslevin.podman_quadlet handles the heavy lifting

The Galaxy role at `roles/requirements.yml` (currently v1.2.1) does the actual quadlet rendering, image pre-pull (before stopping the old container, so DNS etc. stay up during upgrade), `--policy=newer` selection, and the Docker Hub rate-limit fallback (warn + reuse cached image). **Don't hand-roll image pulls or `systemctl --user daemon-reload` in app roles** — call into the Galaxy role.

### Backup is generic; roles declare a manifest

`roles/backup/` is a single role that walks every other role's `backup_manifest` (a cross-role shared variable name, intentionally not prefixed — see `.ansible-lint`) and produces backups per declared volume. Three flavours:

- **tar** — small config/state volumes, restored atomically
- **pgdump** — logical SQL dumps for Postgres (container stays up)
- **rsync** — large mutable trees (media, MinIO buckets) where a full-volume tar would be wasteful

Restore is `playbooks/restore.yml` plus `playbooks/tasks/restore_generic.yml` plus each role's `tasks/restore.yml`. When adding a backed-up service, add its `backup_manifest` in `defaults/main.yml` rather than touching the backup role.

### Verification is part of deploy

Most app roles ship a `tasks/verify.yml` that asserts the service actually works post-deploy (e.g. Pi-hole verifies container health, gravity is populated, a canary is blocked, upstream is Unbound and not leaking externally). These run by default and hard-fail the play. Skip with `--skip-tags verify` or `<role>_run_verification: false`.

## Conventions worth knowing

- Role names with hyphens (`paperless-ngx`, `music-assistant`) match upstream project names; `role-name` is in `.ansible-lint` `skip_list` for that reason. The `deploy_services` tokens and playbook filenames use the same hyphenated names — don't rename.
- `var_naming_pattern` is loosened to `^[a-z_][a-z0-9_]*$` so `backup_manifest` (and other intentionally-shared cross-role vars) lint cleanly.
- Container images default to GHCR mirrors where available to dodge anonymous Docker Hub rate limits.
- LAN IPs that other roles depend on (the home server itself, the NAS) must be set as DHCP reservations on the router. See README "Network prerequisites".
- Dev workflow: GitHub issue → branch → implement → document → PR → user review → merge. Don't push to `main` directly.
