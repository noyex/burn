#!/bin/zsh
# Builds a universal Burn.app and packs it into dist/Burn.dmg (drag to Applications) and dist/Burn.zip.
set -euo pipefail
cd "${0:A:h}/.."

scripts/build-app.sh --universal
rm -rf dist && mkdir -p dist/dmg

ditto -c -k --keepParent build/Burn.app dist/Burn.zip

cp -R build/Burn.app dist/dmg/
ln -s /Applications dist/dmg/Applications
hdiutil create -quiet -volname Burn -srcfolder dist/dmg -fs HFS+ -format UDZO -ov dist/Burn.dmg
rm -rf dist/dmg

ls -lh dist
