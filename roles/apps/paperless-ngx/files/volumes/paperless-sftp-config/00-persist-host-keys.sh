#!/bin/bash
# Persist SSH host keys across container recreations.
#
# Podman quadlets recreate the container on every restart (e.g., image
# auto-update, config change). atmoz/sftp's entrypoint generates fresh
# ssh_host_*_key pairs on any start where /etc/ssh/ssh_host_*_key is
# missing — which happens every time the container's rootfs is fresh.
# That rotates the server's host identity and makes the scanner fail
# with "authentication error" because the stored fingerprint no longer
# matches.
#
# Fix: keep the host keys in a persistent volume mounted at
# /etc/ssh-persistent. On first ever start, seed that volume with the
# freshly-generated keys. On subsequent starts, copy the persisted keys
# back into /etc/ssh/ BEFORE sshd launches — sshd then presents the
# same host identity as on the first run.
#
# /etc/sftp.d/*.sh scripts execute after atmoz/sftp's key generation
# but before `exec sshd`, so this is the right moment to swap keys in.
set -eu
PERSIST_DIR=/etc/ssh-persistent
mkdir -p "$PERSIST_DIR"

# Seed persistent dir on first start
if ! ls "$PERSIST_DIR"/ssh_host_*_key >/dev/null 2>&1; then
  echo "[00-persist-host-keys] Seeding persistent host-key store"
  cp -p /etc/ssh/ssh_host_*_key "$PERSIST_DIR"/
  cp -p /etc/ssh/ssh_host_*_key.pub "$PERSIST_DIR"/
fi

# Overwrite /etc/ssh/ with persisted keys so sshd presents stable identity
echo "[00-persist-host-keys] Installing persisted host keys into /etc/ssh/"
cp -p "$PERSIST_DIR"/ssh_host_*_key /etc/ssh/
cp -p "$PERSIST_DIR"/ssh_host_*_key.pub /etc/ssh/
chmod 600 /etc/ssh/ssh_host_*_key
chmod 644 /etc/ssh/ssh_host_*_key.pub
