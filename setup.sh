#!/bin/bash
# ============================================================================
# Home Server — Interactive Setup Script
#
# Run on a freshly installed RHEL-family host (AlmaLinux 9+, Rocky 9+,
# Fedora Server). Invoke as your non-root sudo user, NOT as root:
#   curl -fsSL https://raw.githubusercontent.com/luckynrslevin/home-server/main/setup.sh \
#     -o /tmp/setup.sh && bash /tmp/setup.sh
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
# setup.sh is a multi-verb CLI. Today only `install` is wired up;
# other verbs ship in later phases (Phase 3-6) of the unified-CLI
# work. No-arg invocation defaults to `install` to preserve the
# Quickstart `curl | bash setup.sh` UX.
VERB="install"
if [[ "${1:-}" =~ ^(install|add|remove|upgrade|backup|restore|uninstall)$ ]]; then
    VERB="$1"
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
Usage: setup.sh [VERB] [flags]

Verbs:
  install      First install or interactive re-install (default).
  add <svc>    Add a service that wasn't deployed before.
  remove       Remove a service. [Phase 6 — not yet wired]
  upgrade      Pull newer images + bump release tag within current major.
  backup       Trigger the backup systemd service now.
  restore      Restore from latest NAS backup.
  uninstall    Full wipe (= scripts/clean-host.sh).

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
  bash setup.sh                              # interactive first install
  bash setup.sh -i git@github.com:you/overlay.git
                                             # first install with overlay URL
  bash setup.sh -y                           # rebuild non-interactive
USAGE
            exit 0
            ;;
        \?) echo "ERROR: unknown flag: -$OPTARG" >&2; exit 1 ;;
        :)  echo "ERROR: flag -$OPTARG requires a value" >&2; exit 1 ;;
    esac
done

# --- Require file execution (not pipe) — install verb only ---
# The install flow has interactive prompts and needs terminal stdin.
# When piped via `curl ... | bash`, stdin is consumed by the stream.
# Detect this and download + run from a file instead.
# Non-install verbs (backup, restore, upgrade, uninstall, add, remove)
# are non-interactive and don't need a tty.
if [[ "$VERB" == "install" && ! -t 0 ]]; then
    SELF_PATH="/tmp/home-server-setup.sh"
    curl -fsSL "https://raw.githubusercontent.com/luckynrslevin/home-server/main/setup.sh" \
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
# previous setup.sh run. Populated by load_existing_inventory() after
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
    err "This user needs passwordless sudo (NOPASSWD:ALL) to run setup.sh."
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
        err "ansible-playbook not on PATH. Run \`setup.sh install\` first."
        exit 1
    fi
}

ensure_install_dir() {
    if [[ ! -d "$INSTALL_DIR" ]]; then
        err "$INSTALL_DIR not found. Run \`setup.sh install\` first."
        exit 1
    fi
}

resolve_target_host() {
    # Use -h flag if given; otherwise system hostname.
    printf '%s' "${HOSTNAME_FLAG:-$(hostname -s)}"
}

