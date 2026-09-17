#!/bin/bash
# Produces a shareable zip of the built app.
#
# The app is ad-hoc signed (no paid Apple Developer account), so Gatekeeper on
# the recipient's Mac will block it on first launch. That is expected and the
# release notes and README explain the one-time workaround.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeRunway"
VERSION="${1:-1.0}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# The zip holds only ClaudeRunway.app at its top level. It used to be wrapped
# in a "Claude Runway" folder with INSTALL.txt, and dragging that folder into
# Applications installed a second copy instead of replacing the existing app.
# Install notes live in the release notes and README instead.
PKG="$STAGE"

echo "==> Building"
# Universal so the zip runs on Intel too — a downloaded build can land on any Mac.
VERSION="$VERSION" UNIVERSAL=1 ./build.sh "$PKG" >/dev/null


echo "==> Zipping"
mkdir -p dist
OUT="dist/$APP_NAME-$VERSION.zip"
rm -f "$OUT"
# ditto preserves the bundle's symlinks and signature; `zip` can corrupt them.
ditto -c -k --sequesterRsrc --keepParent "$PKG/$APP_NAME.app" "$OUT"

echo "==> $OUT  ($(du -h "$OUT" | cut -f1))"
