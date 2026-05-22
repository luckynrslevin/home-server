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

mkdir -p "$LIVE/caddy"
info "Rsyncing certificates/ into live volume"
# --delete scoped to the certificates subdir — leaves locks/, ocsp/ etc.
# untouched so Caddy regenerates them naturally on restart.
rsync -a --delete \
    "$SCRATCH/caddy/certificates/" "$LIVE/caddy/certificates/"

# Inside the container, files must be owned by root (uid 0) which maps
# to the rootless webproxy uid on the host. Use podman unshare to chown
# across the user namespace — same pattern as playbooks/tasks/restore_generic.yml.
info "Re-owning restored tree inside webproxy's user namespace"
su - webproxy -c "podman unshare chown -R 0:0 '$LIVE/caddy/certificates'"

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
info "Done."
