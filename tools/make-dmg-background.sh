#!/bin/bash
# Builds Resources/dmg-background.tiff (1x + 2x) for the installer DMG.
# Run this only when the artwork changes; package.sh consumes the committed file.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swiftc -O tools/dmg-background/main.swift -o "$WORK/bg"
"$WORK/bg" "$WORK/bg.png" 1
"$WORK/bg" "$WORK/bg@2x.png" 2
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out Resources/dmg-background.tiff
echo "==> Resources/dmg-background.tiff"
