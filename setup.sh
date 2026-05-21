#!/usr/bin/env bash
# Deprecated entry point — renamed to homeserver.sh. Shim kept for one
# release so the curl-pipe Quickstart URL keeps working. Remove after.
echo "==> NOTE: setup.sh has been renamed to homeserver.sh. This shim will be removed in the next release." >&2
exec bash "$(dirname "$0")/homeserver.sh" "$@"
