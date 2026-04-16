# dashboard

Generates a static HTML status page summarizing every deployed
service: container status, image and image age, available updates,
volume sizes, last backup timestamp, and a clickable link to each
service's web UI. Driven by a `systemd` timer that re-renders every
15 minutes.

The HTML is written to `/var/www/dashboard/index.html` and served by
the [caddy](../caddy/README.md) role.

## Container image

None. Pure host-level Python script + systemd unit + timer.

## Service user

None. The generator runs as root via systemd so it can `su` into each
service user and call `podman ps`.

## Variables

| Variable                  | Default                                                                       | Purpose |
|---------------------------|-------------------------------------------------------------------------------|---------|
| `dashboard_config_file`   | `{{ inventory_dir }}/host_vars/{{ inventory_hostname }}/dashboard-config.yaml`| Per-host service definition consumed by the generator. |

The config file is the source of truth for which services appear on
the dashboard. `setup.sh` writes it from your service selection so
unselected services don't show up as `Stopped`.

Shape of `dashboard-config.yaml`:

```yaml
services:
  - name: Pi-hole
    user: pihole
    uid: 1005
    service: pihole
    urls:
      - { label: Admin UI, url: "https://<server-ip>:8443/admin" }
    volumes:
      - systemd-pihole-etc
      - systemd-pihole-dnsmasq
```

## Secrets

None.

## Firewall ports

None — served via [caddy](../caddy/README.md) on port 80.

## Endpoints

- Dashboard: `http://<server-ip>/` (served by caddy).

## Volumes

None of its own. Reads from each service's volumes to size them.
Writes HTML to the host directory `/var/www/dashboard`.

## Deployment

```bash
ansible-playbook playbooks/dashboard.yml --limit homeserver
```

The role triggers an immediate refresh (`systemctl start
home-server-dashboard.service`) and enables the timer
(`home-server-dashboard.timer`, every 15 min).

`setup.sh` also runs a manual refresh ~30 s after the playbook
finishes so the first page view shows real container state instead of
"all stopped" (rootless containers are still pulling/starting when
the playbook returns).

## Cross-role dependencies

Pairs with [caddy](../caddy/README.md), which serves the generated
HTML. The dashboard works best when most other roles are also
deployed — there's nothing to display otherwise.
