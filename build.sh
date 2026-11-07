#!/bin/bash
# Builds Byte.app and installs it into ~/Applications
set -e
cd "$(dirname "$0")"
APP="build/Byte.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library Sources/main.swift \
  -o "$APP/Contents/MacOS/Byte" \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework Security

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Byte</string>
  <key>CFBundleDisplayName</key><string>Byte</string>
  <key>CFBundleIdentifier</key><string>local.naikko.byte</string>
  <key>CFBundleExecutable</key><string>Byte</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/Byte.app
cp -R "$APP" ~/Applications/
echo "✓ Built and installed ~/Applications/Byte.app"
