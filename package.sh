#!/bin/bash
# Build a release .app and package it into a zip for a GitHub Release / Homebrew cask.
# Usage:  ./package.sh [version]
#   version defaults to 1.0; CI passes the git tag (without leading "v").
# Outputs (in ./dist):
#   ExtSelector-<version>.zip   — the artifact the cask downloads
#   ExtSelector-<version>.zip.sha256
# Prints VERSION and SHA256 (also written to $GITHUB_OUTPUT when run in Actions).
set -euo pipefail

cd "$(dirname "$0")"

VERSION="${1:-1.0}"
BUILD="${BUILD:-1}"
APP="ExtSelector.app"
DIST="dist"
ZIP="ExtSelector-${VERSION}.zip"

echo "Packaging ExtSelector ${VERSION} (build ${BUILD})…"

# Build the bundled .app with the version stamped in.
VERSION="$VERSION" BUILD="$BUILD" ./bundle.sh release

rm -rf "$DIST"
mkdir -p "$DIST"

# `ditto` preserves the .app's symlinks, resource forks and permissions — a plain
# `zip` corrupts macOS bundles, so always use ditto for distributing apps.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ZIP"

SHA256="$(shasum -a 256 "$DIST/$ZIP" | awk '{print $1}')"
echo "$SHA256  $ZIP" > "$DIST/$ZIP.sha256"

echo "----------------------------------------"
echo "Artifact: $DIST/$ZIP"
echo "Version:  $VERSION"
echo "SHA256:   $SHA256"
echo "----------------------------------------"

# Expose to GitHub Actions if running there.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "version=$VERSION"
    echo "sha256=$SHA256"
    echo "zip=$DIST/$ZIP"
  } >> "$GITHUB_OUTPUT"
fi
