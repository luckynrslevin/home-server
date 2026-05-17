# `roles/<svc>/meta/install.yml` — schema reference

This file is the role's contract with the lifecycle CLI
(`setup.sh add` / `setup.sh remove`, landing in Phase 5+ of the
unified-CLI work). Adding or removing a service to a deployment
uses only this metadata — no per-service code lives in `setup.sh`.

Phase 4 (this commit) ships these files for every optional role;
they aren't consumed yet. Phase 5 wires them up.

## Top-level fields

| Field | Required | Description |
|---|---|---|
| `display_name` | yes | Human-readable name shown in `setup.sh add` menu. |
| `description` | yes | One-line summary, also shown in the picker. |
| `rootful` | no | `true` for rootful containers (currently only shairportsync). Default `false`. |
| `inventory_vars` | yes | List of inventory keys this role needs. Can be empty `[]`. |
| `side_effects` | yes | Shared inventory keys this role modifies. |
| `playbooks` | yes | Ansible playbooks `setup.sh add` runs after inventory is updated, in order. |
| `on_remove` | yes | Reverse-side cleanup spec for `setup.sh remove`. |

## `inventory_vars[]` types

| `type` | Extra fields | Resolution order |
|---|---|---|
| `secret` | `generator` (shell command), `vault` (bool) | inventory > generate via `generator` > vault-encrypt if `vault: true` |
| `config` | `prompt` (text), `default` (literal string or `host_detect:<key>`) | inventory > host_detect > prompt with default |
| `computed` | `template` (Jinja against already-resolved values) | always rendered fresh; not stored separately |
| `literal` | `value` (any YAML scalar) | always the given value |

`host_detect` keys recognised today: `lan_subnet`, `lan_gateway`,
`timezone`, `hostname`, `server_user`. Extend in `setup.sh` as new
sources are needed.

## `side_effects`

A dict of shared inventory keys → values to merge in on `add`.

- `caddy_reverse_proxy_services`: list of entries appended to the
  inventory's list.
- `my_linux_users`: dict of user → `{uid, gid}` merged into the
  inventory's dict.

On `remove`, `setup.sh` reverses these (filters out the entries
this role added).

## `on_remove`

| Field | Description |
|---|---|
| `inventory_vars_to_clear` | List of inventory keys to delete on remove. Usually mirrors `inventory_vars` plus any `computed` URLs. |
| `volumes_to_preserve_unless_purge` | List of rootless podman volume names that survive `remove` by default. `setup.sh remove <svc> --purge` deletes them too. |

## Adding a new role

1. Write the role under `roles/<name>/` (defaults, tasks, templates, quadlets).
2. Create `roles/<name>/meta/install.yml` matching this schema.
3. Add the role to `playbooks/site.yml` behind `"<name>" in (deploy_services | default([]))`.
4. Add a single-service playbook at `playbooks/<name>.yml`.
5. That's it — `setup.sh add <name>` will pick it up via the meta file (once Phase 5 lands).
