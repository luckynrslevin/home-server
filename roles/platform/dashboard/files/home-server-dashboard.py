#!/usr/bin/env python3
"""
Home Server Dashboard Generator

Generates a static HTML dashboard showing one table per deployed service:
- Service name, aggregate status, public links, last backup
- Per-container: image, image age, podman-auto-update status, mounted volumes

Auto-discovery contract (no per-host config file):
- Enabled services come from
  inventory/host_vars/<host>/00-services.yml -> platform_services + apps.
- Display metadata comes from each role's roles/<layer>/<svc>/meta/install.yml:
    display_name                                        -> dashboard heading
    side_effects.my_linux_users (first entry)           -> rootless user / uid
    side_effects.caddy_reverse_proxy_services           -> public URLs
- Per-URL hints (optional on each caddy_reverse_proxy_services entry):
    path:  appended to the URL (e.g. /admin); default "".
    label: link text;             default = subdomain title-cased.
- Volume attribution comes from `podman inspect <container>` Mounts[],
  filtered to volume-type mounts. Bind mounts (timezone files etc.) hidden.

Runs as root (needs to su to each service user for podman queries).
Output: /var/www/dashboard/index.html

Back-compat: if /etc/home-server-dashboard.yaml exists and the inventory
layout isn't reachable, fall back to the legacy config-driven path.
"""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
from datetime import datetime
from glob import glob

try:
    import yaml
except ImportError:
    yaml = None


LEGACY_CONFIG_PATH = "/etc/home-server-dashboard.yaml"
OUTPUT_DIR = "/var/www/dashboard"
BACKUP_LOG = "/var/log/home-server-backup.log"
BACKUP_DIR = "/var/log"
# Persistent state: last-known update status per container. Used to keep
# the previous status visible when a registry check fails (e.g. Docker Hub
# rate limit) instead of falling back to "Unknown".
STATE_PATH = "/var/lib/home-server-dashboard/state.json"

# Default install layout: homeserver.sh deploys to /home/ansible/home-server,
# inventory is symlinked into the overlay. Both paths are overridable via
# CLI args / env vars for non-default installs.
DEFAULT_INVENTORY_DIR = "/home/ansible/home-server/inventory"
DEFAULT_ROLES_DIR = "/home/ansible/home-server/roles"

# Services that have no UI / no dashboard tile. caddy fronts everything and
# isn't itself a "service" the operator cares to watch from the dashboard;
# os-* are pure host-config roles; backup runs from a timer.
DASHBOARD_HIDDEN_SERVICES = {
    "caddy", "dashboard", "os-base", "os-audio", "os-tailscale", "backup",
}


# ---------------------------------------------------------------------------
# Inventory + meta loading
# ---------------------------------------------------------------------------

def _vault_constructor(loader, node):  # noqa: ARG001
    """Treat !vault tags as opaque None — the dashboard never needs
    decrypted secrets, so we just skip them without erroring out."""
    return None


def _safe_yaml_load(path):
    """yaml.safe_load with a !vault constructor that returns None.
    Returns the parsed doc, or None if the file is missing / empty."""
    if not os.path.exists(path):
        return None
    if yaml is None:
        raise SystemExit(
            "PyYAML required: `dnf install python3-pyyaml` (the dashboard "
            "role's tasks/main.yml installs this on deploy)."
        )
    Loader = yaml.SafeLoader  # noqa: N806
    Loader.add_constructor("!vault", _vault_constructor)
    with open(path) as f:
        return yaml.load(f, Loader=Loader)


