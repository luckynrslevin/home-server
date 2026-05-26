#!/usr/bin/env bash
# Enforce the platform/apps boundary documented in docs/PLATFORM-CONTRACT.md.
#
# Rules:
#   1. An app role MUST NOT include/import another app role.
#   2. An app role MUST NOT read files from another app role.
#   3. A platform role MUST NOT include/import or read from any app role.
#
# Exits non-zero on any violation. Intended for local pre-commit + CI use.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPS_DIR="$ROOT/roles/apps"
PLATFORM_DIR="$ROOT/roles/platform"
violations=0

[ -d "$APPS_DIR" ] || { echo "missing $APPS_DIR"; exit 2; }
[ -d "$PLATFORM_DIR" ] || { echo "missing $PLATFORM_DIR"; exit 2; }

apps=$(find "$APPS_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f\n')

check_cross_app() {
  # $1 = source app, $2 = file
  local src=$1 file=$2 other
  for other in $apps; do
    [ "$other" = "$src" ] && continue
    # Match: include_role:/import_role: name: <other>, or path refs into the other role
    if grep -E -q "(include_role|import_role)[^#]*\bname:\s*${other}\b" "$file" \
       || grep -E -q "roles/(apps/)?${other}/" "$file"; then
      echo "VIOLATION: $file references app '$other'"
      violations=$((violations+1))
    fi
  done
}

check_platform_to_app() {
  # $1 = file under platform/
  local file=$1 other
  for other in $apps; do
    if grep -E -q "(include_role|import_role)[^#]*\bname:\s*${other}\b" "$file" \
       || grep -E -q "roles/(apps/)?${other}/" "$file"; then
      echo "VIOLATION: platform file $file references app '$other'"
      violations=$((violations+1))
    fi
  done
}

# 1. Scan app roles for cross-app refs.
for app in $apps; do
  while IFS= read -r f; do
    check_cross_app "$app" "$f"
  done < <(find "$APPS_DIR/$app" -type f \( -name '*.yml' -o -name '*.j2' \))
done

# 2. Scan platform roles for any app refs.
while IFS= read -r f; do
  check_platform_to_app "$f"
done < <(find "$PLATFORM_DIR" -type f \( -name '*.yml' -o -name '*.j2' \))

if [ "$violations" -gt 0 ]; then
  echo
  echo "FAIL: $violations boundary violation(s). See docs/PLATFORM-CONTRACT.md."
  exit 1
fi

echo "OK: no platform/apps boundary violations."
