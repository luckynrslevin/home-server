#!/usr/bin/env python3
"""
scripts/build_remove_update.py — translate a role's meta/install.yml
into the update.json that scripts/inventory_merge.py consumes for
remove mode.

Mirror of build_add_update.py for the remove direction. Pulls from
the `on_remove` block of the meta file:
  - inventory_vars_to_clear  → scalars to delete from inventory
  - side_effect_reversals=auto → remove side_effects entries from
    caddy_reverse_proxy_services + my_linux_users that this role added

Always also removes the service name from deploy_services.

Usage:
    build_remove_update.py --meta roles/nextcloud/meta/install.yml
                           --service nextcloud
                           --output /tmp/update.json
"""

import argparse
import json
import sys


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--meta", required=True)
    p.add_argument("--service", required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()

    try:
        import yaml
    except ImportError:
        print("ERROR: PyYAML not available.", file=sys.stderr)
        sys.exit(1)
    with open(args.meta) as f:
        meta = yaml.safe_load(f)

    on_remove = meta.get("on_remove") or {}
    side_effects = meta.get("side_effects") or {}

    # scalars to remove (the merge helper ignores `value` in remove mode,
    # so a placeholder is fine — we just need the keys)
    scalars = {k: {"value": "_"} for k in on_remove.get("inventory_vars_to_clear", []) or []}

    # lists — remove the items this role added (deploy_services + caddy entries)
    lists = {"deploy_services": {"items": [args.service]}}
    # side_effect_reversals: "auto" (default) reverses side_effects.
    # "none" skips reversal (operator wants the caddy/user entries
    # preserved even after the role is gone — rare; documented opt-out).
    reversals = on_remove.get("side_effect_reversals", "auto")
    if reversals == "auto":
        if "caddy_reverse_proxy_services" in side_effects:
            lists["caddy_reverse_proxy_services"] = {
                "items": side_effects["caddy_reverse_proxy_services"],
            }

    # dicts — remove this role's my_linux_users entries
    dicts = {}
    if reversals == "auto":
        if "my_linux_users" in side_effects:
            dicts["my_linux_users"] = {
                "entries": side_effects["my_linux_users"],
            }

    update = {"scalars": scalars, "lists": lists, "dicts": dicts}
    with open(args.output, "w") as f:
        json.dump(update, f, indent=2)


if __name__ == "__main__":
    main()
