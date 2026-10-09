#!/usr/bin/env bash
# Exercise the actual workflow; optional --red-baseline verifies its pre-change behavior.
set -euo pipefail

SCRIPT_DIR=$(dirname -- "${BASH_SOURCE[0]}")
exec python3 -B "$SCRIPT_DIR/fixtures/ci-build-only/workflow-contract.py" \
    --workflow "$SCRIPT_DIR/../.github/workflows/openwrt-builder.yml" "$@"
