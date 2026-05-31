#!/bin/bash
# ============================================================================
# Home Server — Interactive Setup Script
#
# Run on a freshly installed RHEL-family host (AlmaLinux 9+, Rocky 9+,
# Fedora Server). Invoke as your non-root sudo user, NOT as root:
#   curl -fsSL https://raw.githubusercontent.com/luckynrslevin/home-server/main/homeserver.sh \
#     -o /tmp/homeserver.sh && bash /tmp/homeserver.sh
#
# This script:
#   1. Installs Ansible and dependencies
#   2. Clones the home-server repo
#   3. Installs the Galaxy role dependency
#   4. Walks you through configuring your server
#   5. Generates inventory, host_vars, vault secrets, and dashboard config
#   6. Lets you choose which services to deploy
#   7. Runs the selected playbooks against localhost
# ============================================================================
set -euo pipefail

# --- Subcommand dispatch ---
# homeserver.sh is a multi-verb CLI. No-arg invocation defaults to
# `install` to preserve the Quickstart `curl | bash homeserver.sh` UX.
#
# Three dispatch paths, in priority order:
#   1. First arg matches a built-in verb  → set VERB=<that verb>
#   2. First arg matches a role with a roles/<name>/scripts/ dir on the
#      script's own filesystem → set VERB=service, SERVICE=<that name>,
#      remaining args are the helper action + args. Wired up at the
#      bottom of the file under "--- Service-helper dispatch ---".
#   3. Otherwise → default VERB=install (or treat the first arg as a
#      flag for install).
VERB="install"
SERVICE=""
_self_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# Resolve a role directory across the platform/apps split.
# Usage: resolve_role_path <base_dir> <service>. Prints the path on
# success (returns 0); returns 1 if no matching role directory exists.
resolve_role_path() {
    local base=$1 svc=$2 p
    for p in "$base/roles/platform/$svc" "$base/roles/apps/$svc"; do
        [[ -d "$p" ]] && { printf '%s' "$p"; return 0; }
    done
    return 1
}

# Same, but resolves to the meta/install.yml file inside the role.
resolve_meta_install() {
    local base=$1 svc=$2 rp
    rp=$(resolve_role_path "$base" "$svc") || return 1
    [[ -f "$rp/meta/install.yml" ]] && { printf '%s' "$rp/meta/install.yml"; return 0; }
    return 1
}

# --- Split-layout helpers ---
# host_vars/<host>/ contains 00-services.yml … 60-tailscale.yml plus
# apps/<svc>.yml — one file per topic, no monolithic main.yml.

# Source of truth for platform-vs-app classification. Add/remove verbs
# and the install flow both need this, so it lives at the top.
PLATFORM_SERVICES_CANON=(caddy dashboard pihole backup os-tailscale)
is_platform_service() {
    local needle=$1 p
    for p in "${PLATFORM_SERVICES_CANON[@]}"; do
        [[ "$p" == "$needle" ]] && return 0
    done
    return 1
}

