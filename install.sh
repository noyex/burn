#!/bin/bash
# Installs the latest Burn release into /Applications and launches it.
#   curl -fsSL https://raw.githubusercontent.com/noyex/burn/main/install.sh | bash
set -euo pipefail

URL="${BURN_URL:-https://github.com/noyex/burn/releases/latest/download/Burn.zip}"

fail() { echo "burn: $*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "Burn is a macOS app."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 14 )) || fail "Burn needs macOS 14 or later (this Mac runs $(sw_vers -productVersion))."

# /Applications when we can write to it, otherwise ~/Applications, no sudo needed.
DEST=/Applications
if [[ -e "$DEST/Burn.app" && ! -w "$DEST/Burn.app" ]] || [[ ! -w "$DEST" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Burn…"
curl -fsSL "$URL" -o "$TMP/Burn.zip" || fail "download failed: $URL"
ditto -x -k "$TMP/Burn.zip" "$TMP"
[[ -d "$TMP/Burn.app" ]] || fail "the download doesn't contain Burn.app"

# Quit a running copy so it can be replaced.
if pgrep -x Burn >/dev/null; then
  osascript -e 'quit app "Burn"' 2>/dev/null || pkill -x Burn || true
  for _ in {1..30}; do pgrep -x Burn >/dev/null || break; sleep 0.1; done
fi

rm -rf "$DEST/Burn.app"
ditto "$TMP/Burn.app" "$DEST/Burn.app"
# The app isn't notarized; downloaded with curl it has no quarantine flag, but clear it to be sure.
find "$DEST/Burn.app" -exec xattr -d com.apple.quarantine {} + &>/dev/null || true

open "$DEST/Burn.app"
echo "Installed $DEST/Burn.app. Look for it in the menu bar."
