#!/usr/bin/env bash
# Build a release binary with SwiftPM and wrap it in a macOS .app bundle.
# Output: build/Session Manager.app (and a zipped copy for CI artifacts).
# Then relaunches the app, unless running in CI or given --no-open.
#
#   ./scripts/build-app.sh            build and open
#   ./scripts/build-app.sh --no-open  build only
set -euo pipefail
cd "$(dirname "$0")/.."

OPEN_APP=1
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN_APP=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
[ -n "${CI:-}" ] && OPEN_APP=0

CONFIG="${CONFIG:-release}"
APP_NAME="Session Manager"
BUNDLE_ID="${BUNDLE_ID:-com.tim020.sessionmanager}"
VERSION="${VERSION:-0.1.0}"

swift build -c "$CONFIG" --product SessionManager
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

cp "$BIN_DIR/SessionManager" "$APP/Contents/MacOS/SessionManager"
# SwiftPM resource bundle (fonts) — Bundle.module looks next to the executable
# and in Contents/Resources.
if [ -d "$BIN_DIR/SessionManager_SessionManager.bundle" ]; then
  cp -R "$BIN_DIR/SessionManager_SessionManager.bundle" "$APP/Contents/Resources/"
fi

# App icon from Resources/Assets.xcassets (light design 3b). actool compiles it
# into Assets.car + AppIcon.icns; iconutil is the fallback. A classic
# .appiconset can't hold a dark variant — that needs an Icon Composer .icon
# (sources in design/app-icon/).
ICONSET_SRC="Resources/Assets.xcassets/AppIcon.appiconset"
note() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice::$1"; else echo "$1"; fi; }
if xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" \
     --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
     --output-partial-info-plist build/AppIcon-partial.plist \
     --output-format human-readable-text --errors --warnings >build/actool.log 2>&1 \
   && [ -f "$APP/Contents/Resources/Assets.car" ]; then
  note "App icon: compiled asset catalog"
else
  note "App icon: actool unavailable or failed, using iconutil fallback ($(tr '\n' ' ' < build/actool.log | cut -c1-300))"
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for f in "$ICONSET_SRC"/icon_[0-9]*.png; do
    name="$(basename "$f")"
    cp "$f" "$ICONSET/${name/-2x/@2x}"
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
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

if [ "$OPEN_APP" = 1 ]; then
  # Quit a running copy politely (so it can stop its sessions), then open the new build.
  if pgrep -xq SessionManager; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -xq SessionManager || break; sleep 0.1; done
  fi
  open "$APP"
fi