# True if <dir> contains at least one *.yml file (top-level or under
# apps/). Used to decide whether a host has an existing inventory.
host_vars_dir_has_content() {
    local dir=$1
    [[ -d "$dir" ]] || return 1
    compgen -G "$dir"/*.yml >/dev/null 2>&1 && return 0
    compgen -G "$dir"/apps/*.yml >/dev/null 2>&1 && return 0
    return 1
}

# Print path to the first *.yml file under <dir> containing a
# $ANSIBLE_VAULT block. Used by the install flow to verify the
# supplied vault password decrypts the existing inventory.
find_vault_yml() {
    local dir=$1 f
    [[ -d "$dir" ]] || return 1
    while IFS= read -r -d '' f; do
        if grep -q '\$ANSIBLE_VAULT' "$f" 2>/dev/null; then
            printf '%s' "$f"
            return 0
        fi
    done < <(find "$dir" -maxdepth 2 -type f -name '*.yml' -print0 2>/dev/null)
    return 1
}

if [[ "${1:-}" =~ ^(install|add|remove|config|upgrade|backup|restore|uninstall|secret)$ ]]; then
    VERB="$1"
    shift
elif [[ -n "${1:-}" ]] && _svc_path=$(resolve_role_path "$_self_dir" "$1") && [[ -d "$_svc_path/scripts" ]]; then
    VERB="service"
    SERVICE="$1"
    shift
fi

# (Dispatch on $VERB happens later — after CLI flags, sanity checks
# and helper definitions are loaded. Verb-specific behaviour lives
# at the bottom of this file under "--- Verb dispatch ---".)

# --- CLI flags ---
# Optional non-interactive overrides for `install`. Any flag omitted
# falls back to the interactive prompt later in the script. With
# -y / --yes the script skips every prompt and uses inventory values
# (rebuild) or generated defaults (fresh install) — fails fast on a
# missing required value.
OVERLAY_URL_FLAG=""
HOSTNAME_FLAG=""
VAULT_PW_FLAG_FILE=""
RELEASE_FLAG=""
YES_FLAG=false

# Per-service helpers handle their own argument parsing. The global
# --yes/--help translation + getopts loop below is for top-level
# verbs only and would otherwise consume the helper's own flags.
if [[ "$VERB" != "service" ]]; then

# --yes is a long form for -y. getopts only handles short flags, so
# pre-process argv to translate.
NORMALIZED_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --yes) NORMALIZED_ARGS+=("-y") ;;
        --help|-\?) NORMALIZED_ARGS+=("-H") ;;
        *) NORMALIZED_ARGS+=("$arg") ;;
    esac
done
set -- "${NORMALIZED_ARGS[@]:-}"

while getopts ":i:h:v:r:yH" opt; do
    case $opt in
        i) OVERLAY_URL_FLAG="$OPTARG" ;;
        h) HOSTNAME_FLAG="$OPTARG" ;;
        v) VAULT_PW_FLAG_FILE="$OPTARG" ;;
        r) RELEASE_FLAG="$OPTARG" ;;
        y) YES_FLAG=true ;;
        H)
            cat <<'USAGE'
Usage: homeserver.sh [VERB] [flags]
       homeserver.sh <service> [<action>] [args...]

Verbs:
  install         First install or interactive re-install (default).
  add <svc>       Add a service that wasn't deployed before.
  remove <svc>    Remove a service. Data volumes preserved unless --purge.
  config <section>
                  Edit one host_vars section in $EDITOR (default vi)
                  + apply via the matching playbook. No full re-install.
                  Sections: caddy, smtp, pihole, backup, tailscale, extras.
                  Run `homeserver.sh config` (no section) to list.
  upgrade         Pull newer images + bump release tag within current major.
  backup          Trigger the backup systemd service now.
  restore         Restore from latest NAS backup.
  uninstall       Full wipe (= scripts/clean-host.sh).
  secret <key> [HOST]
                  Decrypt and print an inventory secret to stdout.
                  HOST defaults to this machine's hostname.

Service helpers:
  Each role under roles/<svc>/scripts/ may ship operator helpers.
  Run `homeserver.sh <svc>` (no action) to list a service's helpers.
  Example: `homeserver.sh entephoto-export export-now`

Flags (for install):
  -i <url>     Private overlay repo URL (otherwise prompted).
  -h <name>    Server hostname (otherwise defaults to `hostname -s`).
  -v <file>    Path to a file containing the overlay vault password
               (otherwise prompted).
  -r <tag>     Release tag to install (e.g. v2.1.0). On rebuild,
               defaults to the tag recorded in inventory. On fresh
               install, defaults to the latest stable `v*` tag.
  -y, --yes    Accept all defaults; skip every prompt. Fails fast if
               any required value is missing.
  --help       This help.

Examples:
  bash homeserver.sh                              # interactive first install
  bash homeserver.sh -i git@github.com:you/overlay.git
                                                  # first install with overlay URL
  bash homeserver.sh -y                           # rebuild non-interactive
  bash homeserver.sh add jellyfin                 # deploy a new service
  bash homeserver.sh entephoto-export export-now  # run a service helper
USAGE
            exit 0
            ;;
        \?) echo "ERROR: unknown flag: -$OPTARG" >&2; exit 1 ;;
        :)  echo "ERROR: flag -$OPTARG requires a value" >&2; exit 1 ;;
    esac
done

fi  # end: top-level flag parsing skipped for VERB=service

# --- Require file execution (not pipe) — install verb only ---
# The install flow has interactive prompts and needs terminal stdin.
# When piped via `curl ... | bash`, stdin is consumed by the stream.
# Detect this and download + run from a file instead.
# Non-install verbs (backup, restore, upgrade, uninstall, add, remove)
# are non-interactive and don't need a tty.
if [[ "$VERB" == "install" && "$YES_FLAG" != "true" && ! -t 0 ]]; then
    SELF_PATH="/tmp/home-server-homeserver.sh"
    curl -fsSL "https://raw.githubusercontent.com/luckynrslevin/home-server/main/homeserver.sh" \
        -o "$SELF_PATH" 2>/dev/null
    chmod +x "$SELF_PATH"
    echo
    echo "This script is interactive and cannot run via pipe."
    echo "It has been downloaded to: $SELF_PATH"
    echo
    echo "Run it with:"
    echo "  bash $SELF_PATH"
    echo
    exit 0
fi

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}==>${NC} $*"; }
ok()    { echo -e "${GREEN}==>${NC} $*"; }
warn()  { echo -e "${YELLOW}==> WARNING:${NC} $*"; }
err()   { echo -e "${RED}==> ERROR:${NC} $*" >&2; }
ask()   { echo -en "${BOLD}$*${NC} "; }

# --- Inventory-as-source-of-truth helpers ---
# EXISTING_VARS_JSON holds the decrypted host_vars dict from a
# previous homeserver.sh run. Populated by load_existing_inventory() after
# the overlay (if any) is cloned + vault.pw symlinked. Empty until
# then; empty for fresh installs.
EXISTING_VARS_JSON='{}'

# inv_get <key> — print the inventory value for <key>, or empty.
# Scalars come back verbatim. Dicts/lists come back as JSON so callers
# can re-parse.
inv_get() {
    EXISTING_VARS_JSON="$EXISTING_VARS_JSON" KEY="$1" VAULT_PW="${VAULT_PW_FILE:-}" python3 - <<'PY' 2>/dev/null || true
import json, os, sys, subprocess
try:
    d = json.loads(os.environ["EXISTING_VARS_JSON"])
except Exception:
    sys.exit(0)
v = d.get(os.environ["KEY"])
if v is None:
    sys.exit(0)
# ansible-inventory --host does NOT auto-decrypt inline `!vault | ...`
# blocks — it returns them as {"__ansible_vault": "$ANSIBLE_VAULT;..."}.
# Decrypt transparently here so callers always see the plaintext value.
# (ansible-vault decrypt doesn't read from stdin reliably; use a temp file.)
if isinstance(v, dict) and "__ansible_vault" in v:
    import tempfile
    pw = os.environ.get("VAULT_PW", "")
    if not pw:
        sys.exit(0)
    tmp = tempfile.NamedTemporaryFile("w", delete=False)
    try:
        tmp.write(v["__ansible_vault"])
        tmp.close()
        r = subprocess.run(
            ["ansible-vault", "decrypt", "--vault-password-file", pw, "--output", "-", tmp.name],
            capture_output=True, text=True, check=True,
        )
        sys.stdout.write(r.stdout)
    except Exception:
        sys.exit(0)
    finally:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass
elif isinstance(v, (dict, list)):
    print(json.dumps(v))
else:
    print(v)
PY
}

# prompt_default <var_name> <question> <hardcoded_fallback>
# Picks a default in priority order: inventory > fallback. With -y,
# uses default silently and errors if none. Interactive otherwise.
prompt_default() {
    local var=$1 question=$2 fallback=$3
    local existing default answer
    existing=$(inv_get "$var")
    default=${existing:-$fallback}
    if [[ "$YES_FLAG" == "true" ]]; then
        if [[ -z "$default" ]]; then
            err "Required value '$var' missing from inventory (and no fallback). -y requires a fully-populated inventory."
            exit 1
        fi
        printf -v "$var" '%s' "$default"
        return
    fi
    if [[ -n "$default" ]]; then
        ask "$question [$default]:"
    else
        ask "$question:"
    fi
    read -r answer
    printf -v "$var" '%s' "${answer:-$default}"
}

# prompt_default_hidden <var_name> <question>
# Hidden-input version. Default is the existing inventory value (kept
# hidden); empty input keeps the existing value.
prompt_default_hidden() {
    local var=$1 question=$2
    local existing answer
    existing=$(inv_get "$var")
    if [[ "$YES_FLAG" == "true" ]]; then
        if [[ -z "$existing" ]]; then
            err "Required secret '$var' missing from inventory. -y requires a fully-populated inventory."
            exit 1
        fi
        printf -v "$var" '%s' "$existing"
        return
    fi
    if [[ -n "$existing" ]]; then
        ask "$question [keep existing — type to override]:"
    else
        ask "$question:"
    fi
    read -rs answer
    echo
    printf -v "$var" '%s' "${answer:-$existing}"
}

# gen_or_inherit <var_name> <openssl args...>
# If <var_name> is set in inventory, reuse the decrypted value;
# otherwise generate via openssl. Used for service secrets so a
# rebuild doesn't rotate every password.
gen_or_inherit() {
    local var=$1; shift
    local existing
    existing=$(inv_get "$var")
    if [[ -n "$existing" ]]; then
        printf -v "$var" '%s' "$existing"
    else
        printf -v "$var" '%s' "$(openssl "$@")"
    fi
}

# --- Sanity checks ---
if [[ $EUID -eq 0 ]]; then
    err "Do not run this script as root. Run as your normal user (with sudo access)."
    exit 1
fi

# Distro family detection — accept anything in the RHEL family
# (rhel/centos/fedora as ID or anywhere in ID_LIKE). Same case
# statement scripts/bootstrap-host.sh uses, for consistency.
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    err "/etc/os-release missing — can't identify distro."
    exit 1
fi
case " ${ID:-} ${ID_LIKE:-} " in
    *" rhel "*|*" centos "*|*" fedora "*|*" almalinux "*|*" rocky "*) ;;
    *)
        err "This script supports the RHEL family (Fedora / AlmaLinux / Rocky)."
        err "  Detected: ID=${ID:-?} ID_LIKE=${ID_LIKE:-?}"
        exit 1
        ;;
esac

# Passwordless sudo is required — every install/config step shells out
# via `sudo dnf …` etc., and the script is non-interactive past the
# config-collection phase.
if ! sudo -n true 2>/dev/null; then
    err "This user needs passwordless sudo (NOPASSWD:ALL) to run homeserver.sh."
    err "See docs/Install-Manual.md → Step 3 for how to configure it."
    exit 1
fi

# ============================================================================
# Verb dispatch (Phase 3 — non-install verbs exit here)
# ============================================================================
# `install` falls through to the full flow below. Other verbs are
# self-contained: ensure prereqs (ansible already installed from a
# prior `install`), then run the appropriate playbook/script.
INSTALL_DIR="$HOME/home-server"

ensure_ansible_on_path() {
    if ! command -v ansible-playbook &>/dev/null; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    if ! command -v ansible-playbook &>/dev/null; then
        err "ansible-playbook not on PATH. Run \`homeserver.sh install\` first."
        exit 1
    fi
}

ensure_install_dir() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        err "$INSTALL_DIR not found. Run \`homeserver.sh install\` first."
        exit 1
    fi
}

# Make sure $INSTALL_DIR/ansible.cfg exists and points at a real vault
# password file. Used by `add` / `remove` / `upgrade` so a clobbered
# ansible.cfg (e.g. after a git pull on a host where the install-time
# rewrite was previously tracked) self-heals without forcing a full
# `install` re-run. Idempotent and safe to call on every verb entry.
ensure_ansible_cfg() {
    local cfg="$INSTALL_DIR/ansible.cfg"
    local example="$INSTALL_DIR/ansible.cfg.example"
    local target_vault="${VAULT_PW_FILE:-$HOME/.vaultpw}"
    if [[ -f "$cfg" ]]; then
        # Already pointing at a usable vault file? Nothing to do.
        local current
        current=$(awk -F'= *' '/^vault_password_file/ {print $2; exit}' "$cfg")
        if [[ -n "$current" && -r "$current" ]]; then
            return 0
        fi
        # cfg is present but points somewhere broken — rewrite below.
    fi
    if [[ ! -f "$example" ]]; then
        # Pre-PR-269 checkout without the example template; bail.
        return 0
    fi
    sed "s|^vault_password_file = .*|vault_password_file = $target_vault|" \
        "$example" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
    info "Regenerated $cfg (vault_password_file → $target_vault)"
}

resolve_target_host() {
    # Use -h flag if given; otherwise system hostname.
    printf '%s' "${HOSTNAME_FLAG:-$(hostname -s)}"
}

case "$VERB" in
    service)
        # homeserver.sh <service> [<action>] [args...]  →  per-service helper
        # SERVICE was set during dispatch at the top of the file.
        scripts_dir="$(resolve_role_path "$_self_dir" "$SERVICE")/scripts"
        ACTION="${1:-}"
        if [[ -z "$ACTION" ]]; then
            # No action: list available helpers for this service.
            echo "Helpers for $SERVICE:"
            shopt -s nullglob
            found=0
            for f in "$scripts_dir"/*; do
                [[ -f "$f" && -x "$f" ]] || continue
                name=$(basename "$f")
                # Hide leading-underscore helpers — convention for internal
                # implementations (e.g. _foo.py shipped to the target by a
                # public wrapper `foo`).
                [[ "$name" == _* ]] && continue
                # Strip a single trailing extension (.sh / .py / etc.)
                # so dispatch matches what's printed.
                display="${name%.*}"
                # Pull the one-liner from the second line if it's a `# ...` comment.
                desc=$(sed -n '2{s/^#[[:space:]]*//;p;}' "$f")
                printf "  %-22s %s\n" "$display" "$desc"
                found=$((found+1))
            done
            shopt -u nullglob
            if [[ $found -eq 0 ]]; then
                echo "  (none)"
                echo
                echo "To add one, drop an executable file at:"
                echo "  $scripts_dir/<action>"
            fi
            exit 0
        fi
        shift
        # Find the helper file. Allow either `<action>` or `<action>.<ext>`.
        helper=""
        if [[ -f "$scripts_dir/$ACTION" && -x "$scripts_dir/$ACTION" ]]; then
            helper="$scripts_dir/$ACTION"
        else
            shopt -s nullglob
            for f in "$scripts_dir/$ACTION".*; do
                if [[ -f "$f" && -x "$f" ]]; then
                    helper="$f"
                    break
                fi
            done
            shopt -u nullglob
        fi
        if [[ -z "$helper" ]]; then
            err "Unknown action '$ACTION' for service '$SERVICE'."
            err "Run \`homeserver.sh $SERVICE\` to list available helpers."
            exit 2
        fi
        # If the helper has a requirements.txt next to it, ensure deps
        # are installed in the user's pip env (cached after first run).
        reqs="$scripts_dir/requirements.txt"
        if [[ -f "$reqs" ]]; then
            stamp="$HOME/.cache/home-server/helpers/${SERVICE}.deps"
            if [[ ! -f "$stamp" ]] || [[ "$reqs" -nt "$stamp" ]]; then
                info "Installing helper dependencies for $SERVICE (one-time)..."
                mkdir -p "$(dirname "$stamp")"
                if pip install --user --quiet -r "$reqs"; then
                    touch "$stamp"
                else
                    warn "pip install failed; helper may not run. See $reqs."
                fi
            fi
        fi
        # Export common environment so helpers don't reimplement plumbing.
        export HOMESERVER_REPO_DIR="$_self_dir"
        export HOMESERVER_VAULT_PW_FILE="$HOME/.vaultpw"
        exec "$helper" "$@"
        ;;
    install)
        ;;  # Falls through to Step 1 below.
    backup)
        # The backup is a standalone systemd service deployed by the
        # backup role during `install`. Trigger it via systemctl, not
        # by re-running playbooks/backup.yml (which would only
        # re-deploy the service unit + script, not run a backup).
        if ! systemctl list-unit-files home-server-backup.service &>/dev/null; then
            err "home-server-backup.service not installed. Run \`homeserver.sh install\` first."
            exit 1
        fi
        info "Triggering home-server-backup.service (waiting for completion)..."
        # --wait blocks until the unit finishes; exit code reflects success/failure.
        if sudo systemctl start --wait home-server-backup.service; then
            ok "Backup completed."
            sudo journalctl -u home-server-backup.service --since "10 minutes ago" --no-pager | tail -20
            exit 0
        else
            err "Backup failed. Check: journalctl -u home-server-backup.service"
            exit 1
        fi
        ;;
    restore)
        ensure_ansible_on_path
        ensure_install_dir
        TARGET=$(resolve_target_host)
        info "Restoring $TARGET from latest NAS backup..."
        cd "$INSTALL_DIR"
        exec ansible-playbook playbooks/restore.yml --limit "$TARGET"
        ;;
    upgrade)
        ensure_ansible_on_path
        ensure_install_dir
        TARGET=$(resolve_target_host)
        cd "$INSTALL_DIR"
        VAULT_PW_FILE="$HOME/.vaultpw"
        ensure_ansible_cfg
        # Resolve the "current" tag in priority order:
        #   1. inventory's home_server_release (the durable record)
        #   2. git describe --exact-match (whatever's checked out now)
        # Then bump to the latest tag within that major.
        # `major-upgrade` (across majors) deferred to its own later
        # workflow.
        current_tag=""
        if [[ -r "$VAULT_PW_FILE" ]]; then
            current_tag=$(ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PW_FILE" \
                ansible-inventory --host "$TARGET" 2>/dev/null \
                | python3 -c "import json,sys; print(json.load(sys.stdin).get('home_server_release','') or '')" 2>/dev/null || echo "")
        fi
        if [[ -z "$current_tag" ]]; then
            current_tag=$(git describe --tags --exact-match 2>/dev/null || echo "")
        fi
        if [[ "$current_tag" =~ ^v([0-9]+)\..* ]]; then
            major="${BASH_REMATCH[1]}"
            git fetch --tags --quiet || true
            latest_in_major=$(git tag --list "v${major}.*" --sort=-v:refname 2>/dev/null | head -1)
            if [[ -z "$latest_in_major" ]]; then
                warn "No v${major}.x tags found. Re-running ansible against current checkout."
            elif [[ "$latest_in_major" != "$current_tag" ]]; then
                info "Bumping release: $current_tag → $latest_in_major"
                git checkout --quiet "$latest_in_major"
                # Persist the new tag back to inventory so subsequent
                # operations agree with the on-disk state. home_server_release
                # lives in 00-services.yml (next to platform_services + apps).
                NEW_TAG="$latest_in_major"
                if [[ -r "$VAULT_PW_FILE" ]] && python3 -c "import ruamel.yaml" 2>/dev/null; then
                    REL_FILE="$INSTALL_DIR/inventory/host_vars/$TARGET/00-services.yml"
                    if [[ -f "$REL_FILE" ]]; then
                        info "Updating inventory's home_server_release → $NEW_TAG ($REL_FILE)"
                        python3 - "$REL_FILE" "$NEW_TAG" <<'PY' 2>/dev/null || warn "Could not auto-update inventory home_server_release; do it by hand."
import sys
from ruamel.yaml import YAML
inv_path, new_tag = sys.argv[1], sys.argv[2]
yaml = YAML(typ='rt'); yaml.indent(mapping=2, sequence=4, offset=2)
with open(inv_path) as f:
    data = yaml.load(f) or {}
data['home_server_release'] = new_tag
with open(inv_path, 'w') as f:
    yaml.dump(data, f)
PY
                    else
                        warn "Could not find a host_vars file to persist home_server_release; do it by hand."
                    fi
                fi
            else
                ok "Already on latest v${major}.x release ($current_tag) — refreshing images + ansible state."
                # Ensure checkout matches inventory even if no bump needed
                if [[ -n "$current_tag" ]] && ! git describe --tags --exact-match 2>/dev/null | grep -qx "$current_tag"; then
                    info "Checkout drift detected — checking out $current_tag"
                    git checkout --quiet "$current_tag" || true
                fi
            fi
        else
            warn "No release tag pinned (no home_server_release in inventory, no git tag at HEAD). Just re-running ansible against current checkout."
        fi
        info "Re-running ansible site.yml for $TARGET..."
        exec ansible-playbook playbooks/site.yml --limit "$TARGET"
        ;;
    uninstall)
        if [[ ! -f "$INSTALL_DIR/scripts/clean-host.sh" ]]; then
            err "$INSTALL_DIR/scripts/clean-host.sh not found. Cannot uninstall."
            exit 1
        fi
        info "Running clean-host (wipes containers, users, configs)..."
        exec bash "$INSTALL_DIR/scripts/clean-host.sh"
        ;;
    secret)
        # homeserver.sh secret <key> [HOST]  →  decrypt + print an inventory secret.
        # Useful for recovering an operator-supplied secret (e.g. an
        # account password) that's been vault-encrypted into inventory.
        # HOST defaults to this machine's short hostname (typical case:
        # the script runs on the target box itself).
        KEY="${1:-}"
        if [[ -z "$KEY" ]]; then
            err "Usage: homeserver.sh secret <inventory-key> [HOST]"
            err "Example: homeserver.sh secret entephoto_export_account_password"
            err "         homeserver.sh secret pihole_api_password homeserver2"
            exit 2
        fi
        shift
        # Optional positional HOST overrides resolve_target_host.
        HOSTNAME_FLAG="${1:-${HOSTNAME_FLAG:-}}"
        ensure_install_dir
        ensure_ansible_on_path
        cd "$INSTALL_DIR"
        VAULT_PW_FILE="$HOME/.vaultpw"
        if [[ ! -r "$VAULT_PW_FILE" ]]; then
            err "$VAULT_PW_FILE not readable. Run \`homeserver.sh install\` first."
            exit 1
        fi
        ensure_ansible_cfg
        TARGET=$(resolve_target_host)
        # inv_get reads $EXISTING_VARS_JSON, populate it from inventory first.
        EXISTING_VARS_JSON=$(ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PW_FILE" \
            ansible-inventory --host "$TARGET" 2>/dev/null) || EXISTING_VARS_JSON='{}'
        value=$(inv_get "$KEY")
        if [[ -z "$value" ]]; then
            err "Key '$KEY' not found in inventory for $TARGET (or empty)."
            exit 1
        fi
        # Plain stdout so the value pipes cleanly into other tools.
        printf '%s\n' "$value"
        exit 0
        ;;
    config)
        # homeserver.sh config <section> — targeted reconfig of one
        # host_vars split file + apply via the matching playbook.
        # Opens the file in $EDITOR (default vi); on save, runs the
        # playbook so the change takes effect without a full install.
        #
        # Vault-encrypted values (smtp_password, caddy_acme_token, etc.)
        # stay vault blocks across edits — the operator pastes a fresh
        # `ansible-vault encrypt_string '<value>' --name '<var>'` output
        # to rotate one. The hint banner printed below lists the
        # vault-encrypt commands.
        SECTION="${1:-}"
        if [[ -z "$SECTION" ]]; then
            cat <<USAGE >&2
