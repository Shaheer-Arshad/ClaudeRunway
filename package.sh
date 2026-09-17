#!/bin/bash
# Produces a drag-to-install DMG of the built app: the app icon on the left, an
# arrow, and an Applications shortcut on the right.
#
# The app is ad-hoc signed (no paid Apple Developer account), so Gatekeeper on
# the recipient's Mac will block it on first launch. That is expected and the
# release notes and README explain the one-time workaround.
#
# Uses only hdiutil and Finder scripting, so nothing needs installing. Laying out
# the window needs a logged-in GUI session (a Mac, or a GitHub macOS runner).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeRunway"
VOLUME="Claude Runway"
VERSION="${1:-1.0}"
STAGE=$(mktemp -d)
RW="$STAGE/rw.dmg"
MOUNT="/Volumes/$VOLUME"
cleanup() {
  hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

echo "==> Building"
# Universal so the DMG runs on Intel too — a downloaded build can land on any Mac.
mkdir -p "$STAGE/root"
VERSION="$VERSION" UNIVERSAL=1 ./build.sh "$STAGE/root" >/dev/null
# Replacing the old app works because the app sits at the top level under the
# same name; dragging it onto Applications prompts to Replace.
ln -s /Applications "$STAGE/root/Applications"
mkdir "$STAGE/root/.background"
cp Resources/dmg-background.tiff "$STAGE/root/.background/background.tiff"

echo "==> Creating disk image"
# A leftover mount with the same name would make Finder style the wrong volume.
hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
hdiutil create -quiet -srcfolder "$STAGE/root" -volname "$VOLUME" \
  -fs HFS+ -format UDRW -ov "$RW"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW"

echo "==> Laying out window"
# Window content is 600x380 to match the background artwork; icon centres
# line up with either end of the drawn arrow.
osascript <<OSA
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 800, 522}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {160, 190}
    set position of item "Applications" of container window to {440, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
# Give Finder time to flush .DS_Store before the volume is detached.
sync; sleep 2
hdiutil detach "$MOUNT" -quiet

echo "==> Compressing"
mkdir -p dist
OUT="dist/$APP_NAME-$VERSION.dmg"
rm -f "$OUT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT"

echo "==> $OUT  ($(du -h "$OUT" | cut -f1))"
