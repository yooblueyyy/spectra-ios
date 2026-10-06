#!/usr/bin/env bash
# Puts the Spectra dashboard into SpectraDashboard.bundle, which pipeline.sh injects into the app and
# Spectra/Dashboard.m serves to its web view.
#
#   scripts/build-dashboard.sh <Spectra extension folder> <out dir>
#
# The extension folder is the browser extension's source (extension/ in the Spectra repo): its
# dashboard/, shared/ and icons/ go in as they are, with dashboard/ios-shim.js beside them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="${1:?usage: $0 <extension folder> <out dir>}"
OUT="${2:?usage: $0 <extension folder> <out dir>}"
BUNDLE="$OUT/SpectraDashboard.bundle"

for dir in dashboard shared icons; do
  [ -d "$EXT/$dir" ] || { echo "no $EXT/$dir" >&2; exit 1; }
done
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE"
cp -R "$EXT/dashboard" "$EXT/shared" "$EXT/icons" "$BUNDLE/"
cp "$ROOT/dashboard/ios-shim.js" "$BUNDLE/ios-shim.js"
# A bundle needs an Info.plist to be one.
cat > "$BUNDLE/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>xyz.usespectra.ios.dashboard</string>
	<key>CFBundleName</key>
	<string>SpectraDashboard</string>
	<key>CFBundlePackageType</key>
	<string>BNDL</string>
</dict>
</plist>
PLIST
echo "    $BUNDLE ($(du -sh "$BUNDLE" | cut -f1))"