def load_host_inventory(inventory_dir, host):
    """Return {platform_services, apps, caddy_domain, nas_host_display}
    by reading the split host_vars layout directly off disk. Each value
    defaults to a sensible empty if its file is missing."""
    base = os.path.join(inventory_dir, "host_vars", host)
    services_doc = _safe_yaml_load(os.path.join(base, "00-services.yml")) or {}
    caddy_doc = _safe_yaml_load(os.path.join(base, "10-caddy.yml")) or {}
    # 20-extras.yml is operator-managed; it can carry nas_host_display
    # (cosmetic, shown next to backup_share paths) and future
    # dashboard_overrides hooks.
    extras_doc = _safe_yaml_load(os.path.join(base, "20-extras.yml")) or {}
    return {
        "platform_services": services_doc.get("platform_services") or [],
        "apps": services_doc.get("apps") or [],
        "caddy_domain": caddy_doc.get("caddy_domain") or "",
        "nas_host_display": extras_doc.get("nas_host_display") or "",
    }


def load_role_meta(roles_dir, service):
    """Return meta/install.yml for a service (searching platform/ then apps/),
    or None if neither exists."""
    for layer in ("platform", "apps"):
        path = os.path.join(roles_dir, layer, service, "meta", "install.yml")
        if os.path.exists(path):
            return _safe_yaml_load(path) or {}
    return None


def discover_role_container_names(roles_dir, service):
    """Parse the role's quadlets to find which container names it owns.

    Why: roles that share a rootless user (entephoto + entephoto-export)
    can't be distinguished by `podman ps --user <u>` alone — both would
    return the union. Filtering the dashboard's container list by names
    declared in each role's own quadlets keeps the per-role tables
    accurate.

    Logic: walk `templates/quadlets/*.container.j2` and
    `files/quadlets/*.container` for the role. Each quadlet's container
    name is either explicit via `ContainerName=<name>` (with `%N` =
    quadlet basename), or implicit (= basename without .container[.j2]).
    Returns a set of names; empty set means "no allowlist" → no
    filtering applied.
    """
    names = set()
    for layer in ("platform", "apps"):
        base = os.path.join(roles_dir, layer, service)
        for quadlet_dir, suffix in (
            (os.path.join(base, "templates", "quadlets"), ".container.j2"),
            (os.path.join(base, "files",     "quadlets"), ".container"),
        ):
            if not os.path.isdir(quadlet_dir):
                continue
            for entry in os.listdir(quadlet_dir):
                if not entry.endswith(suffix):
                    continue
                quadlet_basename = entry[: -len(suffix)]
                path = os.path.join(quadlet_dir, entry)
                # Default name from filename; overridden by an explicit
                # ContainerName= line (which may use %N to mean the
                # systemd unit name = the quadlet basename, or a Jinja
                # var like {{ podman_quadlet_app_name }} that the
                # podman_quadlet Galaxy role resolves to the role name
                # at deploy time). Jinja-templated names fall back to
                # the quadlet basename since podman_quadlet defaults
                # match that convention.
                resolved = quadlet_basename
                try:
                    with open(path) as fh:
                        for line in fh:
                            m = re.match(r"^\s*ContainerName=(.+?)\s*$", line)
                            if m:
                                val = m.group(1).strip()
                                if val == "%N" or "{{" in val or "{%" in val:
                                    resolved = quadlet_basename
                                else:
                                    resolved = val
                                break
                except Exception:
                    pass
                names.add(resolved)
    return names


