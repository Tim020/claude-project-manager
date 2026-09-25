#!/usr/bin/env bash
# Build a release binary with SwiftPM and wrap it in a macOS .app bundle.
# Output: build/Session Manager.app (and a zipped copy for CI artifacts).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="Session Manager"
BUNDLE_ID="${BUNDLE_ID:-com.tim020.sessionmanager}"
VERSION="${VERSION:-0.1.0}"

swift build -c "$CONFIG" --product SessionManager
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/SessionManager" "$APP/Contents/MacOS/SessionManager"
# SwiftPM resource bundle (fonts) — Bundle.module looks next to the executable
# and in Contents/Resources.
if [ -d "$BIN_DIR/SessionManager_SessionManager.bundle" ]; then
  cp -R "$BIN_DIR/SessionManager_SessionManager.bundle" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>SessionManager</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper lets a locally built copy run.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

(cd build && rm -f "$APP_NAME.zip" && ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip")
echo "Built $APP"
