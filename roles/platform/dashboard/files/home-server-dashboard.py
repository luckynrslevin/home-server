#!/usr/bin/env python3
"""
Home Server Dashboard Generator

Generates a static HTML dashboard showing:
- Service name, status, container image + version
- Image update availability (local vs registry digest)
- Volume list per service
- Last backup timestamp per service
- Clickable URLs for each service

Runs as root (needs to su to each service user for podman queries).
Output: /var/www/dashboard/index.html
"""

import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

# Try to import yaml, fall back to simple parser
try:
    import yaml
except ImportError:
    yaml = None

CONFIG_PATH = "/etc/home-server-dashboard.yaml"
OUTPUT_DIR = "/var/www/dashboard"
BACKUP_LOG = "/var/log/home-server-backup.log"
BACKUP_DIR = "/var/log"
# Persistent state: last-known update status per container. Used to keep
# the previous status visible when a registry check fails (e.g. Docker Hub
# rate limit) instead of falling back to "Unknown".
STATE_PATH = "/var/lib/home-server-dashboard/state.json"


def load_config(path):
    """Load YAML config file."""
    with open(path) as f:
        if yaml:
            return yaml.safe_load(f)
        # Minimal YAML parser fallback — use PyYAML if available
        import json as _json
        # Convert simple YAML to JSON-ish (only works for flat structures)
        raise SystemExit("PyYAML required: pip install pyyaml")


def run_cmd(cmd, timeout=30):
    """Run a shell command and return stdout."""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return result.stdout.strip()
    except (subprocess.TimeoutExpired, Exception):
        return ""


def get_containers(user):
    """Get running containers for a rootless user."""
    output = run_cmd(
        "su - %s -c 'podman ps --format json' 2>/dev/null" % user
    )
    if not output:
        return []
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return []


def get_container_inspect(user, name):
    """Inspect a specific container."""
    output = run_cmd(
        "su - %s -c 'podman inspect %s' 2>/dev/null" % (user, name)
    )
    if not output:
        return None
    try:
        data = json.loads(output)
        return data[0] if data else None
    except json.JSONDecodeError:
        return None


def get_image_inspect(user, image_id):
    """Inspect a container image."""
    output = run_cmd(
        "su - %s -c 'podman image inspect %s' 2>/dev/null" % (user, image_id)
    )
    if not output:
        return None
    try:
        data = json.loads(output)
        return data[0] if data else None
    except json.JSONDecodeError:
        return None


def get_volumes(user):
    """Get volumes for a rootless user."""
    output = run_cmd(
        "su - %s -c 'podman volume ls --format json' 2>/dev/null" % user
    )
    if not output:
        return []
    try:
        return json.loads(output)
    except json.JSONDecodeError:
        return []


def get_volume_size(user, volume_name):
    """Return the on-disk size of a volume in bytes, or None on failure.

    Uses `podman unshare du -sb` so the rootless user namespace maps the
    container-internal UIDs back to the host user, making the volume
    contents readable for du.
    """
    cmd = (
        "su - %s -c 'podman unshare du -sb "
        "\"$(podman volume inspect %s --format {{.Mountpoint}})\" 2>/dev/null' "
        "2>/dev/null"
    ) % (user, volume_name)
    output = run_cmd(cmd, timeout=300)
    if not output:
        return None
    try:
        return int(output.split()[0])
    except (ValueError, IndexError):
        return None