def build_service_specs(inventory, roles_dir):
    """Translate inventory + role meta into the per-service display spec
    consumed by the rest of the generator. One entry per visible service."""
    specs = []
    enabled = list(inventory["platform_services"]) + list(inventory["apps"])
    caddy_domain = inventory["caddy_domain"]
    for svc in enabled:
        if svc in DASHBOARD_HIDDEN_SERVICES:
            continue
        meta = load_role_meta(roles_dir, svc)
        if meta is None:
            # No meta/install.yml — surface the service anyway with the
            # raw service id so the operator notices something's off.
            specs.append({
                "name": svc,
                "user": None,
                "urls": [],
                "rootful": False,
                "container_names": set(),
                "_warn": f"No meta/install.yml found for {svc}",
            })
            continue
        side = meta.get("side_effects") or {}
        users = side.get("my_linux_users") or {}
        user = next(iter(users.keys()), None) if users else None
        routes = side.get("caddy_reverse_proxy_services") or []
        urls = []
        for r in routes:
            sub = r.get("subdomain")
            if not sub:
                continue
            # `hidden: true` keeps the caddy route but skips the dashboard
            # link — useful for internal subdomains (e.g. Ente's auth/cast/
            # accounts/photos-s3 backplanes that Caddy must proxy but the
            # operator doesn't browse to).
            if r.get("hidden"):
                continue
            label = r.get("label") or sub.replace("-", " ").title()
            path = r.get("path") or ""
            urls.append({
                "label": label,
                "url": f"https://{sub}.{caddy_domain}{path}",
            })
        specs.append({
            "name": meta.get("display_name") or svc,
            "user": user,
            "urls": urls,
            # rootful flag: roles like shairportsync set this so the
            # container query runs as root (host namespace) instead of
            # `su - <user>` into the rootless user that owns nothing.
            "rootful": bool(meta.get("rootful")),
            # Allowlist of container names owned by this role's quadlets.
            # Filters podman ps output so co-tenant roles (e.g. entephoto +
            # entephoto-export both running as `entephoto`) don't show
            # each other's containers.
            "container_names": discover_role_container_names(roles_dir, svc),
        })
    return specs


# ---------------------------------------------------------------------------
# Podman helpers (unchanged from the pre-rewrite generator)
# ---------------------------------------------------------------------------

def run_cmd(cmd, timeout=30):
    """Run a shell command and return stdout."""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout,
        )
        return result.stdout.strip()
    except (subprocess.TimeoutExpired, Exception):
        return ""


def _podman_wrap(inner, user, rootful):
    """Wrap a podman invocation so it runs in the right user-namespace.
    Rootful: invoke directly (the generator already runs as root).
    Rootless: su into the service user so the per-user podman is queried."""
    if rootful:
        return "%s 2>/dev/null" % inner
    return "su - %s -c '%s' 2>/dev/null" % (user, inner)


def get_containers(user, rootful=False):
    """Get running containers — rootless or rootful per `rootful` flag."""
    output = run_cmd(_podman_wrap("podman ps --format json", user, rootful))
    if not output:
        return []
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return []


def get_container_inspect(user, name, rootful=False):
    """Inspect a specific container."""
    output = run_cmd(_podman_wrap("podman inspect %s" % name, user, rootful))
    if not output:
        return None
    try:
        data = json.loads(output)
        return data[0] if data else None
    except json.JSONDecodeError:
        return None


def get_image_inspect(user, image_id, rootful=False):
    """Inspect a container image."""
    output = run_cmd(
        _podman_wrap("podman image inspect %s" % image_id, user, rootful)
    )
    if not output:
        return None
    try:
        data = json.loads(output)
        return data[0] if data else None
    except json.JSONDecodeError:
        return None


def get_volume_size(user, volume_name, rootful=False):
    """Return the on-disk size of a volume in bytes, or None on failure.

    Rootless: `podman unshare du -sb` so the user namespace maps
    container-internal UIDs back to the host user (otherwise du can't
    read the contents). Rootful: plain du on the volume mountpoint.
    """
    if rootful:
        cmd = (
            "du -sb \"$(podman volume inspect %s --format '{{.Mountpoint}}')\" "
            "2>/dev/null"
        ) % volume_name
    else:
        inner = (
            "podman unshare du -sb "
            "\"$(podman volume inspect %s --format {{.Mountpoint}})\""
        ) % volume_name
        cmd = _podman_wrap(inner, user, False)
    output = run_cmd(cmd, timeout=300)
    if not output:
        return None
    try:
        return int(output.split()[0])
    except (ValueError, IndexError):
        return None


