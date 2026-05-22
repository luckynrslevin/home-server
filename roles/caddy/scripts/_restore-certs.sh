#!/usr/bin/env bash
# Restore Caddy's cert tree from the most recent caddy-data tarball.
#
# Why a narrow helper instead of the generic restore: caddy-data also
# contains runtime state Caddy regenerates from inventory on every
# deploy, so a full-volume restore would silently revert fresh config.
# This script touches *only* /data/caddy/certificates/ — the LE certs
# and ACME account keys — leaving everything else alone.
set -euo pipefail

DRY_RUN=false
FROM=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --from) FROM="$2"; shift 2 ;;
        *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
    esac
done

info() { printf '==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (invoke via 'homeserver.sh caddy restore-certs')"

# Pull NAS coords from the deployed backup script so we don't duplicate
# inventory plumbing here.
BACKUP_SCRIPT=/usr/local/bin/home-server-backup.sh
[[ -f $BACKUP_SCRIPT ]] || die "no $BACKUP_SCRIPT — has the backup role been deployed?"

NAS_HOST=$(grep -m1 '^NAS_HOST=' "$BACKUP_SCRIPT" | cut -d'"' -f2)
NAS_VOLUME=$(grep -m1 '^NAS_VOLUME=' "$BACKUP_SCRIPT" | cut -d'"' -f2)
HOSTNAME_DIR=$(grep -m1 '^HOSTNAME_DIR=' "$BACKUP_SCRIPT" | cut -d'"' -f2)
[[ -n $NAS_HOST && -n $NAS_VOLUME && -n $HOSTNAME_DIR ]] \
    || die "failed to parse NAS coords from $BACKUP_SCRIPT"

# Mount the backup-tar share read-only.
MOUNT=/mnt/restore-caddy
mkdir -p "$MOUNT"
trap 'umount "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true' EXIT

info "Mounting $NAS_HOST:$NAS_VOLUME/backup-tar (ro) at $MOUNT"
mount -t nfs -o "ro,noatime,hard,_netdev,vers=4" \
    "$NAS_HOST:$NAS_VOLUME/backup-tar" "$MOUNT"

# Pick the tarball.
TAR_DIR="$MOUNT/$HOSTNAME_DIR/caddy-data"
[[ -d $TAR_DIR ]] || die "no caddy-data backups for $HOSTNAME_DIR at $TAR_DIR"

if [[ -z $FROM ]]; then
    FROM=$(ls -1t "$TAR_DIR"/caddy-data-*.tar.gz 2>/dev/null | head -n1)
    [[ -n $FROM ]] || die "no caddy-data-*.tar.gz found in $TAR_DIR"
fi
info "Source tarball: $FROM"

# Extract just the cert tree to a tmp dir.
SCRATCH=$(mktemp -d)
trap 'umount "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

info "Extracting caddy/certificates/ to $SCRATCH"
# podman volume export tars the _data/ contents flat — so /caddy/... at root.
tar -xzf "$FROM" -C "$SCRATCH" caddy/certificates || \
    die "tar extract failed — does the tar contain caddy/certificates/?"

[[ -d "$SCRATCH/caddy/certificates" ]] || die "extracted tree missing caddy/certificates/"

# Report what we found — issuer + expiry of any leaf cert.
info "Restored cert summary:"
find "$SCRATCH/caddy/certificates" -name '*.crt' -not -path '*/users/*' | while read -r crt; do
    subj=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | sed 's/^subject=//')
    iss=$(openssl x509 -in "$crt" -noout -issuer  2>/dev/null | sed 's/^issuer=//')
    end=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
    printf '    %s\n      issuer: %s\n      expires: %s\n' "$subj" "$iss" "$end"
done

if $DRY_RUN; then
    info "DRY RUN — not touching the live volume"
    exit 0
fi

# Splice into the live volume. webproxy is the rootless user that owns Caddy.
LIVE=$(su - webproxy -c "podman volume inspect caddy-data --format '{{.Mountpoint}}'") \
    || die "caddy-data volume not present — has the caddy role been deployed?"
info "Target volume: $LIVE"

WEBPROXY_UID=$(id -u webproxy)
WEBPROXY_GID=$(id -g webproxy)

info "Stopping caddy.service"
sudo -u webproxy XDG_RUNTIME_DIR="/run/user/$WEBPROXY_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$WEBPROXY_UID/bus" \
    systemctl --user stop caddy.service || true