def load_state(path):
    """Load persistent state (last-known update status per container)."""
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(path, state):
    """Persist state. Best-effort; failure to save is non-fatal."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(state, f)
    except OSError:
        pass


def format_size(num_bytes):
    """Format a byte count as a human-readable string."""
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


def get_auto_update_status(user):
    """Get update status using podman auto-update --dry-run.

    Returns a dict mapping container name to update status:
    'pending' = update available, 'false' = up to date, 'true' = updated.
    """
    output = run_cmd(
        "su - %s -c 'podman auto-update --dry-run --format json' 2>/dev/null"
        % user,
        timeout=60,
    )
    if not output:
        return {}
    try:
        data = json.loads(output)
        return {
            item["ContainerName"]: item["Updated"]
            for item in data
        }
    except (json.JSONDecodeError, KeyError):
        return {}


def get_last_backup(service_name, backup_log, backup_dir):
    """Get last backup timestamp for a service from the log file."""
    if not os.path.exists(backup_log):
        return None

    last_ts = None
    try:
        with open(backup_log) as f:
            for line in f:
                if ("--- %s ---" % service_name) in line:
                    # Extract timestamp from log line
                    match = re.match(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]", line)
                    if match:
                        last_ts = match.group(1)
    except Exception:
        pass

    return last_ts


def format_date(iso_str):
    """Format ISO date string to readable format."""
    if not iso_str:
        return "unknown"
    try:
        # Handle various formats
        for fmt in [
            "%Y-%m-%dT%H:%M:%S.%f",
            "%Y-%m-%dT%H:%M:%S",
            "%Y-%m-%d %H:%M:%S",
        ]:
            try:
                dt = datetime.strptime(iso_str[:26], fmt)
                return dt.strftime("%Y-%m-%d %H:%M")
            except ValueError:
                continue
        return iso_str[:19]
    except Exception:
        return str(iso_str)[:19]


def generate_html(services_data, generated_at, nas_host_display):
    """Generate the HTML dashboard page."""
    rows = []
    for svc in services_data:
        # URLs
        url_links = ""
        for u in svc.get("urls", []):
            url_links += '<a href="%s" target="_blank">%s</a> ' % (
                u["url"], u["label"]
            )

        # Volumes (name + size + optional backup share path)
        vol_entries = []
        for v in svc.get("volumes_info", []):
            entry = "%s <small>(%s)</small>" % (
                v["name"], format_size(v.get("size"))
            )
            share = v.get("backup_share")
            if share:
                if nas_host_display:
                    entry += ' <small class="backup-path">→ %s/%s</small>' % (
                        nas_host_display, share
                    )
                else:
                    entry += ' <small class="backup-path">→ %s</small>' % share
            vol_entries.append(entry)
        vol_list = "<br>".join(vol_entries)

        # Container status
        if svc.get("running"):
            status_badge = '<span class="badge running">Running</span>'
        else:
            status_badge = '<span class="badge stopped">Stopped</span>'

        # Backup status
        backup_ts = svc.get("last_backup", "")
        if backup_ts:
            backup_str = backup_ts
        else:
            backup_str = "No backup"

        for ct in svc.get("containers", [{}]):
            # Per-container update status
            ct_update = ct.get("update_available")
            if ct_update is True:
                update_badge = '<span class="badge update">Update available</span>'
            elif ct_update is False:
                update_badge = '<span class="badge current">Up to date</span>'
            else:
                update_badge = '<span class="badge unknown">Unknown</span>'

            rows.append("""
        <tr>
            <td><strong>%s</strong></td>
            <td>%s</td>
            <td><code>%s</code></td>
            <td>%s</td>
            <td>%s</td>
            <td>%s</td>
            <td><small>%s</small></td>
            <td>%s</td>
        </tr>""" % (
                svc["name"],
                status_badge,
                ct.get("image", "—"),
                format_date(ct.get("created", "")),
                update_badge,
                url_links or "—",
                vol_list or "—",
                backup_str,
            ))

    html = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Home Server Dashboard</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         margin: 20px; background: #f5f5f5; color: #333; }
  h1 { color: #2c3e50; }
  table { border-collapse: collapse; width: 100%%; background: white;
          box-shadow: 0 1px 3px rgba(0,0,0,0.1); border-radius: 8px;
          overflow: hidden; }
  th { background: #2c3e50; color: white; padding: 12px 15px;
       text-align: left; font-weight: 500; }
  td { padding: 10px 15px; border-bottom: 1px solid #eee; }
  tr:hover { background: #f8f9fa; }
  code { background: #e8e8e8; padding: 2px 6px; border-radius: 3px;
         font-size: 0.85em; }
  a { color: #3498db; text-decoration: none; margin-right: 8px; }
  a:hover { text-decoration: underline; }
  .badge { padding: 3px 8px; border-radius: 12px; font-size: 0.8em;
           font-weight: 500; }
  .running { background: #d4edda; color: #155724; }
  .stopped { background: #f8d7da; color: #721c24; }
  .update { background: #fff3cd; color: #856404; }
  .current { background: #d4edda; color: #155724; }
  .unknown { background: #e2e3e5; color: #383d41; }
  .backup-path { color: #6c757d; font-style: italic; }
  .footer { margin-top: 15px; color: #888; font-size: 0.85em; }
</style>
</head>
<body>
<h1>Home Server Dashboard</h1>
<table>
  <thead>
    <tr>
      <th>Service</th>
      <th>Status</th>
      <th>Image</th>
      <th>Image Date</th>
      <th>Updates</th>
      <th>Links</th>
      <th>Volumes</th>
      <th>Last Backup</th>
    </tr>
  </thead>
  <tbody>
    %s
  </tbody>
</table>
<p class="footer">Generated: %s</p>
</body>
</html>""" % ("\n".join(rows), generated_at)

    return html


