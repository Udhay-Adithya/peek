#!/bin/bash
#
# Builds, signs, notarizes and packages Peek for distribution outside the
# Mac App Store. See docs/adr/0002-developer-id-not-app-store.md for why
# Developer ID rather than the store.
#
# One-time setup:
#   1. Create a "Developer ID Application" certificate (NOT "Apple
#      Development" — a different type, and only the Account Holder can make
#      one): Xcode → Settings → Accounts → select your team → Manage
#      Certificates → + → Developer ID Application.
#   2. Create an app-specific password at https://appleid.apple.com → Sign-In
#      and Security → App-Specific Passwords.
#   3. Store notarization credentials once:
#        xcrun notarytool store-credentials peek \
#          --apple-id "udhayxd@gmail.com" \
#          --team-id 5ZN86R9K96 \
#          --password "<app-specific-password>"
#
# Then: ./scripts/release.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="5ZN86R9K96"
NOTARY_PROFILE="peek"
BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/Peek.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/Peek.app"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31merror: %s\033[0m\n' "$1" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------
say "Preflight"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  fail "No 'Developer ID Application' certificate found.

You currently have an 'Apple Development' certificate, which signs local
builds but CANNOT be notarized or distributed. Create the other kind:

  Xcode → Settings → Accounts → your team → Manage Certificates
        → + → Developer ID Application

This requires the Account Holder role on the paid developer account."
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  fail "Notarization profile '$NOTARY_PROFILE' not found. Run:

  xcrun notarytool store-credentials $NOTARY_PROFILE \\
    --apple-id \"udhayxd@gmail.com\" --team-id $TEAM_ID --password \"<app-specific-password>\""
fi

command -v xcodegen >/dev/null || fail "xcodegen not installed (brew install xcodegen)"

# --- Tests must pass before anything ships --------------------------------
say "Running tests"
(cd Packages/PeekKit && swift test)

# --- Build ----------------------------------------------------------------
say "Generating project"
xcodegen generate

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

say "Archiving (Release)"
xcodebuild archive \
  -project Peek.xcodeproj \
  -scheme Peek \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  | grep -E "error:|warning:|BUILD" || true

[ -d "$ARCHIVE" ] || fail "Archive was not produced"

say "Exporting"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

[ -d "$APP" ] || fail "Export did not produce Peek.app"

# --- Verify signing before spending a notarization round trip -------------
say "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|flags|TeamIdentifier"

codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "app-sandbox" \
  && echo "note: entitlements declare app-sandbox=false, as intended"

# Hardened runtime is mandatory for notarization.
codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime" \
  || fail "Hardened runtime is not enabled; notarization will be rejected"

# --- Package --------------------------------------------------------------
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$BUILD_DIR/Peek-$VERSION.dmg"

say "Building DMG ($VERSION)"
STAGING="$BUILD_DIR/dmg"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Peek" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
codesign --sign "Developer ID Application" --timestamp "$DMG"

# --- Notarize -------------------------------------------------------------
say "Notarizing (this can take several minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

say "Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

say "Verifying Gatekeeper acceptance"
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 || true

printf '\n\033[32mdone: %s\033[0m\n\n' "$DMG"
