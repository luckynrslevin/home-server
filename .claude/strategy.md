# Development Strategy

Internal working document for planning the direction of the home-server
repo and the companion `luckynrslevin.podman_quadlet` Ansible role. Not
linked from the public README — this is for collaboration between the
user and Claude across sessions.

See also:
- [docs/ProductStrategy.md](../docs/ProductStrategy.md) — popularity
  landscape of home server automation tools (2026)
- [memory/project_goals.md](memory/project_goals.md) — high-level project
  objective

---

## Positioning (from market analysis)

- **Primary value**: personal, reproducible Fedora home server — the user
  is the primary customer
- **Secondary value**: a reference implementation + reusable Galaxy role
  (`luckynrslevin.podman_quadlet`) for the advanced 5–10% of homelabbers
  who want Ansible + rootless Podman + Quadlets
- **Not a competitor** to Runtipi / Umbrel / CasaOS / Coolify — different
  audience, different trade-offs
- **Closest peers**: NixOS home server configs, khuedoan/homelab,
  geerlingguy Ansible roles, linux-system-roles/podman. All niche.

**Core principles to preserve**:
- Rootless containers per service (dedicated UID, user namespaces)
- Rebuild-over-repair (Kickstart + Ansible + git = deterministic rebuild)
- Fedora-native (Kickstart, firewalld, SELinux, podman-auto-update)
- Secrets via Ansible Vault
- Pods for multi-container apps (share network namespace, simplifies
  service-to-service comms)
- Ansible roles = pure declarations; the base Quadlet role does the work

