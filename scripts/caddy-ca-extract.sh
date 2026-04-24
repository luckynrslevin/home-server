#!/usr/bin/env bash
# ============================================================================
# caddy-ca-extract.sh
#
# One-shot helper: pulls Caddy's auto-generated internal ACME CA (root +
# intermediate cert/key) out of a running caddy container and writes the
# four files into a staging directory. Run this once, on the host where
# caddy is already running and has generated its CA, then vault-encrypt
# the two .key files and commit them into the home-server-private overlay
# so the CA can be re-seeded on reinstall.
#
# Usage:
#   ./scripts/caddy-ca-extract.sh [output_dir]
#
# Defaults to /tmp/caddy-ca-<timestamp>/.
# ============================================================================
set -euo pipefail

OUT_DIR="${1:-/tmp/caddy-ca-$(date +%Y%m%d-%H%M%S)}"
CONTAINER="caddy"
USER_NAME="webproxy"
SRC_DIR="/data/caddy/pki/authorities/local"

mkdir -p "$OUT_DIR"
chmod 0700 "$OUT_DIR"

for f in root.crt root.key intermediate.crt intermediate.key; do
    sudo -iu "$USER_NAME" podman exec "$CONTAINER" cat "$SRC_DIR/$f" > "$OUT_DIR/$f"
    chmod 0600 "$OUT_DIR/$f"
done
chmod 0644 "$OUT_DIR/root.crt" "$OUT_DIR/intermediate.crt"

echo
echo "Extracted Caddy internal CA to: $OUT_DIR"
ls -l "$OUT_DIR"
echo
echo "Next steps:"
echo "  1. Vault-encrypt the two private keys:"
echo "       ansible-vault encrypt $OUT_DIR/root.key $OUT_DIR/intermediate.key"
echo
echo "  2. Copy all four files into home-server-private at:"
echo "       roles/caddy/files/volumes/caddy-data/caddy/pki/authorities/local/"
echo
echo "  3. Add the symlinks in home-server (see roles/caddy/README.md)."
echo
echo "  4. In your host_vars, set:  caddy_seed_internal_ca: true"
echo
echo "  5. Redeploy caddy and verify the root.crt fingerprint is unchanged."
