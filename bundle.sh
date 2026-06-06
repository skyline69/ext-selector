#!/bin/bash
# Wrap the SPM binary into a proper .app bundle — no Xcode IDE needed.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="ExtSelector.app"
ID="com.skyline.extselector"
# Version stamped into Info.plist. Overridable so CI can stamp the git tag.
VERSION="${VERSION:-1.0}"
BUILD="${BUILD:-1}"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)"

# Regenerate AppIcon.icns from the SVG source when tooling is present.
# Falls back to the committed icns if rsvg-convert isn't installed.
if command -v rsvg-convert >/dev/null && command -v iconutil >/dev/null; then
  echo "Rendering icon…"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    rsvg-convert -w "$s"        -h "$s"        Resources/AppIcon.svg -o "$ICONSET/icon_${s}x${s}.png"
    rsvg-convert -w "$((s*2))"  -h "$((s*2))"  Resources/AppIcon.svg -o "$ICONSET/icon_${s}x${s}@2x.png"
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$(dirname "$ICONSET")"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/ExtSelector" "$APP/Contents/MacOS/ExtSelector"
# Bundled resources produced by SPM (Catalog.json lives in the resource bundle).
# This MUST sit at the .app root, NOT Contents/Resources: SPM's generated
# `Bundle.module` accessor for an executable target looks only at
# `Bundle.main.bundleURL/ExtSelector_ExtSelector.bundle` (the .app root). Put it
# anywhere else and Catalog.load() fatal-errors on launch.
if [ -d "$BIN/ExtSelector_ExtSelector.bundle" ]; then
  cp -R "$BIN/ExtSelector_ExtSelector.bundle" "$APP/ExtSelector_ExtSelector.bundle"
fi
# App icon (built from Resources/AppIcon.svg → AppIcon.icns).
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>          <string>ExtSelector</string>
  <key>CFBundleDisplayName</key>   <string>Extension Selector</string>
  <key>CFBundleIdentifier</key>    <string>$ID</string>
  <key>CFBundleVersion</key>       <string>$BUILD</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleExecutable</key>    <string>ExtSelector</string>
  <key>CFBundleIconFile</key>      <string>AppIcon</string>
  <key>CFBundlePackageType</key>   <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
  <key>CFBundleDevelopmentRegion</key>     <string>en</string>
  <key>CFBundleGetInfoString</key> <string>ExtSelector $VERSION — © 2026 Skyline</string>
  <key>NSHumanReadableCopyright</key>      <string>© 2026 Skyline. All rights reserved.</string>
  <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key>      <string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><true/>
  <key>NSSupportsSuddenTermination</key><true/>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>LSUIElement</key>           <false/>
</dict>
</plist>
PLIST

echo "Built $APP"
echo "Run:  open $APP    (or)    ./$APP/Contents/MacOS/ExtSelector"
