# Accelerate your journey to privacy and owning your data <br>Build your own private ecosystem.

> [!WARNING]
> **Work in progress — not ready for production use yet.**
> The project is under active development and as of now it's not
> exactly working as described. The architecture, role
> contracts, inventory layout, and even the deploy_services list
> still change without warning between commits.

## Objective

There are plenty of homeserver projects already. Why another one?

My journey looked like this:

Being interested in owning my data and increasing data privacy, I start reading and watching tutorials on individual topics solving certain issues. Like e.g. using pihole to reduce ADs. Combine pihole with unbound to avoid my internet or more precisely DNS provider can track all my digital activities.

In parallel I install paperless, because I always wanted a solution to manage and find my digital documents, piling up in my mailbox or on multiple different file systems on my computer or elsewhere.

Photos on my iPhone pile up on the local storage until I bought a new one. To get the migrations solved fast - because I want to use my new phone ;-) - I upload all photos to iCloud which works great thanks to apple ecosystem. However, besides the fact I am not owning my data any more, over the years my iCloud bill gets bigger and bigger and at the same time the vendor lock in. Changing to an "own my data" solution now in addition requires data migration.

In parallel I started using paperless and it's working great in my home network, but I would like to use the paperless app on my iPhone from anywhere to upload new pdfs or search pdfs on the go. I watch a youtube tutorial recommending me to forwart port 80 on my router to paperless. But is it a good idea? Simply opening ports and particular port 80 in your router and forwarding unencrypted communication to some service is not at all a good solution! And yes my paperless server obviously is still running on unencrypted communication using http, since I used the default installation and spared the effort to investigate how to switch to encrypted https.

But obviously now it's time to start digging to find a solution. And yes again there is a solution, you just need a reverse proxy and then configure everything properly, great! At the same time you find out, there are plenty of open source reverse proxy solutions. Further digging to figure out, what's best for you. But hold on, if I use self-signed certificates I need to get the certificate authority installed on each of my devices, also to family members using the ecosystem - puh ... again further digging ... and what the hack again there is a soultion to use Let's Encrypt certificates with the reverse proxy for your server in your home network, great! Officially signed certificates, no need to install anything on every device any more.

At the time I solved everything to my needs some time has passed and some major bugs in Linux have been identified and obviously my default Linux installation was not configure to automatically install security updates, but yes you simply need to configure it ;-).

And puh, there is still the backup topic on my todo list with high priority, I need to find some time .... I hope I do not lose any data until then.

Oh wow paperless team is active and meanwhile released several new versions ... I hope it's just new features I do not need but no security fixes :-).


**If you did not stop reading by now you most likely got it. This is what I am working on to solve with this project for myself. Therefore I define the software stack to MY needs according to MY opinionated choice.**

**Reducing time and effort related to**
- **Building my own production grade ecosystem based on open source software solutions**
- **Enabling secure access to my ecosystem to use it from anywhere**
- **Having proper backup in place I can rely on**
- **Continuously deploy functional and security relevant updates for the whole system**

**However, you will still require IT expertise to use the project**

### Design principles

What "opinionated, end-to-end" means concretely:

- **Application focus**
  - A secure, private (ad- and tracker-filtered) home network for all family members
  - Host and own all personal data — documents, music, photos, videos
  - Seamless integration with the iOS ecosystem wherever practical (AirPlay, native photo sync, etc.)
- **Automation by default**
  - Fully automatic, declarative installation — one command, no clicking through wizards
  - Per-host configuration kept in a private overlay repository
- **Security-conscious design**
  - Unique credentials generated during initial install
  - Secrets stored encrypted at rest, never committed in plaintext
  - Rootless containers first — each rootless application runs as its own dedicated Linux user
  - Rootful containers only where rootless is not feasible, and always hardened
  - Caddy is the mandatory front door — every web UI reached via `https://<subdomain>.<caddy_domain>` with real Let's Encrypt certificates issued via DNS-01 against your DNS provider (deSEC by default); per-service HTTP ports are not exposed on the LAN, and no per-device CA install is ever needed
  - Use tailscale to create a virtual network accross your devices to be able to access services on your homeserver independent from your location and network access point
