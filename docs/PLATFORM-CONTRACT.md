# Platform Contract

This document defines the **only** ways an application role may depend on the rest of the project. Anything outside this contract is an app-internal concern.

## Layout

```
roles/
  platform/   # infrastructure every app may rely on
  apps/       # self-contained application roles
```

A new role is an **app by default**. Promote to platform only when ≥2 apps depend on it.

## Contract surface

Apps may rely on the following — nothing else.

### 1. Caddy reverse proxy (`roles/platform/caddy`)

Caddy fronts every web UI on `https://<svc>.<caddy_domain>` using the project's private CA. Apps emit a route snippet via the established Caddy pattern; per-service HTTP ports stay unpublished on the LAN.

Caddy is **mandatory** — `playbooks/site.yml` asserts it.

### 2. Pi-hole LAN DNS (`roles/platform/pihole`)

`*.<caddy_domain>` resolves to the home-server's LAN IP. Apps assume this exists; no app reaches into pihole config.

### 3. Backup manifests (`roles/platform/backup`)

Apps declare a `backup_manifest` in `defaults/main.yml`. The backup role reads manifests from any role in `deploy_services`. **App behavior is unchanged whether or not backup is deployed** — the manifest is free metadata.

Schema: see `roles/META-SCHEMA.md`.

### 4. `my_linux_users` inventory dict

Provides `{uid, gid, home, …}` per service user. Apps look up their own entry. The dict is owned by inventory (private repo).

### 5. `smtp_*` inventory vars

Optional. Apps that send mail (entephoto, paperless-ngx, nextcloud, backup alerts) consume the standard names (`smtp_host`, `smtp_port`, `smtp_username`, `smtp_password`, `smtp_from`) and must gracefully no-op if undefined.

### 6. `luckynrslevin.podman_quadlet` Galaxy role

Apps deploy quadlets via this role. No app should hand-roll `systemctl --user daemon-reload`, image pre-pulls, or registry fallback — call into the Galaxy role.

## Anti-contract

- An app role **MUST NOT** `include_role` / `import_role` another app's role.
- An app role **MUST NOT** read another app's defaults, files, templates, or volumes.
- A platform role **MUST NOT** depend on any app role.

These rules are enforced by `scripts/check-role-boundaries.sh`.

## Adding a new role

1. Default to `roles/apps/<name>/`.
2. Declare a `backup_manifest` in `defaults/main.yml` if the role has state worth restoring.
3. Add a `caddy_route` template if it has a web UI.
4. Add `<name>` to your host's `deploy_services` list.
5. Run `scripts/check-role-boundaries.sh` before opening a PR.
