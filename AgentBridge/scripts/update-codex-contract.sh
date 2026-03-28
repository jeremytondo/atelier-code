#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_ROOT="$ROOT_DIR/src/codex/upstream/codex-cli-0.114.0"

rm -rf "$OUTPUT_ROOT/schema" "$OUTPUT_ROOT/ts"
mkdir -p "$OUTPUT_ROOT"

codex app-server generate-json-schema --experimental --out "$OUTPUT_ROOT/schema"
codex app-server generate-ts --experimental --out "$OUTPUT_ROOT/ts"
