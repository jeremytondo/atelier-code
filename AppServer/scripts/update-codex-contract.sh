#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINNED_CODEX_VERSION="0.114.0"
OUTPUT_ROOT="$ROOT_DIR/src/agents/codex-adapter/upstream/codex-cli-$PINNED_CODEX_VERSION"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/atelier-codex-contract.XXXXXX")"

cleanup() {
  rm -rf "$TEMP_ROOT"
}

trap cleanup EXIT

mkdir -p "$TEMP_ROOT"

codex app-server generate-json-schema --experimental --out "$TEMP_ROOT/schema"
codex app-server generate-ts --experimental --out "$TEMP_ROOT/ts"

mkdir -p "$OUTPUT_ROOT"
rm -rf "$OUTPUT_ROOT/schema" "$OUTPUT_ROOT/ts"
mv "$TEMP_ROOT/schema" "$OUTPUT_ROOT/schema"
mv "$TEMP_ROOT/ts" "$OUTPUT_ROOT/ts"
