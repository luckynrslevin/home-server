#!/bin/bash
# ============================================================================
# scripts/test_e2e.sh — E2E regression test for the home-server project.
#
# Runs on homeserver2 (the test host). Drives a full lifecycle:
#
#   uninstall → install platform (caddy + dashboard) → add nextcloud
#   → upload fixtures via WebDAV → add backup → trigger backup → assert
#   the fixtures are present inside the NAS tarball
#
# Designed to be cheap to repeat. The verify steps inside each role
# (tasks/verify.yml — see PR #294) do the per-service health checks;
# this driver is the orchestrator that wires uninstall + install +
# data-load + backup verification.
#
# ----------------------------------------------------------------------------
# ONE-TIME OPERATOR SETUP (see docs/Testing.md for full how-to)
# ----------------------------------------------------------------------------
#
#   1. Create ~/home-server-test-overlay/ on homeserver2 with the same
#      shape as ~/home-server-private/ but with a curated inventory
#      (platform_services: [caddy, dashboard], apps: []).
#   2. Make sure ~/home-server-private/ has no uncommitted changes (the
#      runner refuses to start otherwise — protects operator state).
#   3. Disable the prod backup timer for the duration of the run
#      (the runner does this automatically and re-enables on exit).
#
# ----------------------------------------------------------------------------
# RUNNING
# ----------------------------------------------------------------------------
#
#   On homeserver2:
#     ./scripts/test_e2e.sh             # interactive — gates with a prompt
#     ./scripts/test_e2e.sh -y          # non-interactive (for cron)
#
#   From the laptop:
#     ssh homeserver2 'cd ~/home-server && ./scripts/test_e2e.sh -y'
#
# Total wall time: 30-40 min. Exit code 0 = green; non-zero = the phase
# that failed is named in the last log line + via the EXIT trap summary.
# ============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Config — overrides via env vars
# -----------------------------------------------------------------------------
TEST_HOSTNAME=${TEST_HOSTNAME:-homeserver2}
PROD_OVERLAY=${PROD_OVERLAY:-$HOME/home-server-private}
TEST_OVERLAY=${TEST_OVERLAY:-$HOME/home-server-test-overlay}
PROD_OVERLAY_PARK=${PROD_OVERLAY_PARK:-$HOME/home-server-private.parked-by-e2e}
REPO_URL=${REPO_URL:-https://github.com/luckynrslevin/home-server.git}
REPO_DIR=${REPO_DIR:-$HOME/home-server}
STAGING_DIR=${STAGING_DIR:-/tmp/home-server-e2e-staging-$$}
BACKUP_WAIT_TIMEOUT=${BACKUP_WAIT_TIMEOUT:-1800}   # 30 min ceiling for a single backup run

# CLI
YES_FLAG=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) YES_FLAG=true ;;
        -h|--help)
            sed -n '/^# ====/,/^# ====/p' "$0" | sed 's/^# //;s/^#$//'
            exit 0
            ;;
        *) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
    esac
    shift
done

# -----------------------------------------------------------------------------
# Colors (TTY-aware, mirrors homeserver.sh PR #291)
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
else
    R=''; G=''; Y=''; C=''; B=''; N=''
fi
log()    { printf '%s[%s] %s%s\n' "${C}" "$(date +%H:%M:%S)" "$*" "${N}"; }
phase()  { printf '\n%s=== %s ===%s\n' "${B}" "$*" "${N}"; }
ok()     { printf '%s  ✓ %s%s\n' "${G}" "$*" "${N}"; }
fail()   { printf '%s  ✗ %s%s\n' "${R}" "$*" "${N}"; }
warn()   { printf '%s  ! %s%s\n' "${Y}" "$*" "${N}"; }

# -----------------------------------------------------------------------------
# Phase tracking + cleanup trap
# -----------------------------------------------------------------------------
CURRENT_PHASE=""
CLEANUP_ACTIONS=()
register_cleanup() { CLEANUP_ACTIONS+=("$1"); }

