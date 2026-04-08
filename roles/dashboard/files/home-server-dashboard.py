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
BACKUP_LOG = "/home/ds/backup/backup.log"
BACKUP_DIR = "/home/ds/backup"


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


def generate_html(services_data, generated_at):
    """Generate the HTML dashboard page."""
    rows = []
    for svc in services_data:
        # URLs
        url_links = ""
        for u in svc.get("urls", []):
            url_links += '<a href="%s" target="_blank">%s</a> ' % (
                u["url"], u["label"]
            )

        # Volumes
        vol_list = "<br>".join(svc.get("volume_names", []))

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
    services_data = []

    for svc in config.get("services", []):
        user = svc["user"]
        svc_data = {
            "name": svc["name"],
            "urls": svc.get("urls", []),
            "volume_names": svc.get("volumes", []),
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

            # Check update status from podman auto-update
            ct_update = update_status.get(ct_name, "")
            if ct_update == "pending":
                update_available = True
            elif ct_update in ("false", "true"):
                update_available = False
            elif ct_update == "failed":
                update_available = None  # check failed, show as unknown
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

    # Generate HTML
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    html = generate_html(services_data, now)

    # Write output
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    output_path = os.path.join(OUTPUT_DIR, "index.html")
    with open(output_path, "w") as f:
        f.write(html)

    print("Dashboard generated: %s" % output_path)


if __name__ == "__main__":
    main()
