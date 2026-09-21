#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="PressureFieldProbe.app"
IDENTITY="Apple Development: Udhay Adithya J (PN3NKRAK2M)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -O -target arm64-apple-macos26.0 \
  -framework AppKit -framework ApplicationServices main.swift \
  -o "$APP/Contents/MacOS/PressureFieldProbe"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PressureFieldProbe</string>
  <key>CFBundleIdentifier</key><string>com.udhayadithya.PeekPressureProbe</string>
  <key>CFBundleName</key><string>Peek Pressure Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "built: $(pwd)/$APP"
