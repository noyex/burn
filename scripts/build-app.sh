#!/bin/zsh
# Builds build/Burn.app.
#   --universal  arm64 + x86_64 binary (used for releases)
#   --install    copies it to /Applications and (re)launches it
set -euo pipefail
cd "${0:A:h}/.."

ARCHS=()
INSTALL=0
for arg in "$@"; do
  case $arg in
    --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/Burn"
APP=build/Burn.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Burn"
[[ -f assets/AppIcon.icns ]] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R assets/Fonts "$APP/Contents/Resources/Fonts"

# 1.2.0 from the latest v1.2.0 tag; the build number is the commit count.
VERSION="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo v0.0.0)"
VERSION="${VERSION#v}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.mikolaj.burn</string>
  <key>CFBundleName</key><string>Burn</string>
  <key>CFBundleDisplayName</key><string>Burn</string>
  <key>CFBundleExecutable</key><string>Burn</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if (( INSTALL )); then
  pkill -x Burn || true
  for _ in {1..30}; do pgrep -x Burn >/dev/null || break; sleep 0.1; done
  rm -rf /Applications/Burn.app
  cp -R "$APP" /Applications/Burn.app
  open /Applications/Burn.app
  echo "Installed /Applications/Burn.app"
fi
