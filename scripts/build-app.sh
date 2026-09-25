#!/usr/bin/env bash
# Build a release binary with SwiftPM and wrap it in a macOS .app bundle.
# Output: build/Claudio.app (and a zipped copy for CI artifacts).
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
APP_NAME="Claudio"
BUNDLE_ID="${BUNDLE_ID:-com.tim020.claudio}"
VERSION="${VERSION:-0.1.0}"

swift build -c "$CONFIG" --product Claudio
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build

cp "$BIN_DIR/Claudio" "$APP/Contents/MacOS/Claudio"
# SwiftPM resource bundle (fonts) — Bundle.module looks next to the executable
# and in Contents/Resources.
if [ -d "$BIN_DIR/Claudio_Claudio.bundle" ]; then
  cp -R "$BIN_DIR/Claudio_Claudio.bundle" "$APP/Contents/Resources/"
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
  <key>CFBundleExecutable</key><string>Claudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Claudio runs Claude Code sessions in your projects, and some of them are in your Documents folder.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Claudio runs Claude Code sessions in your projects, and some of them are on your Desktop.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Claudio runs Claude Code sessions in your projects, and some of them are in your Downloads folder.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Claudio runs Claude Code sessions in your projects, and some of them are on an external drive.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Claudio runs Claude Code sessions in your projects, and some of them are on a network volume.</string>
</dict>
</plist>
PLIST

# Sign with a stable identity when there is one. macOS remembers folder access
# (Documents, Desktop…) and notification permission per signing identity; an
# ad-hoc signature changes with every build, so each rebuild would ask again.
# Override with CODESIGN_IDENTITY="Apple Development: …" (or "-" for ad hoc).
if [ -z "${CODESIGN_IDENTITY:-}" ] && [ -z "${CI:-}" ]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/^ *[0-9]+\) [0-9A-F]{40} "((Apple Development|Developer ID Application|Mac Developer)[^"]*)"$/\1/p' | head -1)"
fi
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  [ -z "${CI:-}" ] && note "Signed ad hoc: macOS may ask for folder access again after each rebuild. Sign in to Xcode with your Apple ID (Settings > Accounts) to get an Apple Development certificate, and this script will use it."
elif codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP" >build/codesign.log 2>&1; then
  note "Signed with $CODESIGN_IDENTITY"
else
  note "Signing with $CODESIGN_IDENTITY failed ($(tr '\n' ' ' < build/codesign.log | cut -c1-200)); signing ad hoc"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

(cd build && rm -f "$APP_NAME.zip" && ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip")
echo "Built $APP"

if [ "$OPEN_APP" = 1 ]; then
  # Quit a running copy politely (so it can stop its sessions), then open the new build.
  if pgrep -xq Claudio; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -xq Claudio || break; sleep 0.1; done
  fi
  open "$APP"
fi
