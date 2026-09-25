#!/usr/bin/env bash
# Run the core test suite inside the official Swift Linux image.
# Useful when working on a machine without a local Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="${SWIFT_IMAGE:-swift:6.1-noble}"
exec docker run --rm -v "$PWD":/src -w /src "$IMAGE" \
  swift test --scratch-path .build/linux "$@"
