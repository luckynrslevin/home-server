# caddy

Front-door web server. Listens on port 80 and serves the static
[dashboard](../dashboard/README.md) HTML out of `/var/www/dashboard`.
Today it does no reverse-proxy work — services expose their own ports
directly — but it's the natural place to add one.

## Container image

`docker.io/library/caddy:latest`

## Service user

`webproxy` (UID/GID 1011) — rootless.

## Variables

| Variable            | Default | Purpose                                                                |
|---------------------|---------|------------------------------------------------------------------------|
| `caddy_listen_port` | `9080`  | Internal listen port. Firewall port-forwards `80 → caddy_listen_port`. |

## Secrets

None.

## Firewall ports

- **80/tcp** (port-forward → `caddy_listen_port`)

## Endpoints

- Dashboard: `http://<server-ip>/`

## Volumes

- `caddy-data` — TLS certificates and Caddy state.
- `caddy-config` — runtime config.
- `caddy-etc` — staged `Caddyfile`.
- Bind mount: `/var/www/dashboard:ro` — dashboard HTML written by the
  dashboard role.

## Deployment

```bash
ansible-playbook playbooks/caddy.yml --limit homeserver
```

The role:
1. Creates `/var/www/dashboard` with SELinux label `container_file_t`
   so the rootless container can read it.
2. Stages the `Caddyfile` into `caddy-etc`.
3. Runs `caddy reload` at the end so config changes apply without a
   container restart.

## Cross-role dependencies

Pairs with [dashboard](../dashboard/README.md). Caddy is the public
face; dashboard is the content. Either can be deployed first; the
other will start serving / writing on its next run.