on_exit() {
    local rc=$?
    echo
    if [[ $rc -ne 0 ]]; then
        fail "Failed in phase: ${CURRENT_PHASE:-(setup)} (exit $rc)"
    fi
    if [[ ${#CLEANUP_ACTIONS[@]} -gt 0 ]]; then
        phase "Cleanup (always runs)"
        # Run cleanup actions in reverse order (LIFO — match setup order).
        for ((i=${#CLEANUP_ACTIONS[@]}-1; i>=0; i--)); do
            log "${CLEANUP_ACTIONS[$i]}"
            eval "${CLEANUP_ACTIONS[$i]}" || warn "cleanup action returned non-zero: ${CLEANUP_ACTIONS[$i]}"
        done
    fi
    exit $rc
}
trap on_exit EXIT

# =============================================================================
# PHASE 0: pre-flight
# =============================================================================
CURRENT_PHASE="0/pre-flight"
phase "Phase 0: pre-flight checks"

# Hostname guard — refuses to run anywhere except the configured test host.
# Protects against accidental invocation on a production homeserver.
if [[ "$(hostname -s)" != "$TEST_HOSTNAME" ]]; then
    fail "Refusing to run: \$(hostname -s)=$(hostname -s), expected $TEST_HOSTNAME"
    fail "Override with: TEST_HOSTNAME=$(hostname -s) ./scripts/test_e2e.sh"
    exit 1
fi
ok "Hostname is $TEST_HOSTNAME"

[[ -d "$TEST_OVERLAY" ]] || { fail "Test overlay missing: $TEST_OVERLAY (see docs/Testing.md)"; exit 1; }
ok "Test overlay present: $TEST_OVERLAY"

if [[ -d "$PROD_OVERLAY" ]]; then
    if ! (cd "$PROD_OVERLAY" && git diff --quiet && git diff --cached --quiet); then
        fail "Prod overlay has uncommitted changes — won't risk losing them."
        fail "Commit + push, or stash them, then re-run."
        exit 1
    fi
    ok "Prod overlay working tree clean"
fi

if [[ -d "$PROD_OVERLAY_PARK" ]]; then
    fail "Found leftover $PROD_OVERLAY_PARK from a previous failed run."
    fail "Inspect + restore manually, then remove the park dir:"
    fail "  mv $PROD_OVERLAY_PARK $PROD_OVERLAY"
    exit 1
fi

# Refuse if a backup is mid-flight — the swap would tear its NFS mount.
if systemctl is-active --quiet home-server-backup.service 2>/dev/null; then
    fail "home-server-backup.service is currently running. Wait or kill it before retrying."
    exit 1
fi
ok "No backup currently running"

if [[ "$YES_FLAG" != "true" ]]; then
    echo
    warn "About to FULLY WIPE $TEST_HOSTNAME and rebuild from scratch."
    warn "Estimated wall time: 30-40 min."
    read -r -p "Type YES to continue, anything else aborts: " confirm
    [[ "$confirm" == "YES" ]] || { warn "Aborted by operator."; exit 1; }
fi

# =============================================================================
# PHASE 1: stage helpers + fixtures outside ~/home-server (uninstall wipes that)
# =============================================================================
CURRENT_PHASE="1/staging"
phase "Phase 1: stage helpers + fixtures to $STAGING_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -a "$REPO_DIR/scripts/test_e2e/." "$STAGING_DIR/test_e2e/"
cp -a "$REPO_DIR/tests/fixtures/." "$STAGING_DIR/fixtures/"
helpers_n=$(find "$STAGING_DIR/test_e2e" -maxdepth 1 -type f | wc -l)
fixtures_n=$(find "$STAGING_DIR/fixtures" -maxdepth 1 -type f | wc -l)
ok "Staged $helpers_n helper(s), $fixtures_n fixture(s)"

register_cleanup "rm -rf '$STAGING_DIR'"

# =============================================================================
# PHASE 2: swap prod overlay aside, expose test overlay at the canonical path
# =============================================================================
CURRENT_PHASE="2/overlay-swap"
phase "Phase 2: park prod overlay; expose test overlay as $PROD_OVERLAY"

# The test overlay must live where homeserver.sh expects an overlay (so
# ensure_overlay_symlink_intact + install's overlay logic both Just Work
# against the test inventory). We rename the prod overlay aside for the
# duration of the test and rename the test overlay into place.
if [[ -d "$PROD_OVERLAY" ]]; then
    mv "$PROD_OVERLAY" "$PROD_OVERLAY_PARK"
    ok "Parked prod overlay → $PROD_OVERLAY_PARK"
fi
mv "$TEST_OVERLAY" "$PROD_OVERLAY"
ok "Test overlay is now at $PROD_OVERLAY"

# Reverse swap on exit, regardless of test outcome. Park dir was already
# moved aside, so this is symmetric.
register_cleanup "[[ -d '$PROD_OVERLAY' ]] && mv '$PROD_OVERLAY' '$TEST_OVERLAY' || true"
register_cleanup "[[ -d '$PROD_OVERLAY_PARK' ]] && mv '$PROD_OVERLAY_PARK' '$PROD_OVERLAY' || true"

# =============================================================================
# PHASE 3: uninstall (wipes ~/home-server + ~/.vaultpw + all service users etc)
# =============================================================================
CURRENT_PHASE="3/uninstall"
phase "Phase 3: ./homeserver.sh uninstall"

if [[ -d "$REPO_DIR" ]]; then
    bash "$REPO_DIR/scripts/clean-host.sh" 2>&1 | tail -20 || warn "clean-host returned non-zero (continuing)"
fi
ok "Uninstall complete"

# =============================================================================
# PHASE 4: fresh re-clone (uninstall removed $REPO_DIR)
# =============================================================================
CURRENT_PHASE="4/reclone"
phase "Phase 4: clone $REPO_URL → $REPO_DIR"

git clone --quiet "$REPO_URL" "$REPO_DIR"
ok "Cloned $(cd "$REPO_DIR" && git log -1 --format='%h %s' main)"

# =============================================================================
# PHASE 5: install platform (caddy + dashboard only, per test overlay)
# =============================================================================
CURRENT_PHASE="5/install"
phase "Phase 5: ./homeserver.sh install -y -h $TEST_HOSTNAME"

# Test overlay has platform_services=[caddy,dashboard], apps=[], so -y
# install rebuilds the base platform only. caddy_acme_token + smtp_*
# come from the test overlay's vaulted inventory.
cd "$REPO_DIR"
./homeserver.sh install -y -h "$TEST_HOSTNAME" 2>&1 | tail -30
ok "Platform installed"

# =============================================================================
# PHASE 6: probe caddy + dashboard
# =============================================================================
CURRENT_PHASE="6/caddy-probe"
phase "Phase 6: assert caddy + dashboard reachable"

CADDY_DOMAIN=$(./homeserver.sh secret caddy_domain 2>/dev/null || true)
if [[ -z "$CADDY_DOMAIN" ]]; then
    # Not stored as a secret — read directly from inventory.
    CADDY_DOMAIN=$(python3 -c "
import yaml
with open('$PROD_OVERLAY/inventory/host_vars/$TEST_HOSTNAME/10-caddy.yml') as f:
    print(yaml.safe_load(f).get('caddy_domain', '').strip('\"'))")
fi
[[ -n "$CADDY_DOMAIN" ]] || { fail "Could not resolve caddy_domain"; exit 1; }
log "caddy_domain: $CADDY_DOMAIN"

# Dashboard subdomain doesn't exist for an apps=[] install — caddy still
# serves /dashboard on the apex. Probe both 200 and accept 200/302/204.
status=$(curl -sk -o /dev/null -w "%{http_code}" "https://$CADDY_DOMAIN/" || true)
if [[ "$status" =~ ^(200|301|302)$ ]]; then
    ok "Caddy serves apex: HTTP $status"
else
    fail "Caddy apex returned HTTP $status"
    exit 1
fi

# =============================================================================
# PHASE 7: add nextcloud (role's tasks/verify.yml runs inside the playbook)
# =============================================================================
CURRENT_PHASE="7/add-nextcloud"
phase "Phase 7: ./homeserver.sh add nextcloud -y"

./homeserver.sh add nextcloud -y 2>&1 | tail -30
ok "nextcloud added (role verify passed inline)"

# =============================================================================
# PHASE 8: upload fixture files via WebDAV
# =============================================================================
CURRENT_PHASE="8/upload-fixtures"
phase "Phase 8: upload fixtures into Nextcloud"

NEXTCLOUD_ADMIN_PASSWORD=$(./homeserver.sh secret nextcloud_admin_password 2>/dev/null | tail -1)
export NEXTCLOUD_ADMIN_PASSWORD
NEXTCLOUD_URL="https://cloud.$CADDY_DOMAIN"
python3 "$STAGING_DIR/test_e2e/upload_nextcloud_files.py" \
    --url "$NEXTCLOUD_URL" \
    --user ncadmin \
    --password-from-env NEXTCLOUD_ADMIN_PASSWORD \
    --fixtures-dir "$STAGING_DIR/fixtures" \
    || { fail "Upload failed"; exit 1; }
unset NEXTCLOUD_ADMIN_PASSWORD
ok "All fixtures uploaded"

# =============================================================================
# PHASE 9: add backup
# =============================================================================
CURRENT_PHASE="9/add-backup"
phase "Phase 9: ./homeserver.sh add backup -y"

# Test overlay should carry backup_nas_ip already; if not, the install
# walker prompts. -y mode requires it to be in inventory.
./homeserver.sh add backup -y 2>&1 | tail -30
ok "backup added (role verify passed inline, snapshot-trigger probe was off)"

# =============================================================================
# PHASE 10: trigger backup now (don't wait until 02:00) and wait for completion
# =============================================================================
CURRENT_PHASE="10/run-backup"
phase "Phase 10: trigger nightly backup immediately, wait for finish"

sudo systemctl start home-server-backup.service
log "backup service started; polling for completion (timeout ${BACKUP_WAIT_TIMEOUT}s)"
elapsed=0
while sudo systemctl is-active --quiet home-server-backup.service; do
    sleep 15
    elapsed=$((elapsed + 15))
    if (( elapsed >= BACKUP_WAIT_TIMEOUT )); then
        fail "Backup did not finish within ${BACKUP_WAIT_TIMEOUT}s"
        sudo journalctl -u home-server-backup.service --no-pager -n 20
        exit 1
    fi
    log "still running… (${elapsed}s)"
done
ok "Backup service finished after ${elapsed}s"

# =============================================================================
# PHASE 11: assert log shows clean run
# =============================================================================
CURRENT_PHASE="11/log-check"
phase "Phase 11: assert backup log shows 0 errors"

if sudo tail -50 /var/log/home-server-backup.log | grep -q "=== Backup finished (0 errors) ==="; then
    ok "Log shows 0 errors"
else
    fail "Last backup did not finish cleanly. Log tail:"
    sudo tail -30 /var/log/home-server-backup.log
    exit 1
fi

# =============================================================================
# PHASE 12: verify fixture files made it into the NAS tarball
# =============================================================================
CURRENT_PHASE="12/backup-contents"
phase "Phase 12: assert fixtures landed in NAS tarball"

# Read NAS coords from inventory.
NAS_HOST=$(python3 -c "
import yaml
with open('$PROD_OVERLAY/inventory/host_vars/$TEST_HOSTNAME/50-backup.yml') as f:
    print(yaml.safe_load(f)['backup_nas_hostname'])")
NAS_VOLUME=$(python3 -c "
import yaml
with open('$PROD_OVERLAY/inventory/host_vars/$TEST_HOSTNAME/50-backup.yml') as f:
    print(yaml.safe_load(f)['backup_nas_volume'])")
log "Mounting $NAS_HOST:$NAS_VOLUME/backup-$TEST_HOSTNAME"

FIXTURE_NAMES=()
for f in "$STAGING_DIR/fixtures"/payload-*.txt; do
    FIXTURE_NAMES+=("$(basename "$f")")
done

python3 "$STAGING_DIR/test_e2e/verify_backup_contents.py" \
    --mount-and-check \
    --nas-host "$NAS_HOST" \
    --nas-volume "$NAS_VOLUME" \
    --share-name "backup-$TEST_HOSTNAME" \
    --role nextcloud \
    --volume nextcloud-data \
    --expect "${FIXTURE_NAMES[@]}" \
    || { fail "Tarball did not contain every fixture"; exit 1; }
ok "All ${#FIXTURE_NAMES[@]} fixture(s) present in backup tarball"

# =============================================================================
# All phases passed
# =============================================================================
CURRENT_PHASE="(done)"
phase "E2E PASSED"
log "All 12 phases green. Total wall time: $SECONDS s"
