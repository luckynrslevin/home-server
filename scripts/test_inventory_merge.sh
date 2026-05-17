#!/bin/bash
# Smoke tests for scripts/inventory_merge.py.
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

cat > "$WORK/baseline.yml" << 'EOF'
##################################################################################################
### Host identity
os_base_hostname: testhost

##################################################################################################
### Services to deploy
deploy_services:
  - caddy
  - dashboard
  - pihole

##################################################################################################
### Linux users
my_linux_users:
  ds:
    uid: 1000
    gid: 1000
  pihole:
    uid: 1005
    gid: 1005
##################################################################################################

### Caddy
caddy_domain: "test.dedyn.io"

# Operator-added unmanaged key — must survive
operator_custom_var: "keep me"

caddy_reverse_proxy_services:
  - { subdomain: pihole, port: 8443, proto: https }
EOF

cat > "$WORK/update_nextcloud.json" << 'EOF'
{
  "scalars": {
    "nextcloud_admin_password": {"value": "secret123", "vault": true}
  },
  "lists": {
    "deploy_services": {"items": ["nextcloud"]},
    "caddy_reverse_proxy_services": {"items": [{"subdomain": "cloud", "port": 8090}]}
  },
  "dicts": {
    "my_linux_users": {"entries": {"nextcloud": {"uid": 1015, "gid": 1015}}}
  }
}
EOF

echo "Test 1: add produces valid YAML with all the expected pieces"
cp "$WORK/baseline.yml" "$WORK/test1.yml"
python3 "$MERGE" --inventory "$WORK/test1.yml" --vault-password-file "$WORK/vault.pw" --update "$WORK/update_nextcloud.json" --mode add
python3 -c "import yaml; d=yaml.safe_load(open('$WORK/test1.yml').read().replace('!vault |', '!vault ').replace('!vault ', ''))" 2>/dev/null \
    && report "parses as YAML" PASS || report "parses as YAML" FAIL
grep -q "^  - nextcloud$" "$WORK/test1.yml" \
    && report "nextcloud in deploy_services" PASS || report "nextcloud in deploy_services" FAIL
grep -q "^  nextcloud:" "$WORK/test1.yml" \
    && report "nextcloud in my_linux_users" PASS || report "nextcloud in my_linux_users" FAIL
grep -q "nextcloud_admin_password: !vault" "$WORK/test1.yml" \
    && report "nextcloud_admin_password emitted as !vault" PASS || report "nextcloud_admin_password emitted as !vault" FAIL
grep -q "operator_custom_var" "$WORK/test1.yml" \
    && report "operator_custom_var preserved" PASS || report "operator_custom_var preserved" FAIL
grep -q '### Linux users' "$WORK/test1.yml" \
    && report "section comments preserved" PASS || report "section comments preserved" FAIL

echo
echo "Test 2: add is idempotent (running twice is a no-op)"
cp "$WORK/test1.yml" "$WORK/test2.yml"
python3 "$MERGE" --inventory "$WORK/test2.yml" --vault-password-file "$WORK/vault.pw" --update "$WORK/update_nextcloud.json" --mode add
diff -q "$WORK/test1.yml" "$WORK/test2.yml" >/dev/null \
    && report "second add is no-op" PASS || report "second add is no-op" FAIL

echo
echo "Test 3: remove reverses add (modulo cosmetic noise)"
cp "$WORK/baseline.yml" "$WORK/test3.yml"
python3 "$MERGE" --inventory "$WORK/test3.yml" --vault-password-file "$WORK/vault.pw" --update "$WORK/update_nextcloud.json" --mode add
python3 "$MERGE" --inventory "$WORK/test3.yml" --vault-password-file "$WORK/vault.pw" --update "$WORK/update_nextcloud.json" --mode remove
! grep -q "nextcloud" "$WORK/test3.yml" \
    && report "nextcloud references all gone" PASS || report "nextcloud references all gone" FAIL
grep -q '### Linux users' "$WORK/test3.yml" \
    && report "### Linux users comment survived round-trip" PASS || report "### Linux users comment survived round-trip" FAIL
grep -q '### Caddy' "$WORK/test3.yml" \
    && report "### Caddy comment survived round-trip" PASS || report "### Caddy comment survived round-trip" FAIL
grep -q 'operator_custom_var' "$WORK/test3.yml" \
    && report "operator_custom_var survived round-trip" PASS || report "operator_custom_var survived round-trip" FAIL

echo
echo "Test 4: add merges into empty starter file"
echo "" > "$WORK/test4.yml"
python3 "$MERGE" --inventory "$WORK/test4.yml" --vault-password-file "$WORK/vault.pw" --update "$WORK/update_nextcloud.json" --mode add
grep -q "^  - nextcloud$" "$WORK/test4.yml" \
    && report "creates deploy_services list" PASS || report "creates deploy_services list" FAIL
grep -q "^  nextcloud:" "$WORK/test4.yml" \
    && report "creates my_linux_users dict" PASS || report "creates my_linux_users dict" FAIL

echo
echo "=========================================="
echo "  $PASS passed, $FAIL failed"
echo "=========================================="
[[ $FAIL -eq 0 ]]
