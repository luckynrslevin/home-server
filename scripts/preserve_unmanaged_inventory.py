#!/usr/bin/env python3
"""
scripts/preserve_unmanaged_inventory.py — preserve operator-added keys.

Called by `setup.sh install` immediately after the heredoc emits the
canonical main.yml. The heredoc only knows about the keys setup.sh
itself manages; any operator-added keys (e.g. jellyfin_nas_mounts,
shairportsync_airplay_name) would be silently dropped on rebuild.

This script:
  1. Loads the PRE-EMIT snapshot of main.yml (--old).
  2. Loads the freshly-emitted main.yml (--new).
  3. Collects top-level keys present in old but not in new.
  4. Appends them (with their comments + vault tags preserved) to --new.

Idempotent: re-runs with no unmanaged keys produce zero diff.

Usage:
    preserve_unmanaged_inventory.py --old <snapshot.yml> --new <main.yml>
"""

import argparse
import sys

try:
    from ruamel.yaml import YAML
    from ruamel.yaml.comments import CommentedMap
except ImportError:
    print("ERROR: ruamel.yaml not installed.", file=sys.stderr)
    sys.exit(1)


def make_yaml() -> YAML:
    yaml = YAML(typ="rt")
    yaml.indent(mapping=2, sequence=4, offset=2)
    yaml.preserve_quotes = True
    yaml.width = 4096
    return yaml


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", required=True, help="Pre-emit snapshot of main.yml")
    ap.add_argument("--new", required=True, help="Freshly-emitted main.yml to append to")
    args = ap.parse_args()

    yaml = make_yaml()

    with open(args.old) as f:
        old_doc = yaml.load(f)
    if not isinstance(old_doc, CommentedMap):
        # Empty or non-mapping snapshot — nothing to preserve.
        return 0

    with open(args.new) as f:
        new_doc = yaml.load(f)
    if not isinstance(new_doc, CommentedMap):
        new_doc = CommentedMap()

    new_keys = set(new_doc.keys())
    unmanaged = [k for k in old_doc.keys() if k not in new_keys]
    if not unmanaged:
        return 0

    # Build a fresh document containing only the unmanaged keys, so
    # ruamel can dump just those (preserving their comments + tags).
    preserved = CommentedMap()
    for k in unmanaged:
        preserved[k] = old_doc[k]
        # Carry over the comment attached to this key, if any.
        if k in old_doc.ca.items:
            preserved.ca.items[k] = old_doc.ca.items[k]

    # Append: render preserved as YAML and append after a header.
    import io
    buf = io.StringIO()
    yaml.dump(preserved, buf)
    body = buf.getvalue()

    with open(args.new, "a") as f:
        f.write("\n")
        f.write("##################################################################################################\n")
        f.write("### Operator-added keys (preserved across `setup.sh install` re-runs)\n")
        f.write("##################################################################################################\n")
        f.write(body)

    # Report what was preserved (visible in setup.sh output).
    print(f"Preserved {len(unmanaged)} unmanaged key(s): {', '.join(unmanaged)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