Usage: homeserver.sh config <section>

Sections:
  caddy       caddy_domain, ACME provider + token, reverse-proxy services
              → file: 10-caddy.yml      → playbook: caddy.yml
  smtp        SMTP relay (host/port/user/from/encryption/password)
              → file: 30-smtp.yml       → playbook: site.yml
                (re-runs every role; SMTP is used by multiple apps)
  pihole      Pi-hole subnet, gateway, API password
              → file: 40-pihole.yml     → playbook: pihole.yml
  backup      NAS coords, backup time
              → file: 50-backup.yml     → playbook: backup.yml
  tailscale   Tailscale auth key
              → file: 60-tailscale.yml  → playbook: os-tailscale.yml
  extras      Operator overrides (Pi-hole DNS records, Jellyfin mounts,
              MA internal hosts, NAS snapshot trigger, custom Caddy entries)
              → file: 20-extras.yml     → playbook: site.yml

Each section maps to one split host_vars file (see
inventory/host_vars/<host>/) plus the playbook that reads from it.
USAGE
            exit 2
        fi
        case "$SECTION" in
            caddy)     FILE=10-caddy.yml      PLAYBOOK=caddy.yml ;;
            smtp)      FILE=30-smtp.yml       PLAYBOOK=site.yml ;;
            pihole)    FILE=40-pihole.yml     PLAYBOOK=pihole.yml ;;
            backup)    FILE=50-backup.yml     PLAYBOOK=backup.yml ;;
            tailscale) FILE=60-tailscale.yml  PLAYBOOK=os-tailscale.yml ;;
            extras|overrides) FILE=20-extras.yml PLAYBOOK=site.yml ;;
            *)
                err "Unknown section '$SECTION'. Run \`homeserver.sh config\` for the list."
                exit 2
                ;;
        esac
        ensure_install_dir
        ensure_ansible_on_path
        VAULT_PW_FILE="$HOME/.vaultpw"
        if [[ ! -r "$VAULT_PW_FILE" ]]; then
            err "$VAULT_PW_FILE not readable. Run \`homeserver.sh install\` first."
            exit 1
        fi
        ensure_ansible_cfg
        TARGET=$(resolve_target_host)
        cd "$INSTALL_DIR"
        FULL_PATH="inventory/host_vars/$TARGET/$FILE"
        # Optional section files (smtp, tailscale, extras) may not exist
        # yet — seed them from the .example template under
        # inventory/host_vars/homeserver.example/ so the operator sees
        # the expected schema + commented defaults.
        if [[ ! -f "$FULL_PATH" ]]; then
            TEMPLATE="inventory/host_vars/homeserver.example/$FILE.example"
            if [[ -f "$TEMPLATE" ]]; then
                cp "$TEMPLATE" "$FULL_PATH"
                info "Seeded $FULL_PATH from $TEMPLATE (edit then save to apply)."
            else
                warn "$FULL_PATH doesn't exist and no template found; creating empty file."
                : > "$FULL_PATH"
            fi
        fi
        # Print the vault-encrypt hint before opening the editor — the
        # operator may need to refresh a secret while editing.
        info "Editing $FULL_PATH for $TARGET..."
        info "Vault-encrypt a fresh secret in another terminal:"
        info "  cd $INSTALL_DIR && ansible-vault encrypt_string '<value>' --name '<var>'"
        info "(or run \`homeserver.sh secret <var>\` first to dump the current value)"
        "${EDITOR:-vi}" "$FULL_PATH"
        # Detect "no change" via mtime so we don't pointlessly run the
        # playbook when the operator opens + quits.
        info "Applying via playbooks/$PLAYBOOK --limit $TARGET..."
        ansible-playbook "playbooks/$PLAYBOOK" --limit "$TARGET"
        rc=$?
        if [[ $rc -eq 0 ]]; then
            ok "$SECTION reconfigured for $TARGET."
            echo
            info "Persist the change to the overlay:"
            echo "  cd $HOME/home-server-private"
            echo "  git add -A && git commit -m '$TARGET: config $SECTION' && git push"
        else
            err "Playbook failed (exit $rc). Inventory file has been updated; re-run"
            err "  ansible-playbook playbooks/$PLAYBOOK --limit $TARGET"
            err "after fixing the underlying issue."
            exit $rc
        fi
        exit 0
        ;;
    add)
        SERVICE="${1:-}"
        if [[ -z "$SERVICE" ]]; then
            err "Usage: homeserver.sh add <service>"
            err "Available services:"
            for m in "$INSTALL_DIR"/roles/platform/*/meta/install.yml "$INSTALL_DIR"/roles/apps/*/meta/install.yml; do
                [[ -f "$m" ]] || continue
                svc=$(basename "$(dirname "$(dirname "$m")")")
                desc=$(python3 -c "import yaml; print(yaml.safe_load(open('$m')).get('description',''))" 2>/dev/null)
                printf "  %-18s %s\n" "$svc" "$desc"
            done
            exit 2
        fi
        ensure_install_dir
        ensure_ansible_on_path
        if ! META=$(resolve_meta_install "$INSTALL_DIR" "$SERVICE"); then
            err "Unknown service '$SERVICE' (no roles/{platform,apps}/$SERVICE/meta/install.yml)."
            err "Run \`homeserver.sh add\` with no args to see available services."
            exit 1
        fi
        TARGET=$(resolve_target_host)
        cd "$INSTALL_DIR"
        VAULT_PW_FILE="$HOME/.vaultpw"
        if [[ ! -r "$VAULT_PW_FILE" ]]; then
            err "$VAULT_PW_FILE not readable. Run \`homeserver.sh install\` first."
            exit 1
        fi
        ensure_ansible_cfg
        # Idempotency check: is the service already deployed?
        # ansible-inventory returns `deploy_services` as the raw Jinja
        # template string from inventory/group_vars/all.yml (it doesn't
        # template), so `or []` against it would yield a non-empty string
        # and `list + str` raises TypeError. Union platform_services + apps
        # only — that's the actual source of truth post-PR-262.
        if ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PW_FILE" \
                ansible-inventory --host "$TARGET" 2>/dev/null \
                | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if '$SERVICE' in ((d.get('platform_services') or []) + (d.get('apps') or [])) else 1)"; then
            warn "$SERVICE is already deployed on $TARGET."
            warn "Use \`homeserver.sh upgrade\` to re-deploy with latest images."
            exit 1
        fi
        # Ensure ruamel.yaml is available for the merge step.
        # Step 1 of `install` adds python3-ruamel-yaml via dnf; this
        # lazy install covers hosts that ran install before that line
        # landed (Phase 5b).
        if ! python3 -c "import ruamel.yaml" 2>/dev/null; then
            info "Installing python3-ruamel-yaml for inventory merge (one-time)..."
            sudo dnf install -y python3-ruamel-yaml &>/dev/null
            if ! python3 -c "import ruamel.yaml" 2>/dev/null; then
                err "Failed to install python3-ruamel-yaml. Required for homeserver.sh add."
                exit 1
            fi
        fi
        info "Resolving inventory updates for $SERVICE from $META..."
        UPDATE_JSON=$(mktemp --suffix=.json)
        PROMPTS_TXT=$(mktemp --suffix=.txt)
        # shellcheck disable=SC2064
        trap "rm -f $UPDATE_JSON $PROMPTS_TXT" EXIT
        PROMPTED_ARGS=()
        # Discovery pass: build_add_update.py exits 3 with PROMPTS_NEEDED
        # on stdout if the role declares `secret_prompt` vars. We collect
        # operator-supplied values and re-invoke with --prompted-secrets.
        if ! python3 scripts/build_add_update.py \
                --meta "$META" \
                --service "$SERVICE" \
                --vault-password-file "$VAULT_PW_FILE" \
                --target-host "$TARGET" \
                --inventory-dir "$INSTALL_DIR/inventory" \
                --output "$UPDATE_JSON" > "$PROMPTS_TXT" 2>&1; then
            if grep -q '^PROMPTS_NEEDED$' "$PROMPTS_TXT"; then
                info "Role needs operator-supplied secret(s):"
                # Inner `read` MUST come from /dev/tty — the while loop's
                # stdin is the file we're iterating over, so a bare
                # `read pval` would silently consume the next line of
                # PROMPTS_TXT (the password's own metadata) as the user's
                # input. /dev/tty bypasses the redirect.
                while IFS=$'\t' read -r pkey ptext pconfirm pmask; do
                    [[ "$pkey" == "PROMPTS_NEEDED" || -z "$pkey" ]] && continue
                    # Default mask=true if the older build_add_update.py
                    # didn't emit the field (back-compat).
                    pmask="${pmask:-true}"
                    read_flags="-r"
                    [[ "$pmask" == "true" ]] && read_flags="-rs"
                    echo
                    ask "$ptext:"
                    # shellcheck disable=SC2086
                    read $read_flags pval </dev/tty
                    [[ "$pmask" == "true" ]] && echo
                    if [[ "$pconfirm" == "true" ]]; then
                        ask "$ptext (confirm):"
                        # shellcheck disable=SC2086
                        read $read_flags pval2 </dev/tty
                        [[ "$pmask" == "true" ]] && echo
                        if [[ "$pval" != "$pval2" ]]; then
                            err "Values do not match. Aborting."
                            exit 1
                        fi
                    fi
                    PROMPTED_ARGS+=("$pkey=$pval")
                done < "$PROMPTS_TXT"
                if ! python3 scripts/build_add_update.py \
                        --meta "$META" \
                        --service "$SERVICE" \
                        --vault-password-file "$VAULT_PW_FILE" \
                        --target-host "$TARGET" \
                        --inventory-dir "$INSTALL_DIR/inventory" \
                        --prompted-secrets "${PROMPTED_ARGS[@]}" \
                        --output "$UPDATE_JSON"; then
                    err "Failed to build update spec after collecting prompts."
                    exit 1
                fi
            else
                err "Failed to build update spec for $SERVICE."
                cat "$PROMPTS_TXT" >&2
                exit 1
            fi
        fi
        HV_DIR="$INSTALL_DIR/inventory/host_vars/$TARGET"
        # Route the update across split files (00-services.yml /
        # 01-linux-users.yml / 10-caddy.yml / apps/<svc>.yml).
        info "Merging into $HV_DIR/ ..."
        if ! python3 scripts/inventory_merge.py \
                --host-vars-dir "$HV_DIR" \
                --service "$SERVICE" \
                --vault-password-file "$VAULT_PW_FILE" \
                --update "$UPDATE_JSON" \
                --mode add; then
            err "Failed to merge inventory."
            exit 1
        fi
        ok "Inventory updated."
        # Run the role's playbooks
        info "Deploying $SERVICE (running role playbooks)..."
        # shellcheck disable=SC2046
        while IFS= read -r pb; do
            [[ -z "$pb" ]] && continue
            info "  → $pb"
            if ! ansible-playbook "$pb" --limit "$TARGET"; then
                err "Playbook $pb failed. Inventory has been updated but"
                err "the role isn't fully deployed. Investigate, then re-run:"
                err "  cd $INSTALL_DIR && ansible-playbook $pb --limit $TARGET"
                exit 1
            fi
        done < <(python3 -c "import yaml; [print(pb) for pb in yaml.safe_load(open('$META'))['playbooks']]")
        ok "$SERVICE deployed."
        echo
        info "Persist the inventory update to the overlay:"
        echo "  cd $HOME/home-server-private"
        echo "  git add -A && git commit -m '$TARGET: add $SERVICE' && git push"
        exit 0
        ;;
    remove)
        SERVICE="${1:-}"
        PURGE=false
        shift || true
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --purge) PURGE=true ;;
                # Re-accept the top-level CLI flags so they can also
                # appear after the verb's positional arg, e.g.
                # `homeserver.sh remove jellyfin -h homeserver --purge`.
                # getopts at the top of the script only catches flags
                # that come before any positional arg.
                -h) shift; HOSTNAME_FLAG="${1:-}" ;;
                -v) shift; VAULT_PW_FLAG_FILE="${1:-}" ;;
                -y|--yes) YES_FLAG=true ;;
                *) err "Unknown remove flag: $1"; exit 2 ;;
            esac
            shift
        done
        if [[ -z "$SERVICE" ]]; then
            err "Usage: homeserver.sh remove <service> [--purge]"
            err "Run \`homeserver.sh add\` (no args) to list services."
            exit 2
        fi
        ensure_install_dir
        ensure_ansible_on_path
        if ! META=$(resolve_meta_install "$INSTALL_DIR" "$SERVICE"); then
            err "Unknown service '$SERVICE' (no roles/{platform,apps}/$SERVICE/meta/install.yml)."
            exit 1
        fi
        TARGET=$(resolve_target_host)
        cd "$INSTALL_DIR"
        VAULT_PW_FILE="$HOME/.vaultpw"
        if [[ ! -r "$VAULT_PW_FILE" ]]; then
            err "$VAULT_PW_FILE not readable. Is the host installed?"
            exit 1
        fi
        ensure_ansible_cfg
        # Idempotency check: is the service in platform_services or apps?
        # (group_vars-computed deploy_services comes back as a raw Jinja
        # string from ansible-inventory --host, so unioning it would raise
        # TypeError — see the matching comment in the `add` verb above.)
        if ! ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PW_FILE" \
                ansible-inventory --host "$TARGET" 2>/dev/null \
                | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if '$SERVICE' in ((d.get('platform_services') or []) + (d.get('apps') or [])) else 1)"; then
            warn "$SERVICE is not deployed on $TARGET — nothing to remove."
            exit 1
        fi
        # Extract service user + uid + volumes from meta + role defaults
        SERVICE_USER=$(python3 -c "
import yaml, sys
m = yaml.safe_load(open('$META'))
users = ((m.get('side_effects') or {}).get('my_linux_users') or {})
print(list(users.keys())[0] if users else '')
")
        SERVICE_UID=$(python3 -c "
import yaml, sys
m = yaml.safe_load(open('$META'))
users = ((m.get('side_effects') or {}).get('my_linux_users') or {})
print(list(users.values())[0].get('uid', '') if users else '')
")
        VOLUMES=$(python3 -c "
import yaml
m = yaml.safe_load(open('$META'))
on_remove = m.get('on_remove') or {}
print(' '.join(on_remove.get('volumes_to_preserve_unless_purge') or []))
")
        warn "Removing $SERVICE from $TARGET..."
        if [[ -n "$SERVICE_USER" && -n "$SERVICE_UID" ]]; then
            info "Stopping rootless services for user $SERVICE_USER (uid $SERVICE_UID)..."
            sudo -u "$SERVICE_USER" \
                XDG_RUNTIME_DIR=/run/user/"$SERVICE_UID" \
                DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/"$SERVICE_UID"/bus \
                systemctl --user stop '*' 2>/dev/null || true
            if [[ "$PURGE" == "true" && -n "$VOLUMES" ]]; then
                info "Purging data volumes: $VOLUMES"
                for vol in $VOLUMES; do
                    sudo -u "$SERVICE_USER" \
                        XDG_RUNTIME_DIR=/run/user/"$SERVICE_UID" \
                        podman volume rm "$vol" 2>/dev/null || true
                done
            else
                if [[ -n "$VOLUMES" ]]; then
                    info "Preserving data volumes (use --purge to delete):"
                    for vol in $VOLUMES; do
                        echo "  - $vol"
                    done
                fi
            fi
            info "Removing user $SERVICE_USER..."
            sudo loginctl disable-linger "$SERVICE_USER" 2>/dev/null || true
            sudo killall -u "$SERVICE_USER" 2>/dev/null || true
            sleep 1
            # -r wipes the home dir (which contains rootless podman
            # volumes under ~/.local/share/containers/). Only do that
            # with --purge; otherwise userdel without -r preserves
            # the home dir so a future `homeserver.sh add` can pick up the
            # data again.
            if [[ "$PURGE" == "true" ]]; then
                sudo userdel -r "$SERVICE_USER" 2>/dev/null || true
            else
                sudo userdel "$SERVICE_USER" 2>/dev/null || true
            fi
            sudo groupdel "$SERVICE_USER" 2>/dev/null || true
        fi
        # Ensure ruamel.yaml is available
        if ! python3 -c "import ruamel.yaml" 2>/dev/null; then
            info "Installing python3-ruamel-yaml..."
            sudo dnf install -y python3-ruamel-yaml &>/dev/null
        fi
        info "Updating inventory..."
        UPDATE_JSON=$(mktemp --suffix=.json)
        # shellcheck disable=SC2064
        trap "rm -f $UPDATE_JSON" EXIT
        if ! python3 scripts/build_remove_update.py \
                --meta "$META" --service "$SERVICE" --output "$UPDATE_JSON"; then
            err "Failed to build remove spec for $SERVICE."
            exit 1
        fi
        HV_DIR="$INSTALL_DIR/inventory/host_vars/$TARGET"
        if ! python3 scripts/inventory_merge.py \
                --host-vars-dir "$HV_DIR" \
                --service "$SERVICE" \
                --vault-password-file "$VAULT_PW_FILE" \
                --update "$UPDATE_JSON" \
                --mode remove; then
            err "Failed to update inventory."
            exit 1
        fi
        ok "Inventory updated."
        info "Refreshing caddy + dashboard..."
        ansible-playbook playbooks/caddy.yml --limit "$TARGET" || warn "caddy refresh failed"
        ansible-playbook playbooks/dashboard.yml --limit "$TARGET" || warn "dashboard refresh failed"
        ok "$SERVICE removed from $TARGET."
        echo
        info "Persist the inventory update to the overlay:"
        echo "  cd $HOME/home-server-private"
        echo "  git add -A && git commit -m '$TARGET: remove $SERVICE' && git push"
        exit 0
        ;;
esac

echo
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}   Home Server — Interactive Setup${NC}"
echo -e "${BOLD}============================================${NC}"
echo
echo "Setting up your server (${PRETTY_NAME:-${ID:-?} ${VERSION_ID:-?}}) as"
echo "an automated home server with containerized services managed by"
echo "Ansible and rootless Podman."
echo

# ============================================================================
# Step 1: Install prerequisites
# ============================================================================
info "Step 1/7: Installing prerequisites..."

# `pipx` lives in EPEL on AlmaLinux / Rocky / RHEL / CentOS-9 and in
# the base repos on Fedora. Enable EPEL on the RHEL-9 family before
# the install; on Fedora the block is skipped.
#
# We also install `python3.11` on the RHEL-9 family because:
#   - AL9's default system Python is 3.9.
#   - pipx defaults to building its venvs against the system Python.
#   - ansible-core 2.16+ requires Python ≥ 3.10.
#   - On Python 3.9, pipx caps us at ansible-core 2.15.x, which has
#     a parser bug in include_tasks/role-include path resolution
#     (TypeError: expected str, ... not NoneType) that this project's
#     Galaxy podman_quadlet role triggers reliably.
# python3.11 ships in AL9 AppStream; Fedora's system Python is
# already current so this whole block is a no-op there.
PIPX_PYTHON_ARG=()
if [[ "${ID:-}" =~ ^(almalinux|rocky|centos|rhel)$ ]]; then
    sudo dnf install -y epel-release python3.11 &>/dev/null \
        || sudo dnf install -y epel-release python3.11
    PIPX_PYTHON_ARG=(--python python3.11)
fi

sudo dnf install -y podman git openssl acl python3-pyyaml python3-ruamel-yaml pipx &>/dev/null \
    || sudo dnf install -y podman git openssl acl python3-pyyaml python3-ruamel-yaml pipx

# Hard-fail if pipx still isn't on PATH — usually means EPEL is
# misconfigured on AL/Rocky.
if ! command -v pipx &>/dev/null; then
    err "pipx not available after install — EPEL likely missing on AlmaLinux/Rocky."
    err "Try: sudo dnf install -y epel-release && sudo dnf install -y pipx"
    exit 1
fi

# Install ansible-core via pipx (latest available for the chosen
# Python). With python3.11 we get ansible-core 2.18.x; without the
# override on Fedora we get whatever's current for system Python.
if ! command -v ansible-playbook &>/dev/null; then
    pipx install "${PIPX_PYTHON_ARG[@]}" ansible-core &>/dev/null
    # Inject the full ansible package for built-in collections.
    pipx inject ansible-core ansible &>/dev/null
fi

# pipx installs into ~/.local/bin which isn't always on PATH for a
# fresh AlmaLinux 9 user (depends on ~/.bash_profile sourcing it).
# Make sure subsequent ansible-playbook calls in this script find it.
export PATH="$HOME/.local/bin:$PATH"

if ! command -v ansible-playbook &>/dev/null; then
    err "ansible-playbook not on PATH after pipx install."
    err "Expected at $HOME/.local/bin/ansible-playbook"
    exit 1
fi

ok "Prerequisites installed: $(ansible-playbook --version 2>/dev/null | head -1)"

# ============================================================================
# Step 2: Clone the repo
# ============================================================================
# (INSTALL_DIR set above in Verb dispatch block, reused here.)

# Move out of $INSTALL_DIR before any rm/clone — if the user
# happens to be running homeserver.sh from inside ~/home-server (e.g.
# re-running after a previous attempt), wiping it leaves the shell
# with an unlinked cwd, and `git clone` silently fails on the
# missing directory.
cd "$HOME"

if [[ -d "$INSTALL_DIR" ]]; then
    warn "$INSTALL_DIR already exists."
    if [[ "$YES_FLAG" == "true" ]]; then
        info "Overwriting (auto-confirmed by -y)."
        rm -rf "$INSTALL_DIR"
    else
        ask "Overwrite it? [y/N]:"
        read -r overwrite
        if [[ "$overwrite" =~ ^[Yy]$ ]]; then
            rm -rf "$INSTALL_DIR"
        else
            info "Using existing directory."
        fi
    fi
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
    info "Step 2/7: Cloning home-server repository..."
    # Don't suppress stderr — if git fails (auth, network, broken
    # cwd, …) we want the user to see why.
    git clone https://github.com/luckynrslevin/home-server.git "$INSTALL_DIR"
    ok "Repository cloned to $INSTALL_DIR"
else
    ok "Using existing $INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# ============================================================================
# Step 3: Install Galaxy dependency
# ============================================================================
info "Step 3/7: Installing Ansible Galaxy dependencies..."
ansible-galaxy install -r roles/requirements.yml --force 2>/dev/null
ok "Galaxy roles installed."

# ============================================================================
# Step 3.5: Hostname + optional private overlay
# ============================================================================
# Capture hostname early so the overlay prompt can look for an
# existing host_vars/<hostname>/ inventory. The hostname prompt in
# Step 5 used to live here; consolidated into this block.

# Hostname: CLI flag wins, else `hostname -s` as default in prompt.
DEFAULT_HOSTNAME=$(hostname -s 2>/dev/null)
if [[ -n "$HOSTNAME_FLAG" ]]; then
    SERVER_HOSTNAME="$HOSTNAME_FLAG"
    ok "Server hostname: $SERVER_HOSTNAME (from -h)"
elif [[ "$YES_FLAG" == "true" ]]; then
    SERVER_HOSTNAME="$DEFAULT_HOSTNAME"
    ok "Server hostname: $SERVER_HOSTNAME (from \`hostname -s\`)"
else
    echo
    ask "Server hostname [$DEFAULT_HOSTNAME]:"
    read -r SERVER_HOSTNAME
    SERVER_HOSTNAME=${SERVER_HOSTNAME:-$DEFAULT_HOSTNAME}
fi

OVERLAY_DIR="$HOME/home-server-private"
OVERLAY_URL=""
USE_EXISTING_INVENTORY=false

# Overlay repo URL: CLI flag wins, else interactive prompt (silent in
# -y mode — empty is a valid "no overlay" answer).
if [[ -n "$OVERLAY_URL_FLAG" ]]; then
    OVERLAY_URL="$OVERLAY_URL_FLAG"
    ok "Overlay repo: $OVERLAY_URL (from -i)"
elif [[ "$YES_FLAG" != "true" ]]; then
    echo
    echo -e "${BOLD}--- Private overlay repo (optional) ---${NC}"
    echo
    echo "If you have a private git repo for inventory storage — either an"
    echo "existing one (rebuild path) or a fresh empty one prepared for"
    echo "this host (first-time path) — point to it here. We'll clone it"
    echo "and either reuse its inventory as-is or generate fresh inventory"
    echo "directly into it."
    echo "Leave empty to keep inventory local in ~/home-server/inventory/."
    echo
    ask "Private overlay repo URL [empty to skip]:"
    read -r OVERLAY_URL
fi

if [[ -n "$OVERLAY_URL" ]]; then
    # Vault password sourcing priority:
    #   1. -v <file> flag
    #   2. overlay's existing vault.pw (rebuild path)
    #   3. interactive prompt
    if [[ -n "$VAULT_PW_FLAG_FILE" ]]; then
        if [[ ! -r "$VAULT_PW_FLAG_FILE" ]]; then
            err "Vault password file not readable: $VAULT_PW_FLAG_FILE"
            exit 1
        fi
        OVERLAY_VAULT_PW=$(< "$VAULT_PW_FLAG_FILE")
        ok "Vault password loaded from $VAULT_PW_FLAG_FILE (from -v)"
    elif [[ -d "$OVERLAY_DIR/.git" && -r "$OVERLAY_DIR/vault.pw" ]]; then
        OVERLAY_VAULT_PW=$(< "$OVERLAY_DIR/vault.pw")
        ok "Vault password reused from $OVERLAY_DIR/vault.pw"
    elif [[ "$YES_FLAG" == "true" ]]; then
        err "Overlay vault password required for -y mode (use -v <file> or pre-place vault.pw)."
        exit 1
    else
        ask "Vault password for the overlay (input hidden — invent one if the repo is empty):"
        read -rs OVERLAY_VAULT_PW
        echo
    fi
    if [[ -z "$OVERLAY_VAULT_PW" ]]; then
        err "Vault password is required when using an overlay."
        exit 1
    fi

    if [[ ! -d "$OVERLAY_DIR/.git" ]]; then
        info "Cloning overlay into $OVERLAY_DIR ..."
        git clone "$OVERLAY_URL" "$OVERLAY_DIR"
    else
        ok "Overlay already cloned at $OVERLAY_DIR — pulling latest."
        (cd "$OVERLAY_DIR" && git pull --ff-only) || warn "git pull failed; continuing with existing tree"
    fi

    mkdir -p "$OVERLAY_DIR/inventory/host_vars"

    # Persist vault.pw in the overlay so future rebuilds can re-read
    # it (priority #2 above). ~/.vaultpw becomes a symlink in Step 4.
    # vault.pw is mode 400 once written, so unlink first to allow
    # rewrite (e.g. when -v flag supplies a different password than
    # what's already cached on disk).
    if [[ ! -f "$OVERLAY_DIR/vault.pw" ]] || [[ "$(< "$OVERLAY_DIR/vault.pw")" != "$OVERLAY_VAULT_PW" ]]; then
        rm -f "$OVERLAY_DIR/vault.pw"
        echo -n "$OVERLAY_VAULT_PW" > "$OVERLAY_DIR/vault.pw"
        chmod 400 "$OVERLAY_DIR/vault.pw"
    fi

    if host_vars_dir_has_content "$OVERLAY_DIR/inventory/host_vars/$SERVER_HOSTNAME"; then
        USE_EXISTING_INVENTORY=true
        ok "Overlay has existing inventory for '$SERVER_HOSTNAME' — will reuse as defaults."
    else
        ok "Overlay has no inventory for '$SERVER_HOSTNAME' yet — will generate fresh into it."
        existing_hosts=$(ls -1 "$OVERLAY_DIR/inventory/host_vars/" 2>/dev/null | tr '\n' ' ')
        [[ -n "$existing_hosts" ]] && info "  Other hosts already in overlay: $existing_hosts"
    fi
elif [[ "$YES_FLAG" == "true" ]]; then
    err "-y mode requires an inventory source (-i <overlay-url> or pre-staged inventory)."
    exit 1
fi

# ============================================================================
# Step 4: Configure vault password
# ============================================================================
info "Step 4/7: Setting up Ansible Vault..."

VAULT_PW_FILE="$HOME/.vaultpw"

if [[ -n "$OVERLAY_URL" ]]; then
    # Overlay path — point ~/.vaultpw at the overlay's vault.pw.
    rm -f "$VAULT_PW_FILE"
    ln -s "$OVERLAY_DIR/vault.pw" "$VAULT_PW_FILE"
    ok "Vault password symlinked: $VAULT_PW_FILE → $OVERLAY_DIR/vault.pw"

    if [[ "$USE_EXISTING_INVENTORY" == "true" ]]; then
        # Verify vault password works against the existing inventory.
        # `ansible-vault view` only handles whole-file-encrypted files;
        # the split files use inline `!vault |` blocks (typically
        # 10-caddy.yml's caddy_acme_token). Find the first split file
        # carrying a vault block, extract that block, decrypt it
        # standalone, check the exit code.
        verify_tmp=$(mktemp)
        if vault_yml=$(find_vault_yml "$OVERLAY_DIR/inventory/host_vars/$SERVER_HOSTNAME"); then
            python3 - "$vault_yml" > "$verify_tmp" <<'PY'
import sys
with open(sys.argv[1]) as f:
    lines = f.readlines()
i = 0
while i < len(lines):
    if '$ANSIBLE_VAULT' in lines[i]:
        indent = len(lines[i]) - len(lines[i].lstrip())
        sys.stdout.write(lines[i].lstrip())
        i += 1
        while i < len(lines) and lines[i].strip() and lines[i].startswith(' ' * indent):
            sys.stdout.write(lines[i].lstrip())
            i += 1
        break
    i += 1
PY
        fi
        if [[ -s "$verify_tmp" ]]; then
            if ! ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PW_FILE" \
                    ansible-vault decrypt --output - "$verify_tmp" &>/dev/null; then
                rm -f "$verify_tmp"
                err "Vault password doesn't decrypt the existing inventory at"
                err "  ${vault_yml:-$OVERLAY_DIR/inventory/host_vars/$SERVER_HOSTNAME/}"
                err "Re-run homeserver.sh with the correct vault password."
                exit 1
            fi
            ok "Vault password verified — existing inventory decrypts cleanly."
        fi
        rm -f "$verify_tmp"
    fi
elif [[ -f "$VAULT_PW_FILE" ]]; then
    ok "Vault password already exists at $VAULT_PW_FILE"
else
    echo
    echo "Ansible Vault encrypts your secrets (passwords, API keys)."
    echo "You need a vault password — either generate a random one or choose your own."
    echo
    ask "Generate a random vault password? [Y/n]:"
    read -r gen_vault

    if [[ "$gen_vault" =~ ^[Nn]$ ]]; then
        ask "Enter your vault password:"
        read -rs vault_pw
        echo
        echo -n "$vault_pw" > "$VAULT_PW_FILE"
    else
        openssl rand -base64 32 > "$VAULT_PW_FILE"
    fi

    chmod 400 "$VAULT_PW_FILE"
    ok "Vault password saved to $VAULT_PW_FILE (mode 400)"
    echo
    warn "Back up this file! Without it you cannot decrypt your secrets."
fi

# Point ansible.cfg at the vault password file
cat > ansible.cfg << EOF
[defaults]
inventory = inventory/hosts.yml
roles_path = ./roles/platform:./roles/apps:./roles:./.ansible/roles:~/.ansible/roles:/usr/share/ansible/roles
stdout_callback = default
host_key_checking = False
vault_password_file = $VAULT_PW_FILE

[ssh_connection]
pipelining = True
use_tty = False
EOF

# Point the public repo's inventory/ at the overlay for host-specific
# data (hosts.yml + host_vars/<host>/) while keeping inventory/group_vars/
# from the public repo intact — that's where deploy_services is
# computed from platform_services + apps. The old scheme (whole-dir
# symlink) shadowed group_vars/ and broke `deploy_services` at runtime.
if [[ -n "$OVERLAY_URL" ]]; then
    # Migrate any pre-existing whole-dir symlink to the new selective
    # scheme. Idempotent — does nothing if already selective.
    if [[ -L inventory ]]; then
        rm inventory
        git checkout -- inventory/ 2>/dev/null || true
    fi
    # Ensure the public inventory/ dir is there with its group_vars.
    if [[ ! -d inventory ]]; then
        git checkout -- inventory/ 2>/dev/null || mkdir -p inventory
    fi
    # Selective symlinks: hosts.yml + host_vars → overlay.
    if [[ ! -L inventory/hosts.yml ]]; then
        rm -f inventory/hosts.yml
        ln -s "$OVERLAY_DIR/inventory/hosts.yml" inventory/hosts.yml
        ok "Symlinked inventory/hosts.yml → $OVERLAY_DIR/inventory/hosts.yml"
    fi
    if [[ ! -L inventory/host_vars ]]; then
        rm -rf inventory/host_vars
        ln -s "$OVERLAY_DIR/inventory/host_vars" inventory/host_vars
        ok "Symlinked inventory/host_vars → $OVERLAY_DIR/inventory/host_vars"
    fi
fi

info "Step 5/7: Configuring your server..."

# Load existing inventory (if any) so every prompt below can default
# from its previous value. Decrypts vault blocks in the dict.
# ansible-inventory --host walks every *.yml under host_vars/<host>/
# (and the apps/ subdir), so any split-layout file present counts.
if host_vars_dir_has_content "inventory/host_vars/$SERVER_HOSTNAME"; then
    EXISTING_VARS_JSON=$(ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PW_FILE" \
        ansible-inventory --host "$SERVER_HOSTNAME" 2>/dev/null) || EXISTING_VARS_JSON='{}'
    if [[ "$EXISTING_VARS_JSON" != "{}" ]]; then
        ok "Loaded existing inventory for $SERVER_HOSTNAME — values will populate prompt defaults."
    fi
fi

# --- Release pinning ---
# Resolve which tag of the home-server repo to deploy. Priority:
#   1. -r <tag> CLI flag (explicit operator choice)
#   2. home_server_release in inventory (rebuild — stay on the same
#      release that was installed last time, so `add service` and
#      `upgrade` are bounded to that major)
#   3. latest stable v* tag from the cloned repo (fresh install)
#   4. main (no tags yet — graceful fallback)
#
# The script's Step 2 clone always pulls main initially (since we
# don't know the answer yet). Now that we have the answer, switch
# checkout to the resolved tag.
INVENTORY_RELEASE=$(inv_get home_server_release)
if [[ -n "$RELEASE_FLAG" ]]; then
    HOME_SERVER_RELEASE="$RELEASE_FLAG"
    info "Release tag (from -r): $HOME_SERVER_RELEASE"
elif [[ -n "$INVENTORY_RELEASE" ]]; then
    HOME_SERVER_RELEASE="$INVENTORY_RELEASE"
    info "Release tag (from inventory): $HOME_SERVER_RELEASE"
else
    # Fresh install — pick the latest stable v* tag, or main if no tags exist.
    (cd "$INSTALL_DIR" && git fetch --tags --quiet 2>/dev/null) || true
    LATEST_TAG=$(cd "$INSTALL_DIR" && git tag --list 'v*' --sort=-v:refname 2>/dev/null | head -1)
    LATEST_TAG=${LATEST_TAG:-main}
    if [[ "$YES_FLAG" == "true" ]]; then
        HOME_SERVER_RELEASE="$LATEST_TAG"
        info "Release tag (auto-detected): $HOME_SERVER_RELEASE"
    else
        ask "Release tag to install [$LATEST_TAG]:"
        read -r release_input
        HOME_SERVER_RELEASE="${release_input:-$LATEST_TAG}"
    fi
fi

# Switch the home-server checkout to the resolved tag.
# `git -C` runs git in that dir without polluting cwd.
if [[ "$HOME_SERVER_RELEASE" != "main" ]]; then
    if ! git -C "$INSTALL_DIR" rev-parse --verify "$HOME_SERVER_RELEASE" &>/dev/null; then
        git -C "$INSTALL_DIR" fetch --tags --quiet || true
    fi
    if git -C "$INSTALL_DIR" checkout --quiet "$HOME_SERVER_RELEASE" 2>/dev/null; then
        ok "home-server checked out at $HOME_SERVER_RELEASE"
    else
        err "Failed to check out $HOME_SERVER_RELEASE — tag doesn't exist."
        err "Available tags: $(git -C "$INSTALL_DIR" tag --list 'v*' --sort=-v:refname | tr '\n' ' ')"
        exit 1
    fi
else
    info "Staying on main (no release tag pinned)."
fi

# Server IP is detected fresh every run (DHCP may have moved the host
# between rebuilds; we don't want to PATCH a stale A record).
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo
echo -e "${BOLD}--- Network Configuration ---${NC}"
echo

DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
DEFAULT_GATEWAY_DETECTED=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
DEFAULT_NETWORK_DETECTED=$(ip -4 addr show "$DEFAULT_IFACE" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
DEFAULT_USER=$(whoami)

# --- TLS via deSEC + Let's Encrypt ---
echo
echo -e "${BOLD}--- deSEC + Let's Encrypt ---${NC}"
echo
echo "Caddy issues real Let's Encrypt certs via DNS-01 against deSEC."
echo "Every device gets a green padlock with no per-device CA install."
echo "Sign up at https://desec.io/ first if you haven't:"
echo "  1. Register an account and confirm via email."
echo "  2. Claim a *.dedyn.io subdomain at first sign-in."
echo "  3. Create an API token in Token Management."
echo "See docs/Setup-Guide/01-deSEC-account.md for the click-by-click."
echo
prompt_default        caddy_acme_subdomain "deSEC subdomain (without .dedyn.io)" ""
DESEC_SUBDOMAIN="$caddy_acme_subdomain"
if [[ -z "$DESEC_SUBDOMAIN" ]]; then
    err "deSEC subdomain is required."
    exit 1
fi
prompt_default_hidden caddy_acme_token     "deSEC API token (input hidden)"
DESEC_TOKEN="$caddy_acme_token"
if [[ -z "$DESEC_TOKEN" ]]; then
    err "deSEC token is required."
    exit 1
fi
CADDY_DOMAIN="${DESEC_SUBDOMAIN}.dedyn.io"
ok "Caddy domain: $CADDY_DOMAIN"

prompt_default ansible_user            "Your username"                "$DEFAULT_USER"
SERVER_USER="$ansible_user"

prompt_default pihole_local_network    "LAN subnet (for Pi-hole)"     "$DEFAULT_NETWORK_DETECTED"
LAN_NETWORK="$pihole_local_network"
# Normalise host IP/CIDR (e.g. 192.168.1.5/24) to subnet CIDR (192.168.1.0/24).
LAN_PREFIX=$(echo "$LAN_NETWORK" | cut -d/ -f2)
LAN_NETWORK_BASE=$(echo "$LAN_NETWORK" | cut -d/ -f1 | awk -F. '{printf "%s.%s.%s.0", $1, $2, $3}')
LAN_CIDR="${LAN_NETWORK_BASE}/${LAN_PREFIX}"

prompt_default pihole_local_router     "LAN gateway/router"           "$DEFAULT_GATEWAY_DETECTED"
LAN_GATEWAY="$pihole_local_router"

echo
echo -e "${BOLD}--- Timezone ---${NC}"
echo
DEFAULT_TZ_DETECTED=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")
prompt_default paperless_time_zone     "Timezone"                     "$DEFAULT_TZ_DETECTED"
TIMEZONE="$paperless_time_zone"

# --- SMTP relay (project-level) ---
echo
echo -e "${BOLD}--- SMTP relay (required) ---${NC}"
echo
echo "Nextcloud (password resets, share notifications), Ente Photos"
echo "(signup OTPs) and Paperless need an external SMTP relay to send"
echo "mail. See docs/SMTP-Setup.md for picking a provider (Mailbox.org"
echo "/ Posteo / etc.) and generating an app password."
echo
prompt_default        smtp_host       "SMTP host"                    "smtp.mailbox.org"
SMTP_HOST="$smtp_host"
prompt_default        smtp_port       "SMTP port"                    "587"
SMTP_PORT="$smtp_port"
prompt_default        smtp_username   "SMTP username (full email)"   ""
SMTP_USERNAME="$smtp_username"
if [[ -z "$SMTP_USERNAME" ]]; then
    err "SMTP username is required."
    exit 1
fi
prompt_default_hidden smtp_password   "SMTP password / app password (input hidden)"
SMTP_PASSWORD="$smtp_password"
if [[ -z "$SMTP_PASSWORD" ]]; then
    err "SMTP password is required."
    exit 1
fi
prompt_default        smtp_encryption "Encryption (starttls / ssl)"  "starttls"
SMTP_ENCRYPTION="$smtp_encryption"
prompt_default        smtp_from       "From address"                 "$SMTP_USERNAME"
SMTP_FROM="$smtp_from"
ok "SMTP relay configured."

echo
echo -e "${BOLD}--- Service Selection ---${NC}"
echo
echo "Caddy + Nextcloud are always deployed (front-door reverse proxy"
echo "+ household OIDC identity provider). For the rest, defaults"
echo "follow the recommended baseline; previous \`deploy_services\`"
echo "from inventory takes priority."
echo

declare -A SERVICES=(
    [dashboard]="Status dashboard showing all services"
    [backup]="Nightly backup to a NAS via NFS (needs LAN-reachable NAS)"
    [pihole]="Pi-hole DNS ad-blocker"
    [entephoto]="Ente Photos (self-hosted photo storage)"
    [paperless-ngx]="Paperless-NGX document management (OCR + search)"
    [syncthing]="Syncthing file synchronization"
    [shairportsync]="Shairport-sync AirPlay audio receiver (needs audio device)"
    [jellyfin]="Jellyfin media server (movies, TV, music)"
    [music-assistant]="Music Assistant music server (optional local Squeezelite player on hosts with a USB DAC)"
)

SELECTED_SERVICES=(caddy nextcloud)

SERVICE_ORDER=(dashboard backup pihole entephoto paperless-ngx syncthing shairportsync jellyfin music-assistant)
declare -A SERVICE_DEFAULT_YES=(
    [dashboard]=1
    [backup]=1
    [pihole]=1
    [entephoto]=1
    [paperless-ngx]=1
)

# If inventory has the platform_services / apps split (or a legacy
# deploy_services list), prefer it: a service is defaulted Y iff it's
# in the existing union.
EXISTING_PLATFORM=$(inv_get platform_services)
EXISTING_APPS=$(inv_get apps)
EXISTING_LEGACY=$(inv_get deploy_services)
declare -A INV_DEPLOY=()
_have_existing=""
for _src in "$EXISTING_PLATFORM" "$EXISTING_APPS" "$EXISTING_LEGACY"; do
    [[ -z "$_src" ]] && continue
    # inv_get returns a literal Jinja string ("{{ ... }}") for the
    # group_vars-computed deploy_services — skip those.
    [[ "$_src" == \{\{*\}\}* || "$_src" == *\{\{* ]] && continue
    _have_existing=1
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && INV_DEPLOY[$svc]=1
    done < <(echo "$_src" | python3 -c "import json,sys
try:
    d = json.load(sys.stdin)
    if isinstance(d, list):
        print('\n'.join(d))
except Exception:
    pass")
done
EXISTING_DEPLOY_SERVICES="$_have_existing"

for svc in "${SERVICE_ORDER[@]}"; do
    desc="${SERVICES[$svc]}"
    # Resolve default-Y from (a) prior inventory, else (b) hardcoded baseline.
    if [[ -n "$EXISTING_DEPLOY_SERVICES" ]]; then
        if [[ -n "${INV_DEPLOY[$svc]:-}" ]]; then
            default_yes=1
        else
            default_yes=0
        fi
    else
        default_yes=${SERVICE_DEFAULT_YES[$svc]:-0}
    fi

    if [[ "$YES_FLAG" == "true" ]]; then
        [[ "$default_yes" == "1" ]] && SELECTED_SERVICES+=("$svc")
        continue
    fi

    if [[ "$default_yes" == "1" ]]; then
        ask "Deploy $svc? ($desc) [Y/n]:"
        read -r answer
        [[ ! "$answer" =~ ^[Nn]$ ]] && SELECTED_SERVICES+=("$svc")
    else
        ask "Deploy $svc? ($desc) [y/N]:"
        read -r answer
        [[ "$answer" =~ ^[Yy]$ ]] && SELECTED_SERVICES+=("$svc")
    fi
done

echo
ok "Selected services: ${SELECTED_SERVICES[*]}"

is_selected() {
    local needle=$1
    for s in "${SELECTED_SERVICES[@]}"; do
        [[ "$s" == "$needle" ]] && return 0
    done
    return 1
}

# --- NAS prompts (only if backup is selected) ---
if is_selected backup; then
    echo
    echo -e "${BOLD}--- Backup NAS ---${NC}"
    echo
    echo "Backup is a nightly rsync/tar/pgdump to a LAN-reachable NAS"
    echo "via NFS. You need:"
    echo "  - The NAS reachable on your LAN (DHCP-reserved IP)."
    echo "  - An NFS share exported to this host's IP, with subdirs"
    echo "    matching each service that backs up via rsync (\`backup-pihole\`,"
    echo "    \`backup-syncthing\`, etc. — see roles/backup/README.md)."
    echo
    prompt_default backup_nas_hostname "NAS hostname" "nas"
    prompt_default backup_nas_ip       "NAS IP address" ""
    if [[ -z "$backup_nas_ip" ]]; then
        err "NAS IP is required when backup is selected."
        err "(Set up a DHCP reservation on your router, then re-run.)"
        exit 1
    fi
    prompt_default backup_nas_volume   "NAS share root path" "/volume1"
    prompt_default backup_time         "Daily backup time (HH:MM:SS)" "02:00:00"
fi

# ============================================================================
# Step 6: Generate configuration files
# ============================================================================
info "Step 6/7: Generating configuration files..."

# Helper: vault-encrypt a string.
# Uses a temp file for the value (avoids stdin conflicts with curl pipe).
# Uses ANSIBLE_VAULT_PASSWORD_FILE env var instead of --vault-password-file
# flag to avoid "duplicate vault-ids" error when ansible.cfg also sets it.
vault_encrypt() {
    local value=$1 name=$2
    local tmpfile
    tmpfile=$(mktemp)
    echo -n "$value" > "$tmpfile"
    ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PW_FILE" \
    ansible-vault encrypt_string \
        --encrypt-vault-id default \
        --stdin-name "$name" < "$tmpfile" 2>/dev/null
    rm -f "$tmpfile"
}

# --- Generate inventory/hosts.yml ---
mkdir -p "inventory/host_vars/$SERVER_HOSTNAME"

# When the overlay already has a multi-host hosts.yml, merge instead
# of clobber. Pure write for a brand-new file.
if [[ -s inventory/hosts.yml ]]; then
    python3 - "$SERVER_HOSTNAME" "$SERVER_USER" << 'PYEOF'
import sys, yaml
hostname, user = sys.argv[1], sys.argv[2]
with open("inventory/hosts.yml") as f:
    data = yaml.safe_load(f) or {}
data.setdefault("all", {}).setdefault("children", {}).setdefault(
    "homeservers", {}).setdefault("hosts", {})[hostname] = {
        "ansible_host": "127.0.0.1",
        "ansible_connection": "local",
        "ansible_user": user,
    }
with open("inventory/hosts.yml", "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
PYEOF
    ok "Merged $SERVER_HOSTNAME into existing inventory/hosts.yml"
else
    cat > inventory/hosts.yml << EOF
all:
  children:
    homeservers:
      hosts:
        $SERVER_HOSTNAME:
          ansible_host: 127.0.0.1
          ansible_connection: local
          ansible_user: $SERVER_USER
EOF
    ok "Generated inventory/hosts.yml"
fi

# --- Generate host_vars ---
info "Resolving secrets (reusing existing from inventory where present)..."

# Resolve each secret: if the inventory already has a value, reuse it
# (so a rebuild doesn't rotate every password). Otherwise generate.
# Inventory key names mirror the YAML emission below.
resolve_secret() {
    # resolve_secret <shell_var_name> <inventory_key> <openssl args...>
    # If <inventory_key> exists in inventory, reuse it (transparently
    # decrypts vault blocks via inv_get). Otherwise generate via openssl.
    local shvar=$1 inv_key=$2; shift 2
    local existing
    existing=$(inv_get "$inv_key")
    if [[ -n "$existing" ]]; then
        printf -v "$shvar" '%s' "$existing"
    else
        printf -v "$shvar" '%s' "$(openssl "$@")"
    fi
}

resolve_secret PIHOLE_PW            pihole_api_password         rand -base64 24
resolve_secret ENTEPHOTO_DB_PW      entephoto_db_password       rand -base64 24
resolve_secret ENTEPHOTO_GARAGE_RPC   entephoto_garage_rpc_secret    rand -hex 32
resolve_secret ENTEPHOTO_GARAGE_ADMIN entephoto_garage_admin_token   rand -base64 24
resolve_secret ENTEPHOTO_ENC_KEY    entephoto_encryption_key    rand -base64 32
# Hash key is 64-byte base64; tr strips the trailing newline from openssl.
existing_hash=$(inv_get entephoto_hash_key)
if [[ -n "$existing_hash" ]]; then
    ENTEPHOTO_HASH_KEY="$existing_hash"
else
    ENTEPHOTO_HASH_KEY=$(openssl rand -base64 64 | tr -d '\n')
fi
resolve_secret ENTEPHOTO_JWT        entephoto_jwt_secret        rand -hex 32
resolve_secret PAPERLESS_SECRET_KEY paperless_secret_key        rand -hex 32
resolve_secret PAPERLESS_DB_PW      paperless_db_password       rand -base64 24
resolve_secret PAPERLESS_ADMIN_PW   paperless_admin_password    rand -base64 24
resolve_secret JELLYFIN_ADMIN_PW    jellyfin_admin_password     rand -base64 24
resolve_secret NEXTCLOUD_ADMIN_PW   nextcloud_admin_password    rand -base64 24
resolve_secret NEXTCLOUD_DB_PW      nextcloud_db_password       rand -base64 24

# Music Assistant's Squeezelite player identifies by MAC under
# SlimProto. Keep the value stable across rebuilds — reuse from
# inventory if present; otherwise generate a locally-administered
# unicast MAC (first octet 0x02 → b1=1, b0=0).
existing_mac=$(inv_get music_assistant_squeezelite_mac)
if [[ -n "$existing_mac" ]]; then
    MUSIC_ASSISTANT_MAC="$existing_mac"
else
    MUSIC_ASSISTANT_MAC="02:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g;s/:$//')"
fi

HOST_VARS_DIR="inventory/host_vars/$SERVER_HOSTNAME"
APPS_DIR="$HOST_VARS_DIR/apps"
mkdir -p "$APPS_DIR"

_split_header='# DO NOT EDIT — managed by homeserver.sh'

# --- 00-services.yml: host identity + platform_services + apps lists ---
# Split SELECTED_SERVICES into platform infrastructure vs application
# roles. `deploy_services` is computed in inventory/group_vars/all.yml
# as the concatenation of the two — playbooks keep iterating that name.
# (Platform classification helper `is_platform_service` is defined at
# the top of this script so add/remove verbs can use it too.)
PLATFORM_SELECTED=()
APPS_SELECTED=()
for svc in "${SELECTED_SERVICES[@]}"; do
    if is_platform_service "$svc"; then
        PLATFORM_SELECTED+=("$svc")
    else
        APPS_SELECTED+=("$svc")
    fi
done

{
cat << YAML
$_split_header
##################################################################################################
### Host identity
# Pin the system hostname so os-base never renames the box on a
# re-deploy (the role's default would be inventory_hostname).
os_base_hostname: $SERVER_HOSTNAME

# home-server release pinned for this host. Used by homeserver.sh to
# decide which tag to check out on rebuild + add-service flows
# (so an \`add\` doesn't accidentally pull in a different major).
# Override at install time with \`homeserver.sh -r <tag>\`.
home_server_release: $HOME_SERVER_RELEASE

##################################################################################################
### Platform services — mandatory + optional infrastructure roles
# caddy + dashboard are mandatory (asserted in playbooks/site.yml).
# pihole / backup / os-tailscale are optional and additionally gated by
# their <svc>_enabled flag (defaults to true when listed).
platform_services:
YAML
for svc in "${PLATFORM_SELECTED[@]}"; do
    echo "  - $svc"
done

cat << YAML

##################################################################################################
### Apps — user-managed list. Add via \`homeserver.sh add <name>\`;
### remove via \`homeserver.sh remove <name>\`.
apps:
YAML
if [[ ${#APPS_SELECTED[@]} -eq 0 ]]; then
    echo "  []"
else
    for svc in "${APPS_SELECTED[@]}"; do
        echo "  - $svc"
    done
fi
} > "$HOST_VARS_DIR/00-services.yml"

# --- 01-linux-users.yml: my_linux_users dict ---
#
# Source-of-truth: each selected role's meta/install.yml carries
# side_effects.my_linux_users. Aggregate those, then layer the existing
# inventory dict on top so operator-set UIDs are preserved per-key.
# This stops nextcloud-style misses where a previously-deployed inventory's
# dict didn't include a newly-selected service (the install then failed
# at "Ensure rootless user group exists" because my_linux_users.<svc> was
# undefined).
existing_users_json=$(inv_get my_linux_users)
META_PATHS=()
for svc in "${SELECTED_SERVICES[@]}"; do
    if m=$(resolve_meta_install "$INSTALL_DIR" "$svc"); then
        META_PATHS+=("$m")
    fi
done

{
cat << YAML
$_split_header
##################################################################################################
### Linux users — service accounts with fixed UIDs
###
### Merged from each selected role's meta/install.yml side_effects.my_linux_users,
### with the existing inventory dict layered on top (operator overrides win
### per-key). Add an operator-only user by editing 20-extras.yml.
YAML

EXISTING="$existing_users_json" \
    SERVER_USER="$SERVER_USER" \
    python3 - "${META_PATHS[@]}" <<'PY'
import json, os, sys, yaml

merged = {}

# Layer 1: union of side_effects.my_linux_users across selected roles.
for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            meta = yaml.safe_load(fh) or {}
    except Exception:
        continue
    users = (meta.get('side_effects') or {}).get('my_linux_users') or {}
    for name, props in users.items():
        merged[name] = dict(props)

# Layer 2: existing inventory wins per-key — preserves operator-set
# UIDs and any hand-added users.
existing_raw = (os.environ.get('EXISTING') or '').strip()
if existing_raw:
    try:
        existing = json.loads(existing_raw)
        if isinstance(existing, dict):
            for name, props in existing.items():
                if isinstance(props, dict):
                    merged[name] = dict(props)
    except json.JSONDecodeError:
        pass

# Layer 3: always include the operator's primary login user (the host's
# SERVER_USER) at uid 1000 so my_linux_users is never missing the root
# operator account.
server_user = os.environ.get('SERVER_USER') or 'ds'
merged.setdefault(server_user, {'uid': 1000, 'gid': 1000})

# Sort by uid for stable output (matches the visual ordering operators
# expect when scanning the file).
ordered = dict(sorted(merged.items(),
                      key=lambda kv: kv[1].get('uid', 9999)))

print(yaml.safe_dump({'my_linux_users': ordered},
                     default_flow_style=False,
                     sort_keys=False).rstrip())
PY
} > "$HOST_VARS_DIR/01-linux-users.yml"

# --- 10-caddy.yml: caddy core + reverse-proxy services ---
{
cat << YAML
$_split_header
##################################################################################################
### Caddy reverse-proxy + Let's Encrypt via deSEC DNS-01
caddy_domain: "$CADDY_DOMAIN"
caddy_acme_provider: "desec"
caddy_acme_subdomain: "$DESEC_SUBDOMAIN"
YAML
echo ""
vault_encrypt "$DESEC_TOKEN" "caddy_acme_token"
echo ""

# caddy_reverse_proxy_services: union of (each selected role's meta
# side_effects.caddy_reverse_proxy_services) + the existing inventory's
# list, keyed by subdomain. Existing entries win per-key — preserves
# operator port overrides and hand-added subdomains. Missing entries
# for newly-selected services get filled in from meta.
#
# (Bug class fixed previously for my_linux_users in PR #272: the old
# "if existing present, copy verbatim" branch silently dropped any
# newly-selected service's subdomain because the existing inventory
# was preserved with no union.)
existing_rps_json=$(inv_get caddy_reverse_proxy_services)
META_PATHS=()
for svc in "${SELECTED_SERVICES[@]}"; do
    if m=$(resolve_meta_install "$INSTALL_DIR" "$svc"); then
        META_PATHS+=("$m")
    fi
done

EXISTING="$existing_rps_json" \
    python3 - "${META_PATHS[@]}" <<'PY'
import json, os, sys, yaml

# Layer 1: aggregate from each selected role's meta/install.yml.
merged = {}
for path in sys.argv[1:]:
    try:
        with open(path) as fh:
            meta = yaml.safe_load(fh) or {}
    except Exception:
        continue
    for entry in ((meta.get('side_effects') or {}).get('caddy_reverse_proxy_services') or []):
        sub = entry.get('subdomain')
        if sub:
            merged[sub] = dict(entry)

# Layer 2: existing inventory wins per-subdomain (preserves operator
# port overrides + any hand-added subdomains that don't come from
# meta — e.g. an extra Caddy route in 20-extras.yml that's been
# duplicated into the main reverse_proxy list).
existing_raw = (os.environ.get('EXISTING') or '').strip()
if existing_raw:
    try:
        existing = json.loads(existing_raw)
        if isinstance(existing, list):
            for entry in existing:
                if isinstance(entry, dict):
                    sub = entry.get('subdomain')
                    if sub:
                        merged[sub] = dict(entry)
    except json.JSONDecodeError:
        pass

# Stable order: alphabetical by subdomain. Matches `ls` output for
# anyone diffing the file by hand.
ordered = [merged[k] for k in sorted(merged.keys())]

print(yaml.safe_dump({'caddy_reverse_proxy_services': ordered},
                     default_flow_style=False, sort_keys=False).rstrip())
PY
} > "$HOST_VARS_DIR/10-caddy.yml"

# --- 30-smtp.yml: SMTP relay (whole block optional) ---
if [[ -n "${SMTP_HOST:-}" ]]; then
    {
    cat << YAML
$_split_header
##################################################################################################
### SMTP relay (project-level — used by Nextcloud, Ente, Paperless)
# See docs/SMTP-Setup.md for provider/credential setup + rotation.
smtp_host: "$SMTP_HOST"
smtp_port: $SMTP_PORT
smtp_username: "$SMTP_USERNAME"
smtp_encryption: "$SMTP_ENCRYPTION"
smtp_from: "$SMTP_FROM"
YAML
    vault_encrypt "$SMTP_PASSWORD" "smtp_password"
    } > "$HOST_VARS_DIR/30-smtp.yml"
fi

# --- 40-pihole.yml: Pi-hole core ---
if is_selected pihole; then
    {
    cat << YAML
$_split_header
##################################################################################################
### Pi-hole
pihole_local_network: "$LAN_CIDR"
pihole_local_router: "$LAN_GATEWAY"
YAML
    echo ""
    vault_encrypt "$PIHOLE_PW" "pihole_api_password"
    } > "$HOST_VARS_DIR/40-pihole.yml"
fi

# --- 50-backup.yml: nightly backup to NAS ---
if is_selected backup; then
    {
    cat << YAML
$_split_header
##################################################################################################
### Backup — nightly rsync/tar/pgdump to a LAN NAS via NFS
# See roles/platform/backup/README.md for NAS-side prep (exports + dirs).
backup_nas_hostname: "$backup_nas_hostname"
backup_nas_ip: "$backup_nas_ip"
backup_nas_volume: "$backup_nas_volume"
backup_time: "$backup_time"
YAML
    } > "$HOST_VARS_DIR/50-backup.yml"
fi

# --- apps/music-assistant.yml ---
if is_selected music-assistant; then
    {
    cat << YAML
$_split_header
##################################################################################################
### Music Assistant
# Stable MAC for the built-in Squeezelite player. SlimProto identifies
# players by MAC, so a fixed value keeps the player recognized across
# redeploys.
music_assistant_squeezelite_mac: "$MUSIC_ASSISTANT_MAC"
# On a host without a USB DAC / sound card, set this to false in
# 20-extras.yml to skip the local Squeezelite player container — MA
# server still runs and can drive AirPlay / Cast / external Squeezelite.
# music_assistant_player_enabled: false
YAML
    } > "$APPS_DIR/music-assistant.yml"
fi

# --- apps/entephoto.yml ---
if is_selected entephoto; then
    {
    cat << YAML
$_split_header
##################################################################################################
### Ente Photos
# Public URLs of the Ente services. Without these, the web client
# auto-detects http://<host_ip>:<port> from defaults and pops a
# 'developer settings' dialog at signup. Setting them here makes
# Caddy the canonical entry point and uses real LE certs.
entephoto_api_url: "https://photos-api.${CADDY_DOMAIN}"
entephoto_photos_url: "https://photos.${CADDY_DOMAIN}"
# Caddy reverse-proxies the photos-s3 subdomain on standard 443, so
# the endpoint uses the default https port — both the browser and the
# museum pod hit the same caddy listener that way.
entephoto_s3_endpoint: "photos-s3.${CADDY_DOMAIN}"
entephoto_s3_host: "photos-s3.${CADDY_DOMAIN}"
# false here flips Ente's presigned upload URLs to https://, which
# matches the Caddy-fronted endpoint above and avoids browser
# mixed-content errors.
entephoto_s3_local_buckets: false
YAML
    echo ""
    vault_encrypt "$ENTEPHOTO_DB_PW" "entephoto_db_password"
    echo ""
    vault_encrypt "$ENTEPHOTO_GARAGE_RPC" "entephoto_garage_rpc_secret"
    echo ""
    vault_encrypt "$ENTEPHOTO_GARAGE_ADMIN" "entephoto_garage_admin_token"
    echo ""
    vault_encrypt "$ENTEPHOTO_ENC_KEY" "entephoto_encryption_key"
    echo ""
    vault_encrypt "$ENTEPHOTO_HASH_KEY" "entephoto_hash_key"
    echo ""
    vault_encrypt "$ENTEPHOTO_JWT" "entephoto_jwt_secret"
    echo ""
    echo "entephoto_admin_user_ids: []"
    } > "$APPS_DIR/entephoto.yml"
fi

# --- apps/paperless.yml ---
if is_selected paperless-ngx; then
    {
    cat << YAML
$_split_header
##################################################################################################
### Paperless-NGX
# Public URL of the web UI. Used for absolute-URL generation and as
# the only entry in Django's CSRF trusted origins, so login through
# the Caddy reverse-proxy stops returning 403.
paperless_url: "https://paperless.${CADDY_DOMAIN}"
YAML
    echo ""
    vault_encrypt "$PAPERLESS_SECRET_KEY" "paperless_secret_key"
    echo ""
    vault_encrypt "$PAPERLESS_DB_PW" "paperless_db_password"
    echo ""
    vault_encrypt "$PAPERLESS_ADMIN_PW" "paperless_admin_password"
    } > "$APPS_DIR/paperless.yml"
fi

# --- apps/jellyfin.yml ---
if is_selected jellyfin; then
    {
    cat << YAML
$_split_header
##################################################################################################
### Jellyfin
YAML
    vault_encrypt "$JELLYFIN_ADMIN_PW" "jellyfin_admin_password"
    } > "$APPS_DIR/jellyfin.yml"
fi

# --- apps/nextcloud.yml ---
if is_selected nextcloud; then
    {
    cat << YAML
$_split_header
##################################################################################################
### Nextcloud
YAML
    vault_encrypt "$NEXTCLOUD_ADMIN_PW" "nextcloud_admin_password"
    echo ""
    vault_encrypt "$NEXTCLOUD_DB_PW" "nextcloud_db_password"
    } > "$APPS_DIR/nextcloud.yml"
fi

# Ensure 20-extras.yml exists with a stable header. Operator-managed
# file the tool never touches again — overrides (Pi-hole DNS records,
# Jellyfin NFS mounts, Caddy extras, NAS snapshot trigger config, etc.)
# go here.
if [[ ! -f "$HOST_VARS_DIR/20-extras.yml" ]]; then
    cat > "$HOST_VARS_DIR/20-extras.yml" << 'YAML'
# EDIT FREELY — homeserver.sh never touches this file.
#
# Operator-managed host_vars: anything the install tool does not
# write itself lives here. Add overrides (custom Pi-hole DNS records,
# Jellyfin NFS mounts, Caddy extras, NAS snapshot trigger config, etc.)
# below.
##################################################################################################
YAML
fi

ok "Generated split host_vars under inventory/host_vars/$SERVER_HOSTNAME/ (with vault-encrypted secrets)"

# Dashboard auto-discovers what to render by reading the split host_vars +
# each role's meta/install.yml at generation time; no dashboard-config.yaml
# is written here. See roles/platform/dashboard/README.md.

# ============================================================================
# Step 6.5: deSEC API — upsert A records + clear stale ACME challenge TXT
# ============================================================================
# Writes `*.<sub>.dedyn.io` and `<sub>.dedyn.io` → SERVER_IP so LAN
# clients (Pi-hole) and roaming Tailscale clients both resolve every
# Caddy subdomain to this host's LAN IP. Caddy then issues a wildcard
# LE cert against deSEC's DNS-01 challenge during the deploy below.
# PATCH on the rrset collection is idempotent — safe to re-run.
#
# Also clears `_acme-challenge.<sub>` TXT. Mitigates issue #170:
# Caddy's deSEC plugin occasionally leaves stale TXT records from
# a failed previous order, and the apex + wildcard cert challenges
# race on the same TXT name. Starting from a clean state ensures
# Caddy's first DNS-01 round sees only its own values; sending the
# rrset with records=[] tells deSEC to delete it. No-op if absent.
info "Step 6.5/7: Writing A records + clearing stale _acme-challenge TXT at deSEC..."
api_body=$(cat <<JSON
[
  {"subname":"","type":"A","ttl":3600,"records":["$SERVER_IP"]},
  {"subname":"*","type":"A","ttl":3600,"records":["$SERVER_IP"]},
  {"subname":"_acme-challenge","type":"TXT","ttl":3600,"records":[]}
]
JSON
)
api_resp=$(curl -sS -w "\n%{http_code}" -X PATCH \
    "https://desec.io/api/v1/domains/${DESEC_SUBDOMAIN}.dedyn.io/rrsets/" \
    -H "Authorization: Token $DESEC_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary "$api_body" 2>&1)
api_code=$(echo "$api_resp" | tail -n1)
api_body_resp=$(echo "$api_resp" | head -n -1)
if [[ "$api_code" == "200" ]]; then
    ok "deSEC: ${DESEC_SUBDOMAIN}.dedyn.io and *.${DESEC_SUBDOMAIN}.dedyn.io → $SERVER_IP"
else
    err "deSEC API call failed (HTTP $api_code):"
    echo "$api_body_resp" >&2
    err "Check that the subdomain '$DESEC_SUBDOMAIN' exists in your deSEC account"
    err "and the token has write access. Then re-run homeserver.sh."
    exit 1
fi

# ============================================================================
# Step 7: Deploy selected services
# ============================================================================
echo
echo -e "${BOLD}============================================${NC}"
echo -e "${BOLD}   Ready to deploy!${NC}"
echo -e "${BOLD}============================================${NC}"
echo
echo "The following services will be deployed to this server:"
echo
for svc in "${SELECTED_SERVICES[@]}"; do
    echo "  - $svc"
done
echo
if [[ "$YES_FLAG" == "true" ]]; then
    proceed="y"
    info "Proceeding with deployment (auto-confirmed by -y)."
else
    ask "Proceed with deployment? [Y/n]:"
    read -r proceed
fi
if [[ "$proceed" =~ ^[Nn]$ ]]; then
    echo
    ok "Setup complete! Configuration files generated at:"
    echo "  $INSTALL_DIR/inventory/hosts.yml"
    echo "  $INSTALL_DIR/inventory/host_vars/$SERVER_HOSTNAME/"
    echo
    echo "Deploy manually anytime with:"
    echo "  cd $INSTALL_DIR"
    echo "  ansible-playbook playbooks/site.yml --limit $SERVER_HOSTNAME"
    exit 0
fi

echo

info "Deploying selected services..."
ansible-playbook playbooks/site.yml --limit $SERVER_HOSTNAME
DEPLOY_EXIT=$?

if [[ $DEPLOY_EXIT -ne 0 ]]; then
    warn "Some services may have failed. Check the output above."
    echo "Re-run with: cd $INSTALL_DIR && ansible-playbook playbooks/site.yml --limit $SERVER_HOSTNAME"
fi

# Rootless containers can take a moment to start after the playbook
# finishes (linger user manager + image pulls). Refresh the dashboard
# after a short delay so the first page view reflects real state instead
# of the post-install "all stopped" snapshot.
if is_selected dashboard; then
    info "Refreshing dashboard..."
    sleep 30
    sudo systemctl start home-server-dashboard.service 2>/dev/null || true
fi

# ============================================================================
# Done!
# ============================================================================
echo
echo -e "${BOLD}============================================${NC}"
echo -e "${GREEN}${BOLD}   Setup complete!${NC}"
echo -e "${BOLD}============================================${NC}"
echo
echo "Your home server is now running at: https://${CADDY_DOMAIN}"
echo
echo -e "${BOLD}Back up ${VAULT_PW_FILE} into your password manager now.${NC}"
echo "Without it you cannot re-deploy this host or decrypt its inventory."
echo
echo "Configuration files:"
echo "  $INSTALL_DIR/inventory/host_vars/$SERVER_HOSTNAME/  (split host_vars: 00-services.yml … 60-tailscale.yml, apps/<svc>.yml)"
echo

if [[ -n "${OVERLAY_URL:-}" && "$USE_EXISTING_INVENTORY" != "true" ]]; then
    echo -e "${BOLD}Persist your generated inventory to the overlay repo:${NC}"
    echo "  cd $OVERLAY_DIR"
    echo "  git add -A && git commit -m \"$SERVER_HOSTNAME: initial install\" && git push"
    echo
fi
echo "Container images auto-update daily via podman-auto-update.timer."
echo "See the Quickstart.md for more details."
echo
