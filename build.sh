#!/bin/bash
# Builds ClaudeRunway.app without Xcode (Command Line Tools only).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeRunway"
BUNDLE_ID="com.shaheer.clauderunway"
DEST="${1:-$HOME/Applications}"
APP="$DEST/$APP_NAME.app"

echo "==> Compiling"
rm -rf build && mkdir -p build
swiftc -O \
  -target arm64-apple-macos14.0 \
  Sources/RunwayCore/*.swift \
  App/*.swift \
  -o "build/$APP_NAME"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Regenerate with ./tools/make-icon.sh if the mark changes.
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "    (no Resources/AppIcon.icns — run ./tools/make-icon.sh)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Claude Runway</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signing with a STABLE identifier. Without this, macOS treats every
# rebuild as a different binary and re-prompts for keychain access each time.
echo "==> Signing"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "==> Installed at $APP"
