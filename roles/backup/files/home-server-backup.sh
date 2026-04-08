#!/bin/bash
set -euo pipefail

# ===========================================================================
# Home Server Backup Script
# Standalone backup — runs autonomously via systemd timer.
# No Ansible dependency at runtime.
#
# Three backup methods:
#   - tar:    podman volume export → gzipped tar (with daily retention)
#   - rsync:  rsync volume mount path (current mirror, no history)
#   - pgdump: pg_dump logical database backup (with daily retention)
#
# Mount/unmount lifecycle:
#   If MOUNT_DEV is set, the backup target is mounted before backup
#   and unmounted on exit (even on failure).
# ===========================================================================

# --- Configuration ---
BACKUP_DIR="/mnt/backup"
MOUNT_DEV=""                        # e.g. "nas:/backups/homeserver" (empty = no mount)
MOUNT_TYPE="nfs"
MOUNT_OPTS="noatime,soft,timeo=30"
RETENTION_DAYS=7
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ERRORS=0

# --- Ensure backup dir exists before logging ---
mkdir -p "$BACKUP_DIR"
LOG_FILE="$BACKUP_DIR/backup.log"

# --- Logging ---
log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2; ERRORS=$((ERRORS+1)); }

# --- Mount/unmount ---
if [ -n "$MOUNT_DEV" ]; then
  log "Mounting $MOUNT_DEV on $BACKUP_DIR"
  mount -t "$MOUNT_TYPE" -o "$MOUNT_OPTS" "$MOUNT_DEV" "$BACKUP_DIR" \
    || { log_error "Mount failed, aborting backup"; exit 1; }
  trap "log 'Unmounting $BACKUP_DIR'; umount '$BACKUP_DIR'" EXIT
fi

log "=== Backup started ==="

# --- Service helpers ---
stop_service() {
  local user=$1 uid=$2 service=$3
  log "  Stopping $service (user=$user)"
  sudo -u "$user" XDG_RUNTIME_DIR=/run/user/"$uid" \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/"$uid"/bus \
    systemctl --user stop "$service" 2>>"$LOG_FILE" || log_error "Failed to stop $service"
}

start_service() {
  local user=$1 uid=$2 service=$3
  log "  Starting $service (user=$user)"
  sudo -u "$user" XDG_RUNTIME_DIR=/run/user/"$uid" \
    DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/"$uid"/bus \
    systemctl --user start "$service" 2>>"$LOG_FILE" || log_error "Failed to start $service"
}

# --- Backup functions ---
backup_tar_volume() {
  local user=$1 uid=$2 volume=$3
  local dest="$BACKUP_DIR/tar/$volume"
  mkdir -p "$dest"
  log "  Tar backup: $volume"
  if su - "$user" -c "podman volume export $volume" \
    | gzip > "$dest/${volume}-${TIMESTAMP}.tar.gz"; then
    chmod 644 "$dest/${volume}-${TIMESTAMP}.tar.gz"
    log "  Tar backup: $volume done ($(du -sh "$dest/${volume}-${TIMESTAMP}.tar.gz" | cut -f1))"
  else
    log_error "Tar export failed for $volume"
    rm -f "$dest/${volume}-${TIMESTAMP}.tar.gz"
    return 1
  fi
  # Retention: remove old backups
  find "$dest" -name "*.tar.gz" -mtime +"$RETENTION_DAYS" -delete
}

backup_rsync_volume() {
  local user=$1 uid=$2 volume=$3
  local mount_path
  if ! mount_path=$(su - "$user" -c "podman volume inspect $volume --format={{.Mountpoint}}"); then
    log_error "Cannot inspect volume $volume"
    return 1
  fi
  local dest="$BACKUP_DIR/rsync/$volume"
  mkdir -p "$dest"
  log "  Rsync backup: $volume"
  if rsync -a --delete "$mount_path/" "$dest/" 2>>"$LOG_FILE"; then
    log "  Rsync backup: $volume done ($(du -sh "$dest" | cut -f1))"
  else
    log_error "Rsync failed for $volume"
    return 1
  fi
}

backup_pgdump() {
  local user=$1 container=$2 db_user=$3 db_name=$4
  local dest="$BACKUP_DIR/tar/pgdump-$container"
  mkdir -p "$dest"
  log "  pg_dump: $container ($db_name)"
  if su - "$user" -c "podman exec $container pg_dump -U $db_user $db_name" \
    | gzip > "$dest/${container}-${TIMESTAMP}.sql.gz"; then
    chmod 644 "$dest/${container}-${TIMESTAMP}.sql.gz"
    log "  pg_dump: $container done ($(du -sh "$dest/${container}-${TIMESTAMP}.sql.gz" | cut -f1))"
  else
    log_error "pg_dump failed for $container"
    rm -f "$dest/${container}-${TIMESTAMP}.sql.gz"
    return 1
  fi
  # Retention: remove old backups
  find "$dest" -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
}

# =======================================================================
# Backup definitions per service
# =======================================================================

# === Pi-hole ===
log "--- Pi-hole ---"
stop_service pihole 1005 pihole
backup_tar_volume pihole 1005 systemd-pihole-etc
backup_tar_volume pihole 1005 systemd-pihole-dnsmasq
start_service pihole 1005 pihole

# === Samba ===
log "--- Samba ---"
stop_service samba 1010 samba
backup_rsync_volume samba 1010 systemd-samba-data
start_service samba 1010 samba

# === Syncthing ===
log "--- Syncthing ---"
stop_service syncthg 1003 syncthing
backup_tar_volume syncthg 1003 systemd-syncthing-config
backup_rsync_volume syncthg 1003 systemd-syncthing-data
start_service syncthg 1003 syncthing

# === Jukebox ===
log "--- Jukebox ---"
stop_service jukebox 1006 jukebox-pod
backup_tar_volume jukebox 1006 jukebox-server-config
backup_tar_volume jukebox 1006 jukebox-server-playlist
backup_rsync_volume jukebox 1006 jukebox-server-music
start_service jukebox 1006 jukebox-pod

# === Ente Photos ===
log "--- Ente Photos ---"
# pg_dump runs while service is up (consistent logical snapshot)
backup_pgdump entephoto entephoto-postgres pguser ente_db
# Stop pod for volume backups
stop_service entephoto 1008 entephoto-pod
backup_tar_volume entephoto 1008 entephoto-museum-config
backup_rsync_volume entephoto 1008 entephoto-minio-data
start_service entephoto 1008 entephoto-pod

# =======================================================================
log "=== Backup finished ($ERRORS errors) ==="
[ "$ERRORS" -eq 0 ] || exit 1
