#!/bin/bash
# Builds ClaudeRunway.app without Xcode (Command Line Tools only).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeRunway"
BUNDLE_ID="com.shaheer.clauderunway"
DEST="${1:-$HOME/Applications}"
APP="$DEST/$APP_NAME.app"

# Stamped into Info.plist. The release workflow sets this from the git tag;
# a local build is just "1.0".
VERSION="${VERSION:-1.0}"

# Local builds are arm64-only — that's every Mac this is developed on, and one
# compile instead of two. Release builds set UNIVERSAL=1 so the downloadable
# zip also runs on Intel.
UNIVERSAL="${UNIVERSAL:-0}"

echo "==> Compiling"
rm -rf build && mkdir -p build
compile() {  # compile <target-triple> <output>
  swiftc -O \
    -target "$1" \
    Sources/RunwayCore/*.swift \
    App/*.swift \
    -o "$2"
}
if [ "$UNIVERSAL" = "1" ]; then
  compile arm64-apple-macos14.0 "build/$APP_NAME-arm64"
  compile x86_64-apple-macos14.0 "build/$APP_NAME-x86_64"
  lipo -create -output "build/$APP_NAME" \
    "build/$APP_NAME-arm64" "build/$APP_NAME-x86_64"
else
  compile arm64-apple-macos14.0 "build/$APP_NAME"
fi

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
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
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

echo "==> Installed at $APP  (version $VERSION)"