- **Operational consistency**
  - Fully automatic reinstall from scratch, including restore of configuration and data
  - All applications fully integrated with systemd (start, stop, reboot)
  - Simple but practical backup and restore of all your data
  - Automatic release updates of containers, plus automatic OS security updates on the host

---

## Alternatives & Comparison

Honest, side-by-side feature matrix. Contributions welcome — open
an issue or PR if your favourite solution is missing or a rating
looks off.

**Legend:** **+** delivered out of the box · **o** partial /
manual / requires extra setup · **−** absent or actively contrary

| Feature | **This project** | [**Coolify**](https://coolify.io) | [**Umbrel**](https://umbrel.com) | [**CasaOS**](https://casaos.io) | [**YunoHost**](https://yunohost.org) |
|---|:---:|:---:|:---:|:---:|:---:|
| Polished web UI for daily ops | o | + | + | + | + |
| Curated application catalog (one-click install) | o | + | + | + | + |
| Built-in SSO / LDAP across all installed apps | o <br>*(Nextcloud as OIDC provider for apps that support it)* | − | − | − | + |
| Ready-made VPS image at common hosters | − <br>*(cloud-init self-provision planned)* | + | o | o | o |
| One-command install of the *whole* stack | + | o | + | + | + |
| Mandatory HTTPS for every service via real Let's Encrypt certs | + | o | o | − | + |
| Tailscale / mesh-VPN integration first-class | + | o | + | o | − |
| **Rootless / per-app-user isolation by default** | + | − | − | − | o |
| Per-app systemd integration (`systemctl`, `journalctl`, dep ordering) | + | − | − | − | + |
| Automatic container/app release updates | + | − | − | − | o |
| Automatic OS security updates | + | − | o | o | + |
| Built-in scheduled backup workflow | + | − | + | − | + |
| Tested, fully automated restore from scratch | + | − | o | − | + |
| Zero control-plane RAM overhead on the home server | + | − | − | − | − |
| Easy to extend with services *outside* the catalog | + | + | − | + | o |
| Ready-made hardware appliance you can buy | − | − | + | o | − |

**Notes worth flagging:**

- **Rootless matters.** Coolify runs as root and so do all deployed containers — full rootless Docker is an [open feature request](https://github.com/coollabsio/coolify/issues/2387). The [Jan 2026 CVE batch](https://thehackernews.com/2026/01/coolify-discloses-11-critical-flaws.html) (3× CVSS 10.0, including unauthenticated root SSH key disclosure) demonstrates the cost of that default.
- **App-update model on Umbrel** is deliberately manual — apps don't auto-update so you can review each release. In practice [many apps lag well behind upstream](https://community.umbrel.com/t/umbrel-update-policy-many-apps-are-not-up-to-date/17208).
- **Lifecycle integration** — Coolify, Umbrel, and CasaOS all rely on Docker restart policies (`unless-stopped` etc.) for container lifecycle. No dependency ordering (e.g. wait for the NFS mount before starting Jellyfin), no per-app systemd unit, no `journalctl -u <app>`. Coolify's own control plane has had [host-reboot bugs](https://github.com/coollabsio/coolify/issues/5933).
- **Umbrel Bitcoin focus** — heavily oriented toward Bitcoin / Lightning use cases. Excellent if you want that; complexity tax if you don't.
- **CasaOS backup/restore** is an [open community feature request](https://github.com/IceWhaleTech/CasaOS/discussions/175), not a shipped capability. App updates are also limited — apps installed from the store are [bound to specific releases](https://github.com/IceWhaleTech/CasaOS/discussions/744).
- **YunoHost is fundamentally different** — apps are *not* containerized; they install directly into the host as system packages, each running as its own dedicated system user behind a shared NGINX + LDAP + SSO stack. That's why it gets credit for built-in SSO and per-app systemd integration but only `o` on isolation (no namespace boundaries), and why "extend outside the catalog" is harder (you'd be manually packaging an app into the YunoHost integration model).

---

## Technical Architecture

The target system is built around a small number of well-defined
components that together provide a predictable and maintainable
platform. It leverages **podman containers** (both rootless and
rootful) and **podman quadlets** for native systemd integration —
every application is wired into the host's boot and shutdown
sequence, scheduled container updates, and the backup flow.

![Technical architecture](docs/diagrams/technical.svg)

<!-- Source: docs/diagrams/technical.d2 — render with `d2 docs/diagrams/technical.d2 docs/diagrams/technical.svg` -->

Backup flavours (driven by each role's `backup_manifest`):
- **tar** — small config/state volumes (`podman volume export` → gzip'd tar), restored atomically.
- **pgdump** — logical SQL dumps for PostgreSQL services (container stays up while the dump is taken).
- **rsync** — large mutable trees where a full-volume tar would be wasteful (media, MinIO buckets). A filesystem with snapshot capabilities on the NAS, like e.g. ZFS, is obviously benefitial.

The same system from an **automation perspective** — who does what,
and in which order, to bring a fresh box up to a fully-deployed
homeserver. The laptop as ansible host is optional, you could also use the homeserver itself:

![Automation architecture](docs/diagrams/automation.svg)

<!-- Source: docs/diagrams/automation.d2 — render with `d2 docs/diagrams/automation.d2 docs/diagrams/automation.svg` -->



Use **Tailscale** to create a **virtual network across your devices and the homeserver** to be able to access the services running on homeserver, independent from the location and network access point your device is connected. NAS server can be omittet but still needs network access to the homeserver for backup und restore operations.

![Tailscale architecture](docs/diagrams/tailscale.svg)

<!-- Source: docs/diagrams/tailscale.d2 — render with `d2 docs/diagrams/tailscale.d2 docs/diagrams/tailscale.svg` -->


---

### 1. Base Operating System – AlmaLinux 9

AlmaLinux 9 is used as the foundational operating system due to:
- A long, predictable lifecycle (10 years per major release)
  with no surprise feature churn between minor versions
- Bug-for-bug compatibility with RHEL — every operational pattern,
  package, and SELinux policy translates directly
- Strong SELinux integration out of the box
- Mature container tooling — **podman ≥ 5** with native systemd
  **quadlet** unit support and rootless containers, shipped in stock
  `appstream` from AL 9.4 onward (no third-party COPR required)
- **nfs-utils** in stock `baseos` — every host gets the
  `mount.nfs` helper needed for the NAS-backed media (jellyfin) and
  backup/restore flows
- Free and community-governed, with no commercial subscription
  required

This choice ensures the system remains **secure, current, and aligned
with enterprise Linux best practices**, while still being suitable for
home use — and avoids the ~13-month Fedora release treadmill on a
machine that should "just work" for years.

---

### 2. Configuration Management – Ansible

All post-installation configuration is handled using **Ansible**, ensuring the system converges into a known desired state.

Ansible is responsible for:
- System configuration and hardening
- User and group management
- Container runtime setup
- Service configuration and lifecycle management

This approach treats the system as **infrastructure as code**, enabling version control, review, and repeatable execution.

---

### 3. Container-First Workload Model

All applications and services are deployed as containers using two complementary execution models.

#### Rootful Containers
Used for:
- Infrastructure-level services
- Networking-sensitive workloads
- Services requiring elevated privileges

#### Rootless Containers
Used for:
- User-scoped services
- Isolated application stacks
- Improved security through least-privilege execution

Each container deployment is:
- Fully automated via Ansible
- Declarative and reproducible
- Independent of manual user interaction

Persistent data is stored in explicitly defined volumes, allowing:
- Clean separation between OS and application data
- Straightforward backup and restore processes

---

## Non-Goals

The following items are explicitly **out of scope** for this project:

- Running a general-purpose desktop environment on the server
- Manual, ad-hoc configuration changes on the host system
- Hosting production-grade, high-availability workloads
- Complex multi-node orchestration platforms (e.g. Kubernetes)
- Cloud-specific tooling or managed services dependencies
- Long-term in-place OS upgrades without reprovisioning

The guiding principle is **rebuild over repair**: if the system drifts, it should be reinstalled and redeployed automatically rather than manually fixed.

---

## Getting Started

➡️ **[Setup Guide](docs/Setup-Guide/README.md)** — five short
pages, ~50–90 min total, takes you from "I just heard about this
project" to "I'm logged into my dashboard over HTTPS with a green
padlock". Each step has time estimates and a progress bar.

Prefer one long page over a wizard? See
**[Quickstart](docs/Quickstart.md)** — same path, denser
single-page format.

---

## Services

Platform foundations (always deployed) — `os-base` (system hardening,
podman 5, dnf-automatic, systemd-resolved, swap, etc.) and
`os-tailscale` (mesh-VPN onto the tailnet, optional subnet routing).
These aren't web-facing services; they set the stage so the
application roles below can run.

### Deployed

| Service | Purpose | Container images | Volumes (backup method) |
|---|---|---|---|
| **Dashboard** | Generated status page showing every deployed service, its container, related volumes and last backup time. | — (static HTML rendered on host) | — |
| **Caddy** | Mandatory front-door reverse proxy. Issues real Let's Encrypt certs for every web UI via DNS-01 against your DNS provider (deSEC default; Cloudflare / Hetzner also bundled). | `ghcr.io/luckynrslevin/caddy-acme:latest` (custom build with deSEC + Cloudflare + Hetzner DNS plugins) | <ul><li>`caddy-data` — LE certs (auto-renewed, not backed up)</li><li>`caddy-config` — not backed up</li><li>`caddy-etc` — not backed up</li></ul> |
| **Pi-hole + Unbound** | Network-wide DNS ad/tracker blocking with a local recursive resolver (no upstream DNS leakage). Admin UI at `https://pihole.<caddy_domain>`. | <ul><li>`ghcr.io/pi-hole/pihole:latest`</li><li>`docker.io/klutchell/unbound:latest`</li></ul> | <ul><li>`pihole-etc` — tar</li><li>`pihole-dnsmasq` — tar</li></ul> |
| **Shairport-sync** | AirPlay audio receiver for iOS/macOS devices. | `docker.io/mikebrady/shairport-sync` | — (stateless) |
| **Syncthing** | Peer-to-peer file synchronization between household devices. | `ghcr.io/syncthing/syncthing:2` | <ul><li>`syncthing-config` — tar</li><li>`syncthing-data` — rsync</li></ul> |
| **Music Assistant** | Self-hosted music server with library + streaming providers + queue. SqueezeLite player container drives a USB DAC for local playback (opt-out via `music_assistant_player_enabled: false` on hosts without audio hardware). | <ul><li>`ghcr.io/music-assistant/server:latest`</li><li>`docker.io/giof71/squeezelite`</li></ul> | <ul><li>`music-assistant-data` — tar</li></ul> |
| **Ente Photos** | Self-hosted photo & video library with iOS/Android apps (end-to-end encrypted). | <ul><li>`ghcr.io/ente-io/server:latest`</li><li>`ghcr.io/ente-io/web:latest`</li><li>`public.ecr.aws/docker/library/postgres:15`</li><li>`quay.io/minio/minio:latest`</li></ul> | <ul><li>`entephoto-museum-config` — tar</li><li>`entephoto-minio-data` — rsync</li><li>`ente_db` (Postgres) — pgdump</li></ul> |
| **Paperless-NGX** | Document management with OCR + full-text search. Optional SFTP sidecar for scanner auto-ingest (`paperless_sftp_ingest_enabled`). | <ul><li>`ghcr.io/paperless-ngx/paperless-ngx:latest`</li><li>`public.ecr.aws/docker/library/postgres:16`</li><li>`public.ecr.aws/docker/library/redis:7-alpine`</li><li>`docker.io/gotenberg/gotenberg:8`</li><li>`docker.io/atmoz/sftp:latest`</li></ul> | <ul><li>`paperless-data` — tar</li><li>`paperless-export` — tar</li><li>`paperless-redis-data` — tar</li><li>`paperless-media` — rsync</li><li>`paperless` (Postgres) — pgdump</li><li>`paperless-consume`, `paperless-sftp-*` — runtime, not backed up</li></ul> |
| **Jellyfin** | Media server for movies, TV and music with native iOS/tvOS clients. NAS-backed video library mounted read-only via NFS. | `ghcr.io/jellyfin/jellyfin:latest` | <ul><li>`jellyfin-config` — tar</li><li>`jellyfin-media` — rsync (opt-in restore)</li></ul> |
| **Ente Photos export** | Decrypted nightly export of the Ente library to NAS — plain JPG/HEIC + Google-Takeout-style `.json` sidecars per album. Independent of Ente itself, so the photos stay readable without your master password. Includes a self-cleanup report at `https://<host>/ente-photos-report.html`. | `ghcr.io/luckynrslevin/ente-cli:latest` (custom multi-arch build from upstream `ente-io/ente`) | <ul><li>`entephoto-export-state` — CLI auth + sync cursor (preserved on remove)</li><li>NAS export tree at `nas:/volume1/backup-photos-export/<hostname>/` — not backed up (it _is_ a backup)</li></ul> |
| **Nextcloud** | File storage, sharing, contacts, calendar. Also acts as an OIDC identity provider so other apps (where supported) can authenticate against the same Nextcloud user. | <ul><li>`docker.io/library/nextcloud:apache`</li><li>`public.ecr.aws/docker/library/postgres:16`</li><li>`public.ecr.aws/docker/library/redis:7-alpine`</li></ul> | <ul><li>`nextcloud-config` — tar</li><li>`nextcloud-data` — rsync</li><li>`nextcloud` (Postgres) — pgdump</li></ul> |
| **Backup** | Host-side service. Snapshots each role's declared volumes to the NAS on a schedule (default 21:00) using the per-role `backup_manifest`. | — (no container — runs as a systemd timer) | — |

The dashboard, generated on the host and served by Caddy, gives you a
single page with status / images / volumes / last-backup time for
every deployed service:

![Sample dashboard](docs/img/Dashboard.jpg)

### Planned applications / features

This list is generated from the [open `planned-app` issues](https://github.com/luckynrslevin/home-server/issues?q=is%3Aissue+is%3Aopen+label%3Aplanned-app) on GitHub and refreshed by a workflow whenever an issue is opened, closed, or (un)labeled. To propose something new, open an issue with the `planned-app` label.

<!-- planned-app-start -->
- [Cloud-init self-provisioning: one-paste deploy to any VPS provider](https://github.com/luckynrslevin/home-server/issues/106) (#106)
- [Add Home Assistant role](https://github.com/luckynrslevin/home-server/issues/204) (#204)
- [Add Mealie role](https://github.com/luckynrslevin/home-server/issues/205) (#205)
- [Add IoT stack role (Mosquitto + InfluxDB + Grafana + Telegraf)](https://github.com/luckynrslevin/home-server/issues/206) (#206)
- [Add Uptime Kuma role](https://github.com/luckynrslevin/home-server/issues/207) (#207)
<!-- planned-app-end -->
