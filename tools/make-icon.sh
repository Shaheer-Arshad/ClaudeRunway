#!/bin/bash
# Builds Resources/AppIcon.icns from the SparkMark geometry.
# Run this only when the mark changes; build.sh consumes the committed .icns.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swiftc -O -target arm64-apple-macos14.0 \
  App/SparkMark.swift tools/icon/main.swift \
  -o "$WORK/makeicon"

"$WORK/makeicon" "$WORK/AppIcon.iconset"

mkdir -p Resources
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
echo "==> Resources/AppIcon.icns"
