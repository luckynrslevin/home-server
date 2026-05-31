# dashboard

Generates a static HTML status page summarizing every deployed service:
container status, image and image age, available updates, per-container
mounted volumes, last backup timestamp, and a clickable link to each
service's web UI. Driven by a `systemd` timer that re-renders every 15
minutes.

The HTML is written to `/var/www/dashboard/index.html` and served by the
[caddy](../caddy/README.md) role.

## Auto-discovery contract

There is **no per-host config file** for the dashboard. Every 15 minutes
the generator (`/usr/local/bin/home-server-dashboard.py`) reads:

- `inventory/host_vars/<host>/00-services.yml` →
  `platform_services + apps` decides what to render.
- `inventory/host_vars/<host>/10-caddy.yml` → `caddy_domain` builds the
  public URLs.
- `roles/{platform,apps}/<svc>/meta/install.yml` of each enabled
  service:
  - `display_name` → table heading
  - `side_effects.my_linux_users` (sole entry) → rootless user (the
    generator `su`s into this user for podman queries)
  - `side_effects.caddy_reverse_proxy_services` → public URLs (one
    per non-hidden entry)
- Per container (live, via `podman inspect`): image, image age, update
  status, and the volumes actually mounted in *that* container (volume-
  type mounts only; bind mounts are filtered out).

Adding a service: `homeserver.sh add <svc>` updates `platform_services`/
`apps`. The dashboard picks it up on the next 15-min tick. No
dashboard-specific work needed in the role beyond what's already there.

## URL hints on `caddy_reverse_proxy_services` entries

Each route entry accepts three optional fields that Caddy ignores and
the dashboard consumes:

| Field    | Default                           | Effect |
|----------|-----------------------------------|--------|
| `label`  | subdomain, title-cased            | Link text on the dashboard. |
| `path`   | `/`                               | Appended to the URL — useful for apps whose root isn't the UI (e.g. Pi-hole → `/admin`). |
| `hidden` | `false`                           | `true` keeps the Caddy reverse-proxy route but hides the link from the dashboard. Used for internal subdomains (Ente's `accounts`/`cast`/`auth`/`photos-s3` backplanes). |

Example (`roles/platform/pihole/meta/install.yml`):

```yaml
side_effects:
  caddy_reverse_proxy_services:
    - { subdomain: pihole, port: 8443, proto: https, path: /admin, label: "Admin UI" }
```

## Container image

None. Pure host-level Python script + systemd unit + timer.

## Service user

None. The generator runs as root via systemd so it can `su` into each
service user and call `podman ps`.

## Secrets

None. The `!vault` tag on `caddy_acme_token` (in `10-caddy.yml`) is
parsed as a no-op — the dashboard never needs decrypted values.

## Firewall ports

None — served via [caddy](../caddy/README.md) on port 80.

## Endpoints

- Dashboard: `http://<server-ip>/` (served by caddy).

## Volumes

None of its own. Per-service volumes are listed by querying each
container's `Mounts[]` directly.

## Deployment

```bash
ansible-playbook playbooks/dashboard.yml --limit homeserver
```

The role triggers an immediate refresh (`systemctl start
home-server-dashboard.service`) and enables the timer
(`home-server-dashboard.timer`, every 15 min).

`homeserver.sh` also runs a manual refresh ~30 s after the playbook
finishes so the first page view shows real container state instead of
"all stopped" (rootless containers are still pulling/starting when the
playbook returns).

## Cross-role dependencies

Pairs with [caddy](../caddy/README.md), which serves the generated HTML.
The dashboard works best when most other roles are also deployed —
there's nothing to display otherwise.
