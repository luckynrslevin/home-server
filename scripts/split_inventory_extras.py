#!/usr/bin/env python3
"""
scripts/split_inventory_extras.py — capture operator-added keys into 20-extras.yml.

Called by `homeserver.sh install` after the new split-layout files
(00-services.yml, 10-caddy.yml, apps/<name>.yml, etc.) have been written.
The tool only emits the keys it explicitly manages; any operator-added
keys present in the pre-split snapshot (e.g. jellyfin_nas_mounts,
pihole_local_dns_records) would be silently dropped on rebuild.

This script:
  1. Loads the PRE-SPLIT snapshot of main.yml (--old).
  2. Loads every *.yml under the host_vars dir (and apps/ subdir) to
     compute the union of tool-managed top-level keys.
  3. Writes any old-but-not-managed keys into --extras, preserving
     comments and !vault tags.

Idempotent: re-runs with no unmanaged keys produce zero diff.
The --extras file always exists after a successful run — empty if
nothing to preserve, with a stable header so it is safe for the
operator to hand-edit afterward (the tool never rewrites it).

Usage:
    split_inventory_extras.py --old <snapshot.yml> --host-vars-dir <dir> --extras <path>
"""

import argparse
import io
import os
import sys

try:
    from ruamel.yaml import YAML
    from ruamel.yaml.comments import CommentedMap
except ImportError:
    print("ERROR: ruamel.yaml not installed.", file=sys.stderr)
    sys.exit(1)


EXTRAS_HEADER = (
    "# EDIT FREELY — homeserver.sh never touches this file.\n"
    "#\n"
    "# Operator-managed host_vars: anything the install tool does not\n"
    "# write itself lives here. Add overrides (custom Pi-hole DNS records,\n"
    "# Jellyfin NFS mounts, Caddy extras, NAS snapshot trigger config, etc.)\n"
    "# below.\n"
    "##################################################################################################\n"
)


def make_yaml() -> YAML:
    yaml = YAML(typ="rt")
    yaml.indent(mapping=2, sequence=4, offset=2)
    yaml.preserve_quotes = True
    yaml.width = 4096
    return yaml


def collect_managed_keys(yaml: YAML, host_vars_dir: str) -> set:
    """Walk every *.yml under host_vars_dir + apps/ and return the union of
    top-level keys. These are the keys the tool wrote on this run."""
    keys: set = set()
    for root, _, files in os.walk(host_vars_dir):
        for name in files:
            if not name.endswith(".yml") or name.startswith("."):
                continue
            path = os.path.join(root, name)
            with open(path) as f:
                doc = yaml.load(f)
            if isinstance(doc, CommentedMap):
                keys.update(doc.keys())
    return keys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", required=True, help="Pre-split snapshot of main.yml")
    ap.add_argument("--host-vars-dir", required=True,
                    help="Directory containing the freshly-emitted split files")
    ap.add_argument("--extras", required=True, help="Target file for unmanaged keys")
    ap.add_argument("--ignore", action="append", default=[],
                    help="Top-level key to drop from migration (deprecated keys "
                         "that have been semantically replaced). May be repeated.")
    args = ap.parse_args()

    yaml = make_yaml()

    if not os.path.exists(args.old) or os.path.getsize(args.old) == 0:
        # Fresh install — no snapshot. Still ensure --extras exists with header.
        if not os.path.exists(args.extras):
            with open(args.extras, "w") as f:
                f.write(EXTRAS_HEADER)
        return 0

    with open(args.old) as f:
        old_doc = yaml.load(f)
    if not isinstance(old_doc, CommentedMap):
        if not os.path.exists(args.extras):
            with open(args.extras, "w") as f:
                f.write(EXTRAS_HEADER)
        return 0

    managed = collect_managed_keys(yaml, args.host_vars_dir)
    ignore = set(args.ignore)
    unmanaged = [k for k in old_doc.keys() if k not in managed and k not in ignore]

    if not unmanaged:
        if not os.path.exists(args.extras):
            with open(args.extras, "w") as f:
                f.write(EXTRAS_HEADER)
        return 0

    preserved = CommentedMap()
    for k in unmanaged:
        preserved[k] = old_doc[k]
        if k in old_doc.ca.items:
            preserved.ca.items[k] = old_doc.ca.items[k]

    buf = io.StringIO()
    yaml.dump(preserved, buf)
    body = buf.getvalue()

    with open(args.extras, "w") as f:
        f.write(EXTRAS_HEADER)
        f.write(body)

    print(f"Migrated {len(unmanaged)} operator-added key(s) to "
          f"{args.extras}: {', '.join(unmanaged)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
