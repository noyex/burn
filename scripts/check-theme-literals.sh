#!/bin/bash
# Fails when a view hardcodes a color or a capsule instead of using the theme.
# Users restyle Burn with theme files (docs/themes.md); a literal color is one they can't change.
# Colors live in Sources/Burn/UI/Theme.swift and ThemeSpec.swift only.
set -euo pipefail
cd "$(dirname "$0")/.."

NAMED='white|black|red|orange|yellow|green|blue|purple|pink|gray|brown|cyan|mint|teal|indigo|primary|secondary|tertiary|quaternary'
PATTERN="Color\((hex|red|white|\.sRGB|\.displayP3)|NSColor\(|NSColor\.system|[(, :?]\.($NAMED)\b|Color\.($NAMED)\b|\.(system[A-Z][A-Za-z]*|labelColor|[a-z][A-Za-z]*LabelColor|textColor|windowBackgroundColor|controlAccentColor)\b|#[0-9A-Fa-f]{6}\b|Capsule\(\)|\(\.tint\)|accentColor"

hits="$(grep -rnE "$PATTERN" Sources/Burn --include='*.swift' \
  | grep -vE '^Sources/Burn/UI/(Theme|ThemeSpec)\.swift:' \
  | grep -vE '^[^:]+:[0-9]+:\s*//' || true)"

if [[ -n "$hits" ]]; then
  echo "Hardcoded colors or Capsule() outside the theme. Use Theme tokens and Bento.pill (see AGENTS.md):"
  echo "$hits"
  exit 1
fi
echo "No hardcoded colors outside the theme."
