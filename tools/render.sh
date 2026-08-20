#!/bin/bash
# Renders the menu bar item across usage states and both appearances.
# A menu bar item is awkward to screenshot; this makes it inspectable.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/menubar}"
BIN=$(mktemp -d)
trap 'rm -rf "$BIN"' EXIT

swiftc -O \
  -target arm64-apple-macos14.0 \
  Sources/RunwayCore/*.swift \
  App/SparkMark.swift App/StatusItemView.swift App/Theme.swift \
  tools/render/main.swift \
  -o "$BIN/render"

"$BIN/render" "$OUT"
