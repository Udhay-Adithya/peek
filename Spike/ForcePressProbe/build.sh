#!/bin/bash
# Builds the P0 probe as a signed .app so TCC attributes the Accessibility
# grant to the bundle (a bare CLI binary would attribute it to the terminal).
set -euo pipefail
cd "$(dirname "$0")"

APP="ForcePressProbe.app"
IDENTITY="Apple Development: Udhay Adithya J (PN3NKRAK2M)"

rm -rf "$APP" ForcePressProbe
mkdir -p "$APP/Contents/MacOS"

swiftc -swift-version 5 -O \
  -target arm64-apple-macos26.0 \
  -framework AppKit -framework ApplicationServices \
  main.swift -o "$APP/Contents/MacOS/ForcePressProbe"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ForcePressProbe</string>
  <key>CFBundleIdentifier</key><string>com.udhayadithya.PeekForceProbe</string>
  <key>CFBundleName</key><string>Peek Force Probe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|TeamIdentifier' || true
echo "built: $(pwd)/$APP"
