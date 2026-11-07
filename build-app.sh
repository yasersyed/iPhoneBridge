#!/bin/bash
# Wraps the release binary in a .app so it can live in /Applications and open from Finder or Spotlight.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/iPhone Bridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/iPhoneBridge "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>iPhoneBridge</string>
    <key>CFBundleIdentifier</key><string>local.iphonebridge</string>
    <key>CFBundleName</key><string>iPhone Bridge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signing lets macOS launch the bundle without complaining about a missing signature.
codesign --force --sign - "$APP"
echo "Built: $APP"
