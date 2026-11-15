#!/bin/bash
# Fails when the panel UI hardcodes a color or a fixed pill radius instead of using the theme.
# Users restyle Burn with theme files (docs/themes.md); a literal color is one they can't change.
# Colors and the pill radius live in ui/src/lib/theme.css only.
set -euo pipefail
cd "$(dirname "$0")/../ui/src"

NAMED='white|black|red|orange|yellow|green|blue|purple|pink|gray|grey|brown|cyan|teal|indigo|navy|silver|gold|lime|magenta|maroon|olive|aqua'
PATTERN="#[0-9A-Fa-f]{3,8}\b|\b(rgba?|hsla?|hwb|lab|lch|oklab|oklch)\(|(:|[ (,])($NAMED)\b[^-]|(:|[ (,])($NAMED)$|border-radius:[[:space:]]*9{3,4}px"

# Icons.svelte: the white and black of its SVG masks are luminance, not a themed color.
hits="$(grep -rnE "$PATTERN" . --include='*.svelte' --include='*.ts' --include='*.css' \
  | grep -vE '^\./lib/theme\.css:' \
  | grep -vE '^\./lib/components/Icons\.svelte:' \
  | grep -vE '\.test\.ts:' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|/\*|\*|<!--)' || true)"

if [[ -n "$hits" ]]; then
  echo "Hardcoded colors or fixed pill radius outside theme.css. Use theme variables and var(--pill) (see AGENTS.md):"
  echo "$hits"
  exit 1
fi
echo "No hardcoded colors outside the theme."