# Hand the scratch dir to webproxy so it's visible inside the user
# namespace, then run rsync from inside that namespace. Files end up
# owned by container-root (= host webproxy), matching what Caddy
# wrote originally — no separate chown pass needed, and we avoid
# the host-root-owned files → namespace-nobody trap that a plain
# `rsync` followed by `podman unshare chown` falls into.
info "Rsyncing certificates/ into live volume (via podman unshare)"
chown -R webproxy:webproxy "$SCRATCH"
mkdir -p "$LIVE/caddy"
# Self-heal: if a prior failed run left certificates/ owned by host
# root, webproxy can't even read into it from inside its namespace.
# Reclaim ownership so the rsync receiver can do its work.
if [[ -d "$LIVE/caddy/certificates" ]]; then
    chown -R webproxy:webproxy "$LIVE/caddy/certificates"
fi
# --delete scoped to the certificates subdir — leaves locks/, ocsp/
# etc. untouched so Caddy regenerates them naturally on restart.
su - webproxy -c "podman unshare rsync -a --delete \
    '$SCRATCH/caddy/certificates/' '$LIVE/caddy/certificates/'"

info "Starting caddy.service"
sudo -u webproxy XDG_RUNTIME_DIR="/run/user/$WEBPROXY_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$WEBPROXY_UID/bus" \
    systemctl --user start caddy.service

# Best-effort liveness check.
for _ in 1 2 3 4 5; do
    sleep 1
    state=$(sudo -u webproxy XDG_RUNTIME_DIR="/run/user/$WEBPROXY_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$WEBPROXY_UID/bus" \
        systemctl --user is-active caddy.service 2>/dev/null || true)
    [[ $state == active ]] && break
done
info "caddy.service state: ${state:-unknown}"

# Detect CA mismatch: Caddy stores certs under a CA-named subdir
# (e.g. certificates/acme-v02.api.letsencrypt.org-directory/ for LE
# prod). If the running Caddyfile points at a different CA, the
# restored cert sits in storage but is never served — Caddy goes to
# the configured CA for a fresh issuance instead. Warn loudly here
# so the operator knows the cert restore alone won't make Firefox
# happy without an inventory flip + redeploy.
restored_ca_dirs=$(find "$LIVE/caddy/certificates" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -u)
caddyfile=$(find "$LIVE/../" -maxdepth 4 -name Caddyfile 2>/dev/null | head -n1)
if [[ -z $caddyfile ]]; then
    # caddy-etc lives in a sibling volume; look it up by name.
    caddyfile=$(su - webproxy -c "podman volume inspect caddy-etc --format '{{.Mountpoint}}'" 2>/dev/null)/Caddyfile
fi

configured_ca=""
if [[ -r $caddyfile ]]; then
    ca_url=$(grep -E '^\s*acme_ca\s+' "$caddyfile" | awk '{print $2}' | head -n1)
    case "$ca_url" in
        *acme-staging-v02*) configured_ca="acme-staging-v02.api.letsencrypt.org-directory" ;;
        ""|*acme-v02*)      configured_ca="acme-v02.api.letsencrypt.org-directory" ;;
        *)                  configured_ca="(custom: $ca_url)" ;;
    esac
fi

if [[ -n $configured_ca && -n $restored_ca_dirs ]] \
   && ! grep -qx "$configured_ca" <<<"$restored_ca_dirs"; then
    printf '\n'
    printf '!! CA MISMATCH — restored cert will NOT be served by Caddy as-is.\n'
    printf '   Restored cert(s) live under: %s\n' "$restored_ca_dirs" | tr '\n' ' '; printf '\n'
    printf '   Caddy is currently configured for: %s\n' "$configured_ca"
    printf '\n'
    printf '   To use the restored cert, point Caddy at the matching CA in inventory:\n'
    if [[ "$configured_ca" == *staging* ]]; then
        printf '     - edit  ~/<home-server-private>/inventory/host_vars/%s/main.yml\n' "$HOSTNAME_DIR"
        printf '     - comment out the caddy_acme_ca line (defaults to LE production)\n'
    else
        printf '     - edit  ~/<home-server-private>/inventory/host_vars/%s/main.yml\n' "$HOSTNAME_DIR"
        printf '     - set     caddy_acme_ca: "https://%s/directory"\n' "${restored_ca_dirs%-directory}" | sed 's/acme-/acme-/'
    fi
    printf '     - then    ansible-playbook playbooks/caddy.yml --limit %s\n' "$HOSTNAME_DIR"
    printf '\n'
    printf '   Without that step, Caddy will request a new cert from its currently-\n'
    printf '   configured CA on next startup and the restored cert stays idle.\n'
fi

info "Done."
