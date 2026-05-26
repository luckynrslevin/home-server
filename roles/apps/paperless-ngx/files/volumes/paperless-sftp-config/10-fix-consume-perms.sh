#!/bin/bash
# Re-fix ownership on the paperless-consume volume mount point after
# atmoz/sftp's chroot-setup chown clobbered it.
#
# atmoz/sftp's entrypoint enforces root:root 0755 on /home/<user>/ for
# OpenSSH chroot, and also chowns each direct subdir of the home to the
# SFTP user. That chown goes through the bind mount and rewrites the
# underlying paperless-consume volume to root-owned 0755, which breaks
# paperless-ngx's write access to its own consume directory.
#
# The SFTP user and the paperless container user are both UID 1000
# inside their respective containers and both map to the SAME host-side
# subuid (they share the rootless user namespace). So chowning to 1000
# satisfies both containers; paperless reads/writes normally, scanner
# reads/writes normally.
#
# /etc/sftp.d/*.sh scripts run after atmoz/sftp's setup and before sshd.
set -eu
SCAN_DIR="/home/paperless-scanner/scan"
if [ -d "$SCAN_DIR" ]; then
  chown 1000:1000 "$SCAN_DIR"
  chmod 0755 "$SCAN_DIR"
fi
