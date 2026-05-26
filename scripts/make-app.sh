#!/usr/bin/env bash
# Build, sign, notarize, staple, and bundle Halo.app + a .dmg.
# Mirrors the rest of the suite's release pipeline.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/Halo.app"
SRC_ICON="$ROOT/art/AppIcon-source.png"
VERSION="1.0.27"
SIGN_IDENTITY="${SIGN_IDENTITY:-0948896DC970503ADEF5B5070E0BB3E9D9047757}"
NOTARY_PROFILE="${NOTARY_PROFILE:-Notary}"
DMG="$ROOT/Halo-$VERSION.dmg"

echo "› swift build -c release"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

echo "› assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Halo" "$APP/Contents/MacOS/Halo"
# Halo links libSuiteKit at runtime — bundle the dylib into
# Contents/Frameworks/ and rewrite the rpath so the main binary
# finds it relative to itself. Without this the agent crashes at
# launch with "Library not loaded: @rpath/libSuiteKit.dylib".
if [ -f "$BIN/libSuiteKit.dylib" ]; then
  cp "$BIN/libSuiteKit.dylib" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath @executable_path/../Frameworks \
    "$APP/Contents/MacOS/Halo" 2>/dev/null || true
fi
# SwiftPM bundles app resources into <bundle>_<target>.bundle; copy
# its Resources/ contents up into the .app's Resources/ so
# NSImage(named:) and asset catalog lookups resolve.
RESBUNDLE="$BIN/Halo_Halo.bundle"
if [ -d "$RESBUNDLE/Contents/Resources" ]; then
  ditto "$RESBUNDLE/Contents/Resources/" "$APP/Contents/Resources/"
fi
cp "$ROOT/Sources/Halo/Info.plist" "$APP/Contents/Info.plist"

# Asset catalog → AppIcon.icns via actool if it's been compiled.
# In the dev / ad-hoc path we may not have a real catalog yet —
# the build still completes with a Generic icon.
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  echo "✓ app icon present"
fi

echo "› codesign"
if security find-identity -v -p codesigning 2>/dev/null \
     | grep -q "$SIGN_IDENTITY"; then
  # Inside-out signing: dylib first, then the main app. The
  # entitlements only apply to the main binary; the dylib doesn't
  # need them but it does need a hardened-runtime signature.
  if [ -f "$APP/Contents/Frameworks/libSuiteKit.dylib" ]; then
    codesign --force --options=runtime --timestamp \
      --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/libSuiteKit.dylib"
  fi
  codesign --force --options=runtime --timestamp \
    --entitlements "$ROOT/Sources/Halo/Halo.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP"
  echo "✓ Built + Developer ID signed $APP"
else
  # Ad-hoc path skips --options=runtime — hardened runtime +
  # ad-hoc signature on the host AND the dylib triggers dyld's
  # Team-ID match check, and ad-hoc has no team ID either side
  # so the load fails. Hardened runtime is only required for
  # notarization (handled by the Developer-ID branch above);
  # for local dev we apply the AppleEvents entitlement without
  # it. macOS still prompts the user before letting AppleScript
  # talk to Spotify / Music because of NSAppleEventsUsage
  # Description in Info.plist.
  if [ -f "$APP/Contents/Frameworks/libSuiteKit.dylib" ]; then
    codesign --force --sign - "$APP/Contents/Frameworks/libSuiteKit.dylib"
  fi
  codesign --force \
    --entitlements "$ROOT/Sources/Halo/Halo.entitlements" \
    --sign - "$APP"
  echo "⚠ signing identity not found — ad-hoc signed (local only)"
fi

# Notarize only when Developer ID-signed.
if security find-identity -v -p codesigning 2>/dev/null \
     | grep -q "$SIGN_IDENTITY"; then
  echo "› notarizing"
  NZIP="$(mktemp -d)/Halo.zip"
  ditto -c -k --keepParent "$APP" "$NZIP"
  if xcrun notarytool submit "$NZIP" \
       --keychain-profile "$NOTARY_PROFILE" --wait; then
    xcrun stapler staple "$APP"
    echo "✓ notarized + stapled $APP"
  else
    echo "⚠ notarization skipped/failed — signed but not notarized"
  fi
fi

echo "› bundling $DMG"
STAGE="$(mktemp -d)/dmg"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Halo.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Halo" -srcfolder "$STAGE" -ov \
  -format UDZO "$DMG"
if security find-identity -v -p codesigning 2>/dev/null \
     | grep -q "$SIGN_IDENTITY"; then
  codesign --force --sign "$SIGN_IDENTITY" "$DMG" || true
  xcrun stapler staple "$DMG" 2>/dev/null || true
fi
echo "✓ built $DMG"
