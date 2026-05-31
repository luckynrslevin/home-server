#!/bin/bash
# Smoke tests for scripts/inventory_merge.py (split-layout mode).
# Run from the repo root: bash scripts/test_inventory_merge.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MERGE="$SCRIPT_DIR/inventory_merge.py"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
report() {
    local what=$1 result=$2
    if [[ "$result" == "PASS" ]]; then
        echo "  ✓ $what"
        PASS=$((PASS+1))
    else
        echo "  ✗ $what"
        FAIL=$((FAIL+1))
    fi
}

# Common fixtures
echo "testpw" > "$WORK/vault.pw"
chmod 400 "$WORK/vault.pw"

# Build a baseline split host_vars dir. Reflects the on-disk layout
# homeserver.sh install writes: 00-services.yml, 01-linux-users.yml,
# 10-caddy.yml, 20-extras.yml (operator-managed), apps/.
make_baseline() {
    local dir=$1
    rm -rf "$dir"
    mkdir -p "$dir/apps"

    cat > "$dir/00-services.yml" << 'EOF'
# DO NOT EDIT — managed by homeserver.sh
os_base_hostname: testhost

platform_services:
  - caddy
  - dashboard
  - pihole
apps: []
EOF

    cat > "$dir/01-linux-users.yml" << 'EOF'
# DO NOT EDIT — managed by homeserver.sh
my_linux_users:
  ds:
    uid: 1000
    gid: 1000
  pihole:
    uid: 1005
    gid: 1005
EOF

    cat > "$dir/10-caddy.yml" << 'EOF'
# DO NOT EDIT — managed by homeserver.sh
caddy_domain: "test.dedyn.io"
caddy_reverse_proxy_services:
  - { subdomain: pihole, port: 8443, proto: https }
EOF

    cat > "$dir/20-extras.yml" << 'EOF'
# EDIT FREELY — homeserver.sh never touches this file.
operator_custom_var: "keep me"
EOF
}

cat > "$WORK/update_nextcloud.json" << 'EOF'
{
  "scalars": {
    "nextcloud_admin_password": {"value": "secret123", "vault": true}
  },
  "lists": {
    "apps": {"items": ["nextcloud"]},
    "caddy_reverse_proxy_services": {"items": [{"subdomain": "cloud", "port": 8090}]}
  },
  "dicts": {
    "my_linux_users": {"entries": {"nextcloud": {"uid": 1015, "gid": 1015}}}
  }
}
EOF

echo "Test 1: add routes each key to the right split file"
make_baseline "$WORK/test1"
python3 "$MERGE" --host-vars-dir "$WORK/test1" --service nextcloud \
    --vault-password-file "$WORK/vault.pw" --update "$WORK/update_nextcloud.json" --mode add
grep -q "^  - nextcloud$" "$WORK/test1/00-services.yml" \
    && report "nextcloud appended to apps in 00-services.yml" PASS \
    || report "nextcloud appended to apps in 00-services.yml" FAIL
grep -q "^  nextcloud:" "$WORK/test1/01-linux-users.yml" \
    && report "nextcloud entry added to my_linux_users in 01-linux-users.yml" PASS \
    || report "nextcloud entry added to my_linux_users in 01-linux-users.yml" FAIL
grep -q "subdomain: cloud" "$WORK/test1/10-caddy.yml" \
    && report "caddy reverse-proxy entry appended to 10-caddy.yml" PASS \
    || report "caddy reverse-proxy entry appended to 10-caddy.yml" FAIL
[[ -f "$WORK/test1/apps/nextcloud.yml" ]] \
    && grep -q "nextcloud_admin_password: !vault" "$WORK/test1/apps/nextcloud.yml" \
    && report "nextcloud_admin_password emitted as !vault into apps/nextcloud.yml" PASS \
    || report "nextcloud_admin_password emitted as !vault into apps/nextcloud.yml" FAIL
grep -q "operator_custom_var" "$WORK/test1/20-extras.yml" \
    && report "operator_custom_var preserved in 20-extras.yml" PASS \
    || report "operator_custom_var preserved in 20-extras.yml" FAIL

