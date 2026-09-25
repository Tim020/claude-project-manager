#!/usr/bin/env bash
# Run the core test suite inside the official Swift Linux image.
# Useful when working on a machine without a local Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${SWIFT_IMAGE:-swift:6.1-noble}"
# Pass through an HTTPS proxy / CA bundle if the host uses one (for package resolution).
PROXY_ARGS=()
for var in HTTPS_PROXY HTTP_PROXY https_proxy http_proxy NO_PROXY no_proxy; do
  [ -n "${!var:-}" ] && PROXY_ARGS+=(-e "$var")
done
if [ -n "${SSL_CERT_FILE:-}" ] && [ -f "$SSL_CERT_FILE" ]; then
  PROXY_ARGS+=(-v "$SSL_CERT_FILE:/etc/ssl/certs/host-ca.pem:ro" -e SSL_CERT_FILE=/etc/ssl/certs/host-ca.pem -e GIT_SSL_CAINFO=/etc/ssl/certs/host-ca.pem)
fi
exec docker run --rm --network host "${PROXY_ARGS[@]}" -v "$PWD":/src -w /src "$IMAGE" \
  swift test --scratch-path .build/linux "$@"
