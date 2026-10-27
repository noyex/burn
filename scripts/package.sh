#!/bin/zsh
# Builds a universal Burn.app and packs it into dist/Burn.dmg (drag to Applications) and dist/Burn.zip.
# Laying out the DMG window drives Finder, so the first run asks for permission to control it.
set -euo pipefail
cd "${0:A:h}/.."

scripts/build-app.sh --universal
rm -rf dist && mkdir -p dist/dmg/.background

ditto -c -k --keepParent build/Burn.app dist/Burn.zip

cp -R build/Burn.app dist/dmg/
ln -s /Applications dist/dmg/Applications
swift scripts/dmg-background.swift dist/dmg/.background
tiffutil -cathidpicheck dist/dmg/.background/background.png dist/dmg/.background/background@2x.png \
  -out dist/dmg/.background/background.tiff 2>/dev/null
rm dist/dmg/.background/*.png

# Finder addresses the volume by name, so an already mounted "Burn" would get the layout instead.
[[ -d /Volumes/Burn ]] && hdiutil detach -quiet /Volumes/Burn
hdiutil create -quiet -volname Burn -srcfolder dist/dmg -fs HFS+ -format UDRW -size 20m -ov dist/rw.dmg
rm -rf dist/dmg
hdiutil attach -quiet -readwrite -noverify -noautoopen dist/rw.dmg

# Window content is 660x400 to match the background, plus 32 pt of title bar; icon positions are their centers.
osascript <<'APPLESCRIPT'
tell application "Finder"
  tell disk "Burn"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set bounds of container window to {200, 120, 860, 552}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Burn.app" of container window to {180, 196}
    set position of item "Applications" of container window to {480, 196}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach -quiet /Volumes/Burn
hdiutil convert -quiet dist/rw.dmg -format UDZO -imagekey zlib-level=9 -o dist/Burn.dmg
rm dist/rw.dmg

ls -lh dist
