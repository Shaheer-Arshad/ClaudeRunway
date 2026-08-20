#!/bin/bash
# Produces a shareable zip of the built app.
#
# The app is ad-hoc signed (no paid Apple Developer account), so Gatekeeper on
# the recipient's Mac will block it on first launch. That is expected and the
# included INSTALL.txt explains the one-time workaround.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeRunway"
VERSION="${1:-1.0}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# Zip inside a named folder — `--keepParent` uses the directory name, and a
# recipient should not unpack something called "tmp.XkQ92f".
PKG="$STAGE/Claude Runway"
mkdir -p "$PKG"

echo "==> Building"
# Universal so the zip runs on Intel too — a downloaded build can land on any Mac.
VERSION="$VERSION" UNIVERSAL=1 ./build.sh "$PKG" >/dev/null

cat > "$PKG/INSTALL.txt" <<'TXT'
Claude Runway — menu bar app for your Claude Code 5-hour and weekly limits


INSTALL

1. Drag ClaudeRunway.app to your Applications folder.

2. The first launch will be blocked — macOS says it can't check the app
   for malicious software. This app isn't signed with a paid Apple
   Developer certificate, so that warning is expected.

   To open it anyway:
     - Open System Settings > Privacy & Security
     - Scroll down to the message about ClaudeRunway
     - Click "Open Anyway" and authenticate

   On macOS 14 (Sonoma) you can instead right-click the app and choose
   "Open". That shortcut was removed in macOS 15 (Sequoia), so on 15 and
   later use the Settings route above.

   If macOS instead says the app is "damaged and can't be opened", the
   bundle's signature was mangled in transit. Run this once in Terminal,
   then open it normally:

     xattr -dr com.apple.quarantine /Applications/ClaudeRunway.app

   You only have to do this once.

3. Click the spark icon in your menu bar.


WHAT YOU NEED

Claude Code, installed and signed in. The app reads the token Claude Code
already stores in your keychain. macOS will ask permission the first time —
click Allow.

Without it, the app has nothing to read and will say so.


FASTER UPDATES (optional)

By default the app updates every 15 minutes, because the endpoint it reads is
heavily rate limited.

For updates every minute, give it a claude.ai session key:

  1. Open claude.ai in your browser and sign in
  2. Open DevTools (Cmd-Option-I)
  3. Application > Cookies > https://claude.ai
  4. Copy the value of "sessionKey"
  5. Paste it into the app's popover and click Save

That key stays in your login keychain and is only ever sent to claude.ai.
It expires eventually; the app will tell you and fall back to the slower
mode until you paste a new one.


NOTES

This reads undocumented Claude endpoints and may break if they change.

Claude Runway is an unofficial, independent project. It is not affiliated
with, endorsed by, or connected to Anthropic. "Claude" and "Claude Code"
are trademarks of Anthropic PBC, used here only to identify the product
this tool works with.
TXT

echo "==> Zipping"
mkdir -p dist
OUT="dist/$APP_NAME-$VERSION.zip"
rm -f "$OUT"
# ditto preserves the bundle's symlinks and signature; `zip` can corrupt them.
ditto -c -k --sequesterRsrc --keepParent "$PKG" "$OUT"

echo "==> $OUT  ($(du -h "$OUT" | cut -f1))"