**Anti-goals** (don't drift into these):
- GUI / web dashboard
- App catalog / store
- Multi-distro support (Ubuntu / Debian / Arch)
- Multi-host orchestration
- Beginner ease-of-use polish
- Kubernetes

---

## What's done

### Service roles deployed on eddie (homeserver)

- shairport-sync (rootful — rootless broke mDNS, documented why)
- pi-hole (rootless, port forwarding 53 → 1053)
- samba (rootless, port forwarding 445/139)
- syncthing (rootless, config restore via volume staging)
- jukebox — Lyrion Music Server + Squeezelite in a pod (rootless, Material
  Skin plugin install, config patching for server.prefs)
- ente photos — pod with postgres + minio + museum + web (rootless, config
  patching for museum.yaml with vault secrets, MinIO bucket init)

### `luckynrslevin.podman_quadlet` v1.0.0 (published on Galaxy)

Unique features vs. `linux-system-roles/podman`:

- `podman_quadlet_firewall_ports` — automatic firewalld port opening
  with active-zone detection
- `podman_quadlet_firewall_port_forwards` — port forwarding for
  privileged ports (rootless can't bind <1024)
- `podman_quadlet_volumes_files_to_stage` — deploy files into volumes
  before container first start, with rootless UID mapping via
  `podman unshare chown`
- `podman_quadlet_volumes_config_patches` — patch specific keys in
  existing config files (YAML/JSON/INI/XML/keyvalue) after container
  first start, preserving generated defaults

### Project infrastructure

- `roles/requirements.yml` pinned to `v1.0.0`
- Galaxy role installs into `./.ansible/roles/` (gitignored), not
  committed to the repo
- `ansible-lint` passes in production profile on all service roles
- README with Mermaid architecture diagram
- Kickstart file for automated Fedora install

---

## Backlog — roadmap

Prioritized by a mix of **personal value** (does the user need this for
eddie?) and **uniqueness** (is this a genuine gap competitors lack?).

### Tier 1 — Cross-cutting tooling (highest leverage)

1. **Backup strategy** [personal value: HIGH, uniqueness: HIGH]
   - Per-service volume export (podman volume export → tar → somewhere)
   - Per-service restore playbook (the inverse)
   - Scheduling hook (podman auto-update timer has a precedent — maybe a
     backup.timer pattern, or integrate with restic/kopia)
   - Vault-file backup (critical — if `inventory/host_vars/homeserver.yml`
     vault secrets are lost, rebuilds can't work)
   - Decision needed: backup **from** host (sudo tar) vs **into** a
     dedicated backup role with its own volume?
   - Decision needed: local-only, or push to remote (B2, S3, NAS)?

2. **Per-role removal / teardown** [personal value: HIGH, uniqueness: HIGH]
   - `playbooks/remove-<service>.yml` for each role (stop, remove
     containers+pods+volumes+networks+quadlets, reload systemd, remove
     firewall rules, optionally remove linux user)
   - Or a generic `remove_role.yml` that takes `role_name` as input
   - Decision needed: delete volumes by default? (risky) or require a
     `confirm_delete_volumes=true` flag?

3. **Full-system "rebuild from scratch" playbook** [personal value:
   MEDIUM, uniqueness: MEDIUM]
   - Master playbook that runs all deployed roles in correct order
   - Currently implicit; would benefit from being explicit
   - Could live at `playbooks/site.yml` (Ansible convention)

### Tier 2 — Galaxy role polish

4. **`luckynrslevin.podman_quadlet` README overhaul**
   - Position explicitly against `linux-system-roles/podman`
   - Document each unique feature with a minimal example
   - Add "quick start" section
   - Link to the home-server repo as a reference consumer
   - Critical for making the Galaxy role discoverable/usable by others

5. **Molecule tests** for the Galaxy role
   - Currently no automated tests beyond manual ans-test deploys
   - Would catch regressions before publishing new versions
   - Medium effort, high long-term value if others start using the role

6. **Version policy** for the Galaxy role
   - When to cut a new version? Semver discipline?
   - Currently: v1.0.0 tagged manually when features stabilized
   - Future: any change to the public API (variable names, feature
     behavior) bumps minor or major

### Tier 3 — More service roles (for personal use)

Listed in README "Planned" section, ranked by personal utility:

- Paperless NGX (document management)
- IoT stack (Mosquitto + InfluxDB + Grafana + Telegraf)
- Home Assistant
- Uptime Kuma (monitoring across services)
- Mealie (recipes)
- Kopia (backups — overlaps with Tier 1 #1, coordinate design)

Each follows the established pattern, so marginal effort per role is
small — mostly figuring out the right quadlet template and config.

### Tier 4 — Nice-to-have / uncertain value

- Reverse proxy role (Traefik or Caddy) — currently each service exposes
  its own port; a proxy would consolidate to 80/443 and enable HTTPS
  via Let's Encrypt. High personal value if eddie gets accessed remotely.
- A way to generate vault secrets automatically on first deploy (currently
  manual `openssl rand` + `ansible-vault encrypt_string`). Could be a
  helper playbook.
- Smoke tests after deployment (curl health endpoints, podman ps checks)
- A `make` wrapper or shell script for common operations
  (`make deploy SERVICE=entephoto`, `make backup`, etc.)

---

## Decisions / open questions

Items needing a call before implementation:

### Backup tooling design

- **Local vs remote**: export to `/home/<user>/backups/` (simple, but
  single point of failure) or push to a remote target (more resilient,
  more complexity)?
- **Scheduling**: systemd timer per service, single scheduled master
  playbook, or manual / on-demand only?
- **Retention**: how many historical backups to keep?
- **Vault file backup**: where does `inventory/host_vars/homeserver.yml`
  go? Can't be on eddie (chicken-and-egg for rebuild). Options:
  another machine, encrypted off-site storage, printed paper?

### Removal tooling design

- **Generic vs per-role**: single `remove_role.yml` that introspects, or
  explicit `remove-<service>.yml` per role?
- **User preservation**: always keep the linux user? (Current pattern is
  yes — see entephoto test where the user persisted but volumes were
  backed up and removed)
- **Data safety**: require explicit flag to delete volumes?

### Galaxy role promotion

- Is there appetite to write a blog post or Reddit post announcing the
  role and its unique features? Low effort, potentially disproportionate
  visibility boost. Or is this pure personal project territory?

---

## Session log (append as we work)

Track what was done in each session to keep continuity. Add to the top.

### 2026-04-05 — Market analysis + strategy doc
- Researched home server automation popularity landscape (2026)
- Created [docs/ProductStrategy.md](../docs/ProductStrategy.md)
- Created this strategy doc
- Conclusion: project fills a real but narrow niche; continue for
  personal value, polish the Galaxy role independently as the most
  leveraged asset
- Next task TBD by user

### 2026-04-05 — Ente Photos role
- Built `roles/entephoto/` — pod with postgres + minio + museum + web
- Validated on ans-test end-to-end (signup, upload after MinIO
  presigned URL fix, backup+restore workflow verified)
- Cleaned up install path for `luckynrslevin.podman_quadlet` (moved to
  `.ansible/roles/`, pinned v1.0.0 in `roles/requirements.yml`)
