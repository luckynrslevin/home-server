#!/usr/bin/env python3
"""
scripts/build_add_update.py — translate a role's meta/install.yml into
the update.json that scripts/inventory_merge.py consumes for add mode.

Resolves each declared inventory_var:
  - secret  → run `generator` (shell command); emit vaulted scalar
  - config  → leave for setup.sh's interactive prompt (skipped here;
              caller supplies via --extra-overrides if non-interactive)
  - computed → render `template` Jinja against existing inventory
  - literal → emit value verbatim

Side-effects → list/dict update entries (caddy_reverse_proxy_services,
my_linux_users). The service name itself is always appended to
deploy_services.

Inventory_vars already set in inventory are skipped (idempotent;
won't regenerate secrets or re-render computed values).

Usage:
    build_add_update.py --meta roles/nextcloud/meta/install.yml
                        --service nextcloud
                        --vault-password-file ~/.vaultpw
                        --target-host homeserver2
                        [--inventory-dir inventory]
                        [--overrides key1=val1 key2=val2]
                        --output /tmp/update.json
"""

import argparse
import json
import os
import shutil
import subprocess
import sys


def load_existing_inventory(target, vault_pw, inventory_dir):
    """Get target host's current inventory as a dict (with vault dicts
    still wrapped — we only need to check key presence for idempotency
    and to render computed templates against scalar values)."""
    env = {**os.environ, "ANSIBLE_VAULT_PASSWORD_FILE": vault_pw}
    if inventory_dir:
        env["ANSIBLE_INVENTORY"] = os.path.join(inventory_dir, "hosts.yml")
    try:
        result = subprocess.run(
            ["ansible-inventory", "--host", target],
            capture_output=True, text=True, check=True, env=env,
        )
    except subprocess.CalledProcessError:
        return {}
    if not result.stdout.strip():
        return {}
    return json.loads(result.stdout)


def render_template(template_str, ctx):
    """Render a small Jinja-like template. Uses jinja2 if available
    (ansible-core depends on it so it should be on PATH), otherwise
    falls back to str.format-style {key} substitution."""
    try:
        from jinja2 import Template
        return Template(template_str).render(**ctx)
    except ImportError:
        # Crude fallback — operators using `computed` vars need jinja2.
        return template_str.format(**ctx)


def resolve_secret(generator):
    """Run a shell generator command and return its stripped stdout."""
    result = subprocess.run(
        ["sh", "-c", generator],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.rstrip("\n")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--meta", required=True)
    p.add_argument("--service", required=True)
    p.add_argument("--vault-password-file", required=True)
    p.add_argument("--target-host", required=True)
    p.add_argument("--inventory-dir", default="inventory")
    p.add_argument("--overrides", nargs="*", default=[],
                   help="key=value pairs to use for `config`-type vars")
    p.add_argument("--output", required=True)
    args = p.parse_args()

    # Load meta
    try:
        import yaml
    except ImportError:
        print("ERROR: PyYAML not available.", file=sys.stderr)
        sys.exit(1)
    with open(args.meta) as f:
        meta = yaml.safe_load(f)

    # Parse overrides into a dict
    overrides = {}
    for kv in args.overrides:
        if "=" in kv:
            k, v = kv.split("=", 1)
            overrides[k] = v

    # Existing inventory (for idempotency + computed-template context)
    existing = load_existing_inventory(
        args.target_host, args.vault_password_file, args.inventory_dir,
    )

    # Resolve inventory_vars
    scalars = {}
    config_needed = []  # config-type vars not in inventory or overrides
    for var in meta.get("inventory_vars", []) or []:
        name = var["name"]
        vtype = var["type"]
        if name in existing:
            continue  # already set, don't clobber
        if name in overrides:
            scalars[name] = {"value": overrides[name], "vault": False}
            continue
        if vtype == "secret":
            value = resolve_secret(var["generator"])
            scalars[name] = {"value": value, "vault": var.get("vault", True)}
        elif vtype == "computed":
            value = render_template(var["template"], existing)
            scalars[name] = {"value": value, "vault": False}
        elif vtype == "literal":
            scalars[name] = {"value": var["value"], "vault": False}
        elif vtype == "config":
            # caller must supply via --overrides (or via interactive
            # prompt before invoking this script). Track for reporting.
            config_needed.append(var)
        else:
            print(f"ERROR: unknown var type {vtype!r} for {name!r}", file=sys.stderr)
            sys.exit(1)

    if config_needed:
        print("ERROR: the following `config`-type vars need values but"
              " weren't found in inventory or --overrides:", file=sys.stderr)
        for var in config_needed:
            prompt = var.get("prompt", var["name"])
            print(f"  --overrides {var['name']}=<...>  ({prompt})", file=sys.stderr)
        sys.exit(2)

    # Side effects → lists + dicts
    lists = {}
    dicts = {}
    side = meta.get("side_effects") or {}

    # deploy_services always gets the service name appended
    lists["deploy_services"] = {"items": [args.service]}

    if "caddy_reverse_proxy_services" in side:
        lists["caddy_reverse_proxy_services"] = {
            "items": side["caddy_reverse_proxy_services"],
        }
    if "my_linux_users" in side:
        dicts["my_linux_users"] = {"entries": side["my_linux_users"]}

    update = {"scalars": scalars, "lists": lists, "dicts": dicts}
    with open(args.output, "w") as f:
        json.dump(update, f, indent=2)


if __name__ == "__main__":
    main()