case "$VERB" in
    install)
        ;;  # Falls through to Step 1 below.
    backup)
        # The backup is a standalone systemd service deployed by the
        # backup role during `install`. Trigger it via systemctl, not
        # by re-running playbooks/backup.yml (which would only
        # re-deploy the service unit + script, not run a backup).
        if ! systemctl list-unit-files home-server-backup.service &>/dev/null; then
            err "home-server-backup.service not installed. Run \`setup.sh install\` first."
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
        # Bump release tag within the current major if a newer one
        # exists. `major-upgrade` (across majors) deferred to its own
        # later workflow.
        current_tag=$(git describe --tags --exact-match 2>/dev/null || echo "main")
        if [[ "$current_tag" =~ ^v([0-9]+)\..* ]]; then
            major="${BASH_REMATCH[1]}"
            git fetch --tags --quiet || true
            latest_in_major=$(git tag --list "v${major}.*" --sort=-v:refname 2>/dev/null | head -1)
            if [[ -n "$latest_in_major" && "$latest_in_major" != "$current_tag" ]]; then
                info "Bumping release: $current_tag → $latest_in_major"
                git checkout --quiet "$latest_in_major"
            else
                ok "Already on latest v${major}.x release ($current_tag) — refreshing images + ansible state."
            fi
        else
            warn "No release tag pinned (on main). Just re-running ansible against current checkout."
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
    add)
        SERVICE="${1:-}"
        if [[ -z "$SERVICE" ]]; then
            err "Usage: setup.sh add <service>"
            err "Available services:"
            for m in "$INSTALL_DIR"/roles/*/meta/install.yml; do
                svc=$(basename "$(dirname "$(dirname "$m")")")
                desc=$(python3 -c "import yaml; print(yaml.safe_load(open('$m')).get('description',''))" 2>/dev/null)
                printf "  %-18s %s\n" "$svc" "$desc"
            done
            exit 2
        fi
        ensure_install_dir
        ensure_ansible_on_path
        META="$INSTALL_DIR/roles/$SERVICE/meta/install.yml"
        if [[ ! -f "$META" ]]; then
            err "Unknown service '$SERVICE' (no roles/$SERVICE/meta/install.yml)."
            err "Run \`setup.sh add\` with no args to see available services."
            exit 1
        fi
        TARGET=$(resolve_target_host)
        cd "$INSTALL_DIR"
        VAULT_PW_FILE="$HOME/.vaultpw"
        if [[ ! -r "$VAULT_PW_FILE" ]]; then
            err "$VAULT_PW_FILE not readable. Run \`setup.sh install\` first."
            exit 1
        fi
        # Idempotency check: is the service already deployed?
        if ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PW_FILE" \
                ansible-inventory --host "$TARGET" 2>/dev/null \
                | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if '$SERVICE' in (d.get('deploy_services') or []) else 1)"; then
            warn "$SERVICE is already in deploy_services for $TARGET."
            warn "Use \`setup.sh upgrade\` to re-deploy with latest images."
            exit 1
        fi
        # Ensure ruamel.yaml is available for the merge step.
        if ! python3 -c "import ruamel.yaml" 2>/dev/null; then
            info "Installing ruamel.yaml for inventory merge (one-time)..."
            pipx inject ansible-core ruamel.yaml --quiet 2>/dev/null || \
                pip install --user ruamel.yaml >/dev/null
        fi
        info "Resolving inventory updates for $SERVICE from $META..."
        UPDATE_JSON=$(mktemp --suffix=.json)
        # shellcheck disable=SC2064
        trap "rm -f $UPDATE_JSON" EXIT
        if ! python3 scripts/build_add_update.py \
                --meta "$META" \
                --service "$SERVICE" \
                --vault-password-file "$VAULT_PW_FILE" \
                --target-host "$TARGET" \
                --inventory-dir "$INSTALL_DIR/inventory" \
                --output "$UPDATE_JSON"; then
            err "Failed to build update spec for $SERVICE."
            exit 1
        fi
        INV_FILE="$INSTALL_DIR/inventory/host_vars/$TARGET/main.yml"
        info "Merging into $INV_FILE..."
        if ! python3 scripts/inventory_merge.py \
                --inventory "$INV_FILE" \
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
        err "'remove' is not yet wired up. Coming in Phase 6."
        exit 2
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

sudo dnf install -y podman git python3-pyyaml pipx &>/dev/null \
    || sudo dnf install -y podman git python3-pyyaml pipx

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
# happens to be running setup.sh from inside ~/home-server (e.g.
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
# existing host_vars/<hostname>/main.yml. The hostname prompt in
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

    if [[ -f "$OVERLAY_DIR/inventory/host_vars/$SERVER_HOSTNAME/main.yml" ]]; then
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
        # our main.yml uses inline `!vault |` blocks. Extract the first
        # such block, decrypt it standalone, check exit code.
        verify_tmp=$(mktemp)
        python3 - "$OVERLAY_DIR/inventory/host_vars/$SERVER_HOSTNAME/main.yml" > "$verify_tmp" <<'PY'
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
        if [[ -s "$verify_tmp" ]]; then
            if ! ANSIBLE_VAULT_PASSWORD_FILE="$VAULT_PW_FILE" \
                    ansible-vault decrypt --output - "$verify_tmp" &>/dev/null; then
                rm -f "$verify_tmp"
                err "Vault password doesn't decrypt the existing inventory at"
                err "  $OVERLAY_DIR/inventory/host_vars/$SERVER_HOSTNAME/main.yml"
                err "Re-run setup.sh with the correct vault password."
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
roles_path = ./roles:./.ansible/roles:~/.ansible/roles:/usr/share/ansible/roles
stdout_callback = default
host_key_checking = False
vault_password_file = $VAULT_PW_FILE

[ssh_connection]
pipelining = True
use_tty = False
EOF

# Replace the public repo's inventory/ stub with a symlink into the
# overlay so generated (Case 2) or existing (Case 3) inventory lives
# in the overlay repo.
if [[ -n "$OVERLAY_URL" ]]; then
    if [[ ! -L inventory ]]; then
        rm -rf inventory
        ln -s "$OVERLAY_DIR/inventory" inventory
        ok "Symlinked inventory/ → $OVERLAY_DIR/inventory"
    fi
fi

info "Step 5/7: Configuring your server..."

# Load existing inventory (if any) so every prompt below can default
# from its previous value. Decrypts vault blocks in the dict.
if [[ -f "inventory/host_vars/$SERVER_HOSTNAME/main.yml" ]]; then
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
    [pihole]="Pi-hole DNS ad-blocker"
    [entephoto]="Ente Photos (self-hosted photo storage)"
    [paperless-ngx]="Paperless-NGX document management (OCR + search)"
    [syncthing]="Syncthing file synchronization"
    [shairportsync]="Shairport-sync AirPlay audio receiver (needs audio device)"
    [jellyfin]="Jellyfin media server (movies, TV, music)"
    [music-assistant]="Music Assistant music server (optional local Squeezelite player on hosts with a USB DAC)"
)

SELECTED_SERVICES=(caddy nextcloud)

SERVICE_ORDER=(dashboard pihole entephoto paperless-ngx syncthing shairportsync jellyfin music-assistant)
declare -A SERVICE_DEFAULT_YES=(
    [dashboard]=1
    [pihole]=1
    [entephoto]=1
    [paperless-ngx]=1
)

# If inventory has a deploy_services list, prefer it: a service is
# defaulted Y iff it's in the existing list.
EXISTING_DEPLOY_SERVICES=$(inv_get deploy_services)
declare -A INV_DEPLOY=()
if [[ -n "$EXISTING_DEPLOY_SERVICES" ]]; then
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && INV_DEPLOY[$svc]=1
    done < <(echo "$EXISTING_DEPLOY_SERVICES" | python3 -c "import json,sys; print('\n'.join(json.load(sys.stdin)))")
fi

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
resolve_secret ENTEPHOTO_MINIO_PW   entephoto_minio_password    rand -base64 24
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

# Build the host_vars file
{
cat << YAML
##################################################################################################
### Host identity
# Pin the system hostname so os-base never renames the box on a
# re-deploy (the role's default would be inventory_hostname).
os_base_hostname: $SERVER_HOSTNAME

# home-server release pinned for this host. Used by setup.sh to
# decide which tag to check out on rebuild + add-service flows
# (so an `add` doesn't accidentally pull in a different major).
# Override at install time with \`setup.sh -r <tag>\`.
home_server_release: $HOME_SERVER_RELEASE

##################################################################################################
### Services to deploy on this host (used by playbooks/site.yml)
deploy_services:
YAML

for svc in "${SELECTED_SERVICES[@]}"; do
    echo "  - $svc"
done

cat << YAML

##################################################################################################
### Linux users — service accounts with fixed UIDs
YAML

# If inventory already has my_linux_users, emit that block verbatim
# (preserves operator additions like extra service accounts).
# Otherwise emit the canonical UID map.
existing_users=$(inv_get my_linux_users)
if [[ -n "$existing_users" ]]; then
    echo "$existing_users" | python3 -c "
import json, sys, yaml
d = json.load(sys.stdin)
print(yaml.safe_dump({'my_linux_users': d}, default_flow_style=False, sort_keys=False).rstrip())
"
else
    cat << YAML
my_linux_users:
  $SERVER_USER:
    uid: 1000
    gid: 1000
  shairport:
    uid: 1001
    gid: 1001
  syncthg:
    uid: 1003
    gid: 1003
  pihole:
    uid: 1005
    gid: 1005
  entephoto:
    uid: 1008
    gid: 1008
  paperless:
    uid: 1007
    gid: 1007
  jellyfin:
    uid: 1012
    gid: 1012
  webproxy:
    uid: 1011
    gid: 1011
  music-assistant:
    uid: 1014
    gid: 1014
  nextcloud:
    uid: 1015
    gid: 1015
YAML
fi

cat << YAML
##################################################################################################

### Caddy reverse-proxy + Let's Encrypt via deSEC DNS-01
caddy_domain: "$CADDY_DOMAIN"
caddy_acme_provider: "desec"
caddy_acme_subdomain: "$DESEC_SUBDOMAIN"
YAML

echo ""
vault_encrypt "$DESEC_TOKEN" "caddy_acme_token"
echo ""

# caddy_reverse_proxy_services: prefer existing inventory block if
# present (preserves operator port overrides / hand-added services);
# otherwise emit canonical entries for the selected services.
existing_rps=$(inv_get caddy_reverse_proxy_services)
if [[ -n "$existing_rps" ]]; then
    echo "$existing_rps" | python3 -c "
import json, sys, yaml
d = json.load(sys.stdin)
print(yaml.safe_dump({'caddy_reverse_proxy_services': d}, default_flow_style=False, sort_keys=False).rstrip())
"
else
    echo "caddy_reverse_proxy_services:"
    is_selected pihole       && echo '  - { subdomain: pihole, port: 8443, proto: https }'
    is_selected syncthing    && echo '  - { subdomain: syncthing, port: 8384, proto: https }'
    if is_selected entephoto; then
      echo '  - { subdomain: photos, port: 3000 }'
      echo '  - { subdomain: accounts, port: 3001 }'
      echo '  - { subdomain: cast, port: 3002 }'
      echo '  - { subdomain: auth, port: 3003 }'
      echo '  - { subdomain: photos-api, port: 8080 }'
      echo '  - { subdomain: photos-s3, port: 3200 }'
    fi
    is_selected paperless-ngx   && echo '  - { subdomain: paperless, port: 8000 }'
    is_selected jellyfin        && echo '  - { subdomain: jellyfin, port: 8096 }'
    is_selected music-assistant && echo '  - { subdomain: music, port: 8095 }'
    is_selected nextcloud       && echo '  - { subdomain: cloud, port: 8090 }'
fi
echo ""

cat << YAML

### Pi-hole
pihole_local_network: "$LAN_CIDR"
pihole_local_router: "$LAN_GATEWAY"
YAML

echo ""
vault_encrypt "$PIHOLE_PW" "pihole_api_password"
echo ""
echo "### Music Assistant"
echo "# Stable MAC for the built-in Squeezelite player. SlimProto"
echo "# identifies players by MAC, so a fixed value keeps the player"
echo "# recognized across redeploys."
echo "music_assistant_squeezelite_mac: \"$MUSIC_ASSISTANT_MAC\""
echo "# On a host without a USB DAC / sound card, set this to false to"
echo "# skip the local Squeezelite player container — MA server still"
echo "# runs and can drive AirPlay / Cast / external Squeezelite."
echo "# music_assistant_player_enabled: false"
echo ""
echo "### Ente Photos"
echo "# Public URLs of the Ente services. Without these, the web client"
echo "# auto-detects http://<host_ip>:<port> from defaults and pops a"
echo "# 'developer settings' dialog at signup. Setting them here makes"
echo "# Caddy the canonical entry point and uses real LE certs."
echo "entephoto_api_url: \"https://photos-api.${CADDY_DOMAIN}\""
echo "entephoto_photos_url: \"https://photos.${CADDY_DOMAIN}\""
echo "# Port 9443 is intentional. Caddy's rootless quadlet publishes"
echo "# :9443 (only :80 / :443 are NAT'd in the host firewall, and that"
echo "# NAT only fires for inbound LAN traffic). Pod-to-host traffic"
echo "# from museum can ONLY reach the host at the high-numbered"
echo "# pasta-published ports. Browser uses the same URL — port 9443"
echo "# is open on the LAN too, so it works from both vantage points."
echo "entephoto_s3_endpoint: \"photos-s3.${CADDY_DOMAIN}:9443\""
echo "entephoto_s3_host: \"photos-s3.${CADDY_DOMAIN}\""
echo "# false here flips Ente's presigned upload URLs to https://, which"
echo "# matches the Caddy-fronted endpoint above and avoids browser"
echo "# mixed-content errors."
echo "entephoto_s3_local_buckets: false"
echo ""
vault_encrypt "$ENTEPHOTO_DB_PW" "entephoto_db_password"
echo ""
vault_encrypt "$ENTEPHOTO_MINIO_PW" "entephoto_minio_password"
echo ""
vault_encrypt "$ENTEPHOTO_ENC_KEY" "entephoto_encryption_key"
echo ""
vault_encrypt "$ENTEPHOTO_HASH_KEY" "entephoto_hash_key"
echo ""
vault_encrypt "$ENTEPHOTO_JWT" "entephoto_jwt_secret"
echo ""
echo "entephoto_admin_user_ids: []"
echo ""
echo "### Paperless-NGX"
echo "# Public URL of the web UI. Used for absolute-URL generation"
echo "# and as the only entry in Django's CSRF trusted origins,"
echo "# so login through the Caddy reverse-proxy stops returning 403."
echo "paperless_url: \"https://paperless.${CADDY_DOMAIN}\""
echo ""
vault_encrypt "$PAPERLESS_SECRET_KEY" "paperless_secret_key"
echo ""
vault_encrypt "$PAPERLESS_DB_PW" "paperless_db_password"
echo ""
vault_encrypt "$PAPERLESS_ADMIN_PW" "paperless_admin_password"
echo ""
echo "### Jellyfin"
vault_encrypt "$JELLYFIN_ADMIN_PW" "jellyfin_admin_password"

if is_selected nextcloud; then
    echo ""
    echo "### Nextcloud"
    vault_encrypt "$NEXTCLOUD_ADMIN_PW" "nextcloud_admin_password"
    echo ""
    vault_encrypt "$NEXTCLOUD_DB_PW" "nextcloud_db_password"
fi

if [[ -n "${SMTP_HOST:-}" ]]; then
    echo ""
    echo "### SMTP relay (project-level — used by Nextcloud, Ente, Paperless)"
    echo "# See docs/SMTP-Setup.md for provider/credential setup + rotation."
    echo "smtp_host: \"$SMTP_HOST\""
    echo "smtp_port: $SMTP_PORT"
    echo "smtp_username: \"$SMTP_USERNAME\""
    echo "smtp_encryption: \"$SMTP_ENCRYPTION\""
    echo "smtp_from: \"$SMTP_FROM\""
    vault_encrypt "$SMTP_PASSWORD" "smtp_password"
fi
echo "##################################################################################################"
} > inventory/host_vars/$SERVER_HOSTNAME/main.yml

ok "Generated inventory/host_vars/$SERVER_HOSTNAME/main.yml (with vault-encrypted secrets)"

# --- Generate dashboard config ---
# Only include services that were actually selected for deployment, so
# the dashboard doesn't display stale "Stopped" rows for un-deployed
# services.

{
echo "services:"

if is_selected shairportsync; then
cat << EOF
  - name: Shairport-sync
    user: root
    service: shairport-sync
    rootful: true
    volumes: []

EOF
fi

if is_selected pihole; then
cat << EOF
  - name: Pi-hole
    user: pihole
    uid: 1005
    service: pihole
    urls:
      - label: Admin UI
        url: https://pihole.${CADDY_DOMAIN}/admin
    volumes:
      - systemd-pihole-etc
      - systemd-pihole-dnsmasq

EOF
fi

if is_selected syncthing; then
cat << EOF
  - name: Syncthing
    user: syncthg
    uid: 1003
    service: syncthing
    urls:
      - label: Web UI
        url: https://syncthing.${CADDY_DOMAIN}
    volumes:
      - systemd-syncthing

EOF
fi

if is_selected entephoto; then
cat << EOF
  - name: Ente Photos
    user: entephoto
    uid: 1008
    service: entephoto-pod
    urls:
      - label: Photos
        url: https://photos.${CADDY_DOMAIN}
      - label: API
        url: https://photos-api.${CADDY_DOMAIN}/ping
    volumes:
      - entephoto-postgres-data
      - entephoto-minio-data
      - entephoto-museum-config

EOF
fi

if is_selected paperless-ngx; then
cat << EOF
  - name: Paperless-NGX
    user: paperless
    uid: 1007
    service: paperless-ngx-pod
    urls:
      - label: Web UI
        url: https://paperless.${CADDY_DOMAIN}
    volumes:
      - paperless-db-data
      - paperless-media
      - paperless-data

EOF
fi

if is_selected jellyfin; then
cat << EOF
  - name: Jellyfin
    user: jellyfin
    uid: 1012
    service: jellyfin
    urls:
      - label: Web UI
        url: https://jellyfin.${CADDY_DOMAIN}
    volumes:
      - jellyfin-config
      - jellyfin-media

EOF
fi

if is_selected music-assistant; then
cat << EOF
  - name: Music Assistant
    user: music-assistant
    uid: 1014
    service: music-assistant-pod
    urls:
      - label: Web UI
        url: https://music.${CADDY_DOMAIN}
    volumes:
      - music-assistant-data

EOF
fi

if is_selected nextcloud; then
cat << EOF
  - name: Nextcloud
    user: nextcloud
    uid: 1015
    service: nextcloud-pod
    urls:
      - label: Web UI
        url: https://cloud.${CADDY_DOMAIN}
    volumes:
      - nextcloud-config
      - nextcloud-data

EOF
fi
} > inventory/host_vars/$SERVER_HOSTNAME/dashboard-config.yaml

ok "Generated inventory/host_vars/$SERVER_HOSTNAME/dashboard-config.yaml"

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
    err "and the token has write access. Then re-run setup.sh."
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
echo "  $INSTALL_DIR/inventory/host_vars/$SERVER_HOSTNAME/main.yml"
echo "  $INSTALL_DIR/inventory/host_vars/$SERVER_HOSTNAME/dashboard-config.yaml"
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