def main():
    config = load_config(CONFIG_PATH)
    state = load_state(STATE_PATH)
    # Map of container_name -> "true"/"false" (string), the last fresh status
    # we've ever seen. Used as a fallback when this run gets "failed" (e.g.
    # Docker Hub anonymous rate limit) so the dashboard keeps showing the
    # last known good status instead of flipping to "Unknown".
    last_known = state.get("update_status", {})
    services_data = []

    for svc in config.get("services", []):
        user = svc["user"]
        # Volumes config supports two forms:
        #   - bare string: "vol-name"
        #   - object: {name: "vol-name", backup_share: "backup-tar"}
        volumes_info = []
        for v in svc.get("volumes", []):
            if isinstance(v, dict):
                vname = v["name"]
                backup_share = v.get("backup_share")
            else:
                vname = v
                backup_share = None
            volumes_info.append({
                "name": vname,
                "size": get_volume_size(user, vname),
                "backup_share": backup_share,
            })
        svc_data = {
            "name": svc["name"],
            "urls": svc.get("urls", []),
            "volumes_info": volumes_info,
            "running": False,
            "containers": [],
            "last_backup": get_last_backup(
                svc["name"], BACKUP_LOG, BACKUP_DIR
            ),
        }

        # Get containers
        containers = get_containers(user)
        if containers:
            svc_data["running"] = True

        # Get update status via podman auto-update --dry-run
        update_status = get_auto_update_status(user)

        for ct in containers:
            ct_name = ct.get("Names", [""])[0] if isinstance(ct.get("Names"), list) else ct.get("Names", "")
            image = ct.get("Image", "")
            image_id = ct.get("ImageID", "")

            # Skip infra containers
            if "infra" in ct_name:
                continue

            # Get image details
            img_info = get_image_inspect(user, image_id)
            created = ""
            if img_info:
                created = img_info.get("Created", "")

            # Check update status from podman auto-update.
            # On "failed" (typically Docker Hub rate limit), reuse the last
            # known fresh status from persistent state instead of flipping
            # the badge to "Unknown".
            ct_update = update_status.get(ct_name, "")
            if ct_update == "pending":
                update_available = True
                last_known[ct_name] = "pending"
            elif ct_update in ("false", "true"):
                update_available = False
                last_known[ct_name] = ct_update
            elif ct_update == "failed":
                fallback = last_known.get(ct_name)
                if fallback == "pending":
                    update_available = True
                elif fallback in ("false", "true"):
                    update_available = False
                else:
                    update_available = None
            else:
                update_available = None

            svc_data["containers"].append({
                "name": ct_name,
                "image": image,
                "created": created,
                "update_available": update_available,
            })

        if not svc_data["containers"]:
            svc_data["containers"] = [{"name": "", "image": "—", "created": ""}]

        services_data.append(svc_data)

    # Generate HTML. nas_host_display is an optional top-level key in the
    # dashboard YAML config — e.g. "nas:/volume1" — shown as a prefix next
    # to each volume's backup_share. Kept out of the script source because
    # it's environment-specific.
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    nas_host_display = config.get("nas_host_display", "")
    html = generate_html(services_data, now, nas_host_display)

    # Write output
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    output_path = os.path.join(OUTPUT_DIR, "index.html")
    with open(output_path, "w") as f:
        f.write(html)

    # Persist last-known update statuses for the next run.
    state["update_status"] = last_known
    save_state(STATE_PATH, state)

    print("Dashboard generated: %s" % output_path)


if __name__ == "__main__":
    main()