echo
echo "Test 2: add is idempotent (running twice is a no-op)"
cp -a "$WORK/test1" "$WORK/test2"
python3 "$MERGE" --host-vars-dir "$WORK/test2" --service nextcloud \
    --vault-password-file "$WORK/vault.pw" --update "$WORK/update_nextcloud.json" --mode add
diff -qr "$WORK/test1" "$WORK/test2" >/dev/null \
    && report "second add is no-op" PASS \
    || report "second add is no-op" FAIL

echo
echo "Test 3: remove reverses add"
make_baseline "$WORK/test3"
python3 "$MERGE" --host-vars-dir "$WORK/test3" --service nextcloud \
    --vault-password-file "$WORK/vault.pw" --update "$WORK/update_nextcloud.json" --mode add
python3 "$MERGE" --host-vars-dir "$WORK/test3" --service nextcloud \
    --vault-password-file "$WORK/vault.pw" --update "$WORK/update_nextcloud.json" --mode remove
! grep -rq "nextcloud" "$WORK/test3"/*.yml \
    && report "nextcloud refs gone from shared files" PASS \
    || report "nextcloud refs gone from shared files" FAIL
[[ ! -e "$WORK/test3/apps/nextcloud.yml" ]] \
    && report "apps/nextcloud.yml deleted when emptied" PASS \
    || report "apps/nextcloud.yml deleted when emptied" FAIL
grep -q 'operator_custom_var' "$WORK/test3/20-extras.yml" \
    && report "operator_custom_var survived round-trip" PASS \
    || report "operator_custom_var survived round-trip" FAIL

echo
echo "Test 4: add creates missing files (fresh-host case)"
rm -rf "$WORK/test4"
mkdir -p "$WORK/test4"
python3 "$MERGE" --host-vars-dir "$WORK/test4" --service nextcloud \
    --vault-password-file "$WORK/vault.pw" --update "$WORK/update_nextcloud.json" --mode add
grep -q "^  - nextcloud$" "$WORK/test4/00-services.yml" \
    && report "creates 00-services.yml apps list" PASS \
    || report "creates 00-services.yml apps list" FAIL
grep -q "^  nextcloud:" "$WORK/test4/01-linux-users.yml" \
    && report "creates 01-linux-users.yml my_linux_users dict" PASS \
    || report "creates 01-linux-users.yml my_linux_users dict" FAIL
[[ -f "$WORK/test4/apps/nextcloud.yml" ]] \
    && report "creates apps/nextcloud.yml for service-specific scalar" PASS \
    || report "creates apps/nextcloud.yml for service-specific scalar" FAIL

echo
echo "Test 5: set mode overwrites scalars in place (used by config <section>)"
make_baseline "$WORK/test5"
cat > "$WORK/set_caddy_domain.json" << 'EOF'
{
  "scalars": {
    "caddy_domain": {"value": "newdomain.dedyn.io", "vault": false}
  },
  "lists": {},
  "dicts": {}
}
EOF
python3 "$MERGE" --host-vars-dir "$WORK/test5" --service caddy \
    --vault-password-file "$WORK/vault.pw" --update "$WORK/set_caddy_domain.json" --mode set
grep -Eq '^caddy_domain: "?newdomain\.dedyn\.io"?$' "$WORK/test5/10-caddy.yml" \
    && report "caddy_domain overwritten in 10-caddy.yml" PASS \
    || report "caddy_domain overwritten in 10-caddy.yml" FAIL
# Existing siblings should remain intact.
grep -q 'subdomain: pihole' "$WORK/test5/10-caddy.yml" \
    && report "caddy_reverse_proxy_services sibling preserved" PASS \
    || report "caddy_reverse_proxy_services sibling preserved" FAIL
# Operator-only file untouched.
grep -q 'operator_custom_var' "$WORK/test5/20-extras.yml" \
    && report "operator_custom_var untouched" PASS \
    || report "operator_custom_var untouched" FAIL

echo
echo "=========================================="
echo "  $PASS passed, $FAIL failed"
echo "=========================================="
[[ $FAIL -eq 0 ]]