def get_auto_update_status(user, rootful=False):
    """Get update status using podman auto-update --dry-run.

    Returns a dict mapping container name to update status:
    'pending' = update available, 'false' = up to date, 'true' = updated,
    'failed' = registry check failed (e.g. Docker Hub anonymous rate limit).
    """
    output = run_cmd(
        _podman_wrap("podman auto-update --dry-run --format json", user, rootful),
        timeout=60,
    )
    if not output:
        return {}
    try:
        data = json.loads(output)
        return {item["ContainerName"]: item["Updated"] for item in data}
    except (json.JSONDecodeError, KeyError):
        return {}


def get_last_backup(service_name, backup_log):
    """Get last backup timestamp for a service from the log file."""
    if not os.path.exists(backup_log):
        return None
    last_ts = None
    try:
        with open(backup_log) as f:
            for line in f:
                if ("--- %s ---" % service_name) in line:
                    match = re.match(
                        r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]", line,
                    )
                    if match:
                        last_ts = match.group(1)
    except Exception:
        pass
    return last_ts


# ---------------------------------------------------------------------------
# State (persistent update-status fallback)
# ---------------------------------------------------------------------------

def load_state(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(path, state):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(state, f)
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

def format_size(num_bytes):
    if num_bytes is None:
        return "?"
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024.0:
            if unit == "B":
                return "%d %s" % (int(size), unit)
            return "%.1f %s" % (size, unit)
        size /= 1024.0
    return "%.1f PB" % size


def format_date(iso_str):
    if not iso_str:
        return "unknown"
    try:
        for fmt in (
            "%Y-%m-%dT%H:%M:%S.%f",
            "%Y-%m-%dT%H:%M:%S",
            "%Y-%m-%d %H:%M:%S",
        ):
            try:
                dt = datetime.strptime(iso_str[:26], fmt)
                return dt.strftime("%Y-%m-%d %H:%M")
            except ValueError:
                continue
        return iso_str[:19]
    except Exception:
        return str(iso_str)[:19]


def html_escape(s):
    return (
        str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        .replace('"', "&quot;")
    )


# ---------------------------------------------------------------------------
# Per-service data gathering
# ---------------------------------------------------------------------------

def gather_service(spec, last_known, backup_log, nas_host_display):
    """Resolve a service spec into rendered display data: aggregate status,
    container rows (each with its own image / update status / volumes), and
    last-backup."""
    user = spec.get("user")
    rootful = bool(spec.get("rootful"))
    allowlist = spec.get("container_names") or set()
    if user is None and not rootful:
        return {
            "name": spec["name"],
            "warn": spec.get("_warn", "no rootless user declared in meta"),
            "urls": spec.get("urls", []),
            "running": False,
            "containers": [],
            "last_backup": None,
        }

    containers = get_containers(user, rootful=rootful)
    update_status = get_auto_update_status(user, rootful=rootful)
    container_rows = []
    for ct in containers:
        ct_names = ct.get("Names")
        ct_name = (
            ct_names[0] if isinstance(ct_names, list) and ct_names
            else ct_names or ""
        )
        if "infra" in ct_name:
            # Pod infra containers carry no useful info for the operator.
            continue
        # Allowlist filter: only show containers declared by this role's
        # quadlets. Skip when the role has no quadlets (empty allowlist),
        # since "show everything the user owns" is the right behaviour
        # for single-tenant roles.
        if allowlist and ct_name not in allowlist:
            continue
        image = ct.get("Image", "")
        image_id = ct.get("ImageID", "")

        img_info = get_image_inspect(user, image_id, rootful=rootful) or {}
        created = img_info.get("Created", "")

        # Per-container mounted volumes — filter to volume-type (not bind),
        # since bind mounts are typically host config files (timezone, etc.)
        # the operator doesn't track on the dashboard.
        inspect = get_container_inspect(user, ct_name, rootful=rootful) or {}
        ct_volumes = []
        for m in inspect.get("Mounts") or []:
            if m.get("Type") != "volume":
                continue
            name = m.get("Name")
            if name:
                ct_volumes.append({
                    "name": name,
                    "size": get_volume_size(user, name, rootful=rootful),
                })

        # Update status with persistent-state fallback: see the long comment
        # in the previous generator main(). 'failed' means the registry check
        # errored (rate limit etc.); reuse the last known status rather than
        # flipping the badge to Unknown.
        raw = update_status.get(ct_name, "")
        if raw == "pending":
            update_available = True
            last_known[ct_name] = "pending"
        elif raw in ("false", "true"):
            update_available = False
            last_known[ct_name] = raw
        elif raw == "failed":
            fallback = last_known.get(ct_name)
            if fallback == "pending":
                update_available = True
            elif fallback in ("false", "true"):
                update_available = False
            else:
                update_available = None
        else:
            update_available = None

        container_rows.append({
            "name": ct_name,
            "image": image,
            "created": created,
            "update_available": update_available,
            "volumes": ct_volumes,
        })

    return {
        "name": spec["name"],
        "urls": spec.get("urls", []),
        "running": bool(container_rows),
        "containers": container_rows,
        "last_backup": get_last_backup(spec["name"], backup_log),
        "nas_host_display": nas_host_display,
    }


# ---------------------------------------------------------------------------
# HTML render — one table per service
# ---------------------------------------------------------------------------

CSS = """
  :root { color-scheme: light; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
         sans-serif; margin: 16px; background: #f5f5f5; color: #333; }
  h1 { color: #2c3e50; margin-bottom: 0.4em; }
  .footer { margin-top: 16px; color: #888; font-size: 0.85em; }
  .svc { width: 100%; max-width: 1200px; border-collapse: collapse;
         background: white; box-shadow: 0 1px 3px rgba(0,0,0,0.08);
         border-radius: 8px; overflow: hidden; margin: 0 0 18px 0; }
  .svc caption { caption-side: top; text-align: left;
                 background: #2c3e50; color: white;
                 padding: 10px 14px; font-weight: 500; font-size: 1.05em; }
  .svc caption .links { float: right; }
  .svc caption .links a { color: #d9eaf6; margin-left: 10px;
                          text-decoration: none; font-weight: 400; }
  .svc caption .links a:hover { text-decoration: underline; }
  .svc caption .last-backup { display: block; font-size: 0.8em;
                              color: #cdd7e0; font-weight: 400;
                              margin-top: 2px; }
  .svc th { background: #ecf0f1; color: #2c3e50; text-align: left;
            font-weight: 600; font-size: 0.85em; padding: 8px 12px;
            border-bottom: 1px solid #d0d7dc; }
  .svc td { padding: 10px 12px; border-bottom: 1px solid #eee;
            vertical-align: top; font-size: 0.9em; }
  .svc tr:last-child td { border-bottom: none; }
  .svc tr:hover td { background: #f8f9fa; }
  code { background: #eef1f4; padding: 1px 5px; border-radius: 3px;
         font-size: 0.85em; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 10px;
           font-size: 0.78em; font-weight: 500; vertical-align: middle; }
  .running { background: #d4edda; color: #155724; }
  .stopped { background: #f8d7da; color: #721c24; }
  .update { background: #fff3cd; color: #856404; }
  .current { background: #d4edda; color: #155724; }
  .unknown { background: #e2e3e5; color: #383d41; }
  .img-date { color: #6c757d; font-size: 0.82em; display: block; }
  .vol { display: block; }
  .vol-size { color: #6c757d; font-size: 0.82em; }
  .empty { color: #888; font-style: italic; }
  .warn-row td { background: #fff8e1; color: #856404; }

  /* Mobile: stack each row as label/value pairs */
  @media (max-width: 640px) {
    body { margin: 8px; }
    .svc { box-shadow: none; border-radius: 6px; }
    .svc caption .links { float: none; display: block; margin-top: 6px; }
    .svc caption .links a { margin: 0 10px 0 0; }
    .svc thead { display: none; }
    .svc, .svc tbody, .svc tr, .svc td { display: block; width: 100%; }
    .svc tr { border-bottom: 1px solid #ddd; padding: 6px 0; }
    .svc tr:last-child { border-bottom: none; }
    .svc td { border: none; padding: 4px 12px; }
    .svc td::before { content: attr(data-label) ":"; display: inline-block;
                      min-width: 95px; color: #6c757d;
                      font-size: 0.8em; font-weight: 600; margin-right: 6px;
                      text-transform: uppercase; }
    .svc td.ct-name::before { display: none; }
    .svc td.ct-name { font-weight: 600; font-size: 1em; padding-top: 8px; }
  }
"""


def render_status_badge(running):
    cls, text = ("running", "Running") if running else ("stopped", "Stopped")
    return '<span class="badge %s">%s</span>' % (cls, text)


def render_update_badge(state):
    if state is True:
        return '<span class="badge update">Update available</span>'
    if state is False:
        return '<span class="badge current">Up to date</span>'
    return '<span class="badge unknown">Unknown</span>'


def render_volumes_cell(volumes):
    if not volumes:
        return '<span class="empty">—</span>'
    parts = []
    for v in volumes:
        parts.append(
            '<span class="vol"><code>%s</code> '
            '<span class="vol-size">(%s)</span></span>'
            % (html_escape(v["name"]), html_escape(format_size(v.get("size"))))
        )
    return "".join(parts)


def render_service_table(svc):
    name = html_escape(svc["name"])
    status = render_status_badge(svc.get("running"))
    links_html = ""
    if svc.get("urls"):
        anchors = [
            '<a href="%s" target="_blank" rel="noopener">%s</a>'
            % (html_escape(u["url"]), html_escape(u["label"]))
            for u in svc["urls"]
        ]
        links_html = '<span class="links">%s</span>' % "".join(anchors)
    backup_html = ""
    last_backup = svc.get("last_backup")
    if last_backup:
        backup_html = (
            '<span class="last-backup">Last backup: %s</span>'
            % html_escape(last_backup)
        )

    caption = (
        '<caption>%s &nbsp;·&nbsp; %s%s%s</caption>'
        % (name, status, links_html, backup_html)
    )

    # Warn row (no rootless user / no meta): render the caption + a single
    # warn row so the operator notices something needs fixing.
    if svc.get("warn"):
        body = (
            '<tr class="warn-row"><td colspan="4">'
            '%s</td></tr>' % html_escape(svc["warn"])
        )
        return (
            '<table class="svc">%s'
            '<thead><tr><th>Container</th><th>Image</th>'
            '<th>Updates</th><th>Volumes</th></tr></thead>'
            '<tbody>%s</tbody></table>'
            % (caption, body)
        )

    rows = []
    if not svc.get("containers"):
        rows.append(
            '<tr><td colspan="4" class="empty">'
            'No containers running for this service.</td></tr>'
        )
    else:
        for ct in svc["containers"]:
            rows.append(
                '<tr>'
                '<td class="ct-name" data-label="Container"><code>%s</code></td>'
                '<td data-label="Image"><code>%s</code>'
                '<span class="img-date">%s</span></td>'
                '<td data-label="Updates">%s</td>'
                '<td data-label="Volumes">%s</td>'
                '</tr>' % (
                    html_escape(ct["name"]),
                    html_escape(ct["image"] or "—"),
                    html_escape(format_date(ct.get("created"))),
                    render_update_badge(ct.get("update_available")),
                    render_volumes_cell(ct.get("volumes", [])),
                )
            )

    return (
        '<table class="svc">%s'
        '<thead><tr><th>Container</th><th>Image</th>'
        '<th>Updates</th><th>Volumes</th></tr></thead>'
        '<tbody>%s</tbody></table>'
        % (caption, "".join(rows))
    )


def render_dashboard(services, generated_at):
    tables = "\n".join(render_service_table(s) for s in services)
    return (
        "<!DOCTYPE html>\n"
        '<html lang="en">\n<head>\n'
        '<meta charset="UTF-8">\n'
        '<meta name="viewport" content="width=device-width, '
        'initial-scale=1.0">\n'
        '<title>Home Server Dashboard</title>\n'
        '<style>%s</style>\n</head>\n<body>\n'
        '<h1>Home Server Dashboard</h1>\n%s\n'
        '<p class="footer">Generated: %s</p>\n'
        '</body>\n</html>\n'
        % (CSS, tables, html_escape(generated_at))
    )


# ---------------------------------------------------------------------------
# Legacy config-driven path (back-compat, deleted next release)
# ---------------------------------------------------------------------------

def legacy_specs_from_config(config):
    """Translate the old /etc/home-server-dashboard.yaml schema into the
    spec shape build_service_specs returns. Used only when the inventory
    layout can't be read (pre-migration host)."""
    specs = []
    for svc in config.get("services", []) or []:
        specs.append({
            "name": svc.get("name", "?"),
            "user": svc.get("user"),
            "urls": svc.get("urls", []),
            "_legacy_volumes": svc.get("volumes", []),
        })
    return specs


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    p.add_argument(
        "--inventory-dir",
        default=os.environ.get("HOMESERVER_INVENTORY_DIR", DEFAULT_INVENTORY_DIR),
        help="Path to inventory/ (default: %(default)s)",
    )
    p.add_argument(
        "--roles-dir",
        default=os.environ.get("HOMESERVER_ROLES_DIR", DEFAULT_ROLES_DIR),
        help="Path to roles/ (default: %(default)s)",
    )
    p.add_argument(
        "--host",
        default=os.environ.get("HOMESERVER_HOST", socket.gethostname().split(".")[0]),
        help="Hostname to render (default: this machine's short hostname)",
    )
    p.add_argument(
        "--output-dir", default=OUTPUT_DIR,
        help="Where to write index.html (default: %(default)s)",
    )
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)

    state = load_state(STATE_PATH)
    last_known = state.get("update_status", {}) or {}

    inventory = load_host_inventory(args.inventory_dir, args.host)
    have_inventory = bool(
        inventory["platform_services"] or inventory["apps"]
    )

    if have_inventory:
        specs = build_service_specs(inventory, args.roles_dir)
        nas_host_display = inventory["nas_host_display"]
    elif os.path.exists(LEGACY_CONFIG_PATH):
        # Pre-migration host — fall back to the old config file. This path
        # will be removed in a future release; the warning helps operators
        # notice they should re-deploy the dashboard role.
        print(
            "WARN: inventory not reachable at %s for %s; "
            "falling back to legacy %s"
            % (args.inventory_dir, args.host, LEGACY_CONFIG_PATH),
            file=sys.stderr,
        )
        legacy = _safe_yaml_load(LEGACY_CONFIG_PATH) or {}
        specs = legacy_specs_from_config(legacy)
        nas_host_display = legacy.get("nas_host_display", "")
    else:
        print(
            "ERROR: no inventory found at %s and no legacy config at %s — "
            "nothing to render."
            % (args.inventory_dir, LEGACY_CONFIG_PATH),
            file=sys.stderr,
        )
        return 1

    services = [
        gather_service(spec, last_known, BACKUP_LOG, nas_host_display)
        for spec in specs
    ]

    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    html = render_dashboard(services, generated_at)

    os.makedirs(args.output_dir, exist_ok=True)
    out = os.path.join(args.output_dir, "index.html")
    with open(out, "w") as f:
        f.write(html)

    state["update_status"] = last_known
    save_state(STATE_PATH, state)

    print("Dashboard generated: %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
