#!/bin/zsh
# Tags main as the given version, builds the DMG and zip, and publishes them as a GitHub release.
#   scripts/release.sh v1.0.0
set -euo pipefail
cd "${0:A:h}/.."

TAG="${1:?usage: scripts/release.sh vX.Y.Z}"
[[ "$TAG" == v<->.<->.<-> ]] || { echo "Version must look like v1.2.3" >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo "Release from main" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree is not clean" >&2; exit 1; }
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main is not up to date with origin" >&2; exit 1; }

# The build reads the version from the tag, so tag first and drop the tag again if anything fails.
git tag -a "$TAG" -m "Burn $TAG"
trap 'git tag -d "$TAG" >/dev/null' ERR
scripts/package.sh
git push -q origin "$TAG"
trap - ERR
gh release create "$TAG" dist/Burn.dmg dist/Burn.zip --title "Burn $TAG" --generate-notes
