#!/bin/bash
# Re-render all D2 diagrams in docs/diagrams/ to SVG.
# Run after editing any docs/diagrams/*.d2 source.
#
# Usage:  bash scripts/render-diagrams.sh
# Prereq: dnf install d2     (Fedora 43+)

set -euo pipefail

cd "$(dirname "$0")/.."

shopt -s nullglob
sources=(docs/diagrams/*.d2)
if (( ${#sources[@]} == 0 )); then
    echo "No .d2 sources found under docs/diagrams/." >&2
    exit 1
fi

for src in "${sources[@]}"; do
    out="${src%.d2}.svg"
    echo "→ $src → $out"
    d2 "$src" "$out"
done

echo "Done. ${#sources[@]} diagram(s) rendered."
