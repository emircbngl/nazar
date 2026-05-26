#!/usr/bin/env bash
#
# Notarize Nazar.app and produce a DMG ready for distribution.
#
# Prerequisites
# -------------
# 1. Apple Developer account ($99/yr) — https://developer.apple.com/programs/
# 2. "Developer ID Application" certificate installed in your login Keychain.
#    Create at https://developer.apple.com/account/resources/certificates/list
#    (Certificates → +, choose "Developer ID Application", download .cer,
#    double-click to import.) Identity will look like
#    "Developer ID Application: Your Name (TEAMID)".
# 3. App-specific password from https://appleid.apple.com/ → "App-Specific Passwords"
#    Save it via:
#       xcrun notarytool store-credentials nazar-notarize \
#         --apple-id "you@example.com" \
#         --team-id  "TEAMID" \
#         --password "app-specific-password"
#    This stores the creds in the system Keychain under the profile name
#    "nazar-notarize" — used below.
#
# Usage
# -----
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/notarize.sh
#
# Outputs
# -------
#   build/Nazar.app  (signed, hardened, stapled)
#   build/Nazar-<version>.dmg
#
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:?Set IDENTITY env var to your Developer ID Application identity}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-nazar-notarize}"

VERSION=""
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Nazar/Info.plist) \
  || { echo "ERROR: could not read CFBundleShortVersionString" >&2; exit 1; }
[ -n "$VERSION" ] || { echo "ERROR: CFBundleShortVersionString is empty" >&2; exit 1; }

BUILD_DIR="build"
APP="$BUILD_DIR/Nazar.app"
DMG="$BUILD_DIR/Nazar-$VERSION.dmg"
ENTITLEMENTS="Nazar/Nazar.entitlements"

echo "==> Cleaning previous build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> swift build -c release"
swift build -c release

echo "==> Assembling app bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Nazar "$APP/Contents/MacOS/Nazar"
cp Nazar/Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Embed Sparkle.framework — SPM produces it next to the binary; the .app needs
# it under Contents/Frameworks. Hard fail if SPM ever moves the artifact —
# otherwise we'd ship a bundle that crashes on launch with a dyld error.
if [ ! -d ".build/release/Sparkle.framework" ]; then
  echo "ERROR: .build/release/Sparkle.framework not found." >&2
  echo "  SPM may have changed where it emits the framework. Investigate:" >&2
  echo "  find .build/release -name 'Sparkle.framework' -type d" >&2
  exit 1
fi

echo "==> Embedding Sparkle.framework"
rsync -a ".build/release/Sparkle.framework" "$APP/Contents/Frameworks/"

# Add @executable_path/../Frameworks to the binary's rpath so dyld finds the
# embedded Sparkle at launch. Only add if not already present — `add_rpath`
# silently duplicates entries, and unconditional `|| true` masks real errors.
if ! /usr/bin/otool -l "$APP/Contents/MacOS/Nazar" \
     | /usr/bin/grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/Nazar"
fi

echo "==> Codesigning Sparkle nested code, inside-out"
# Use -depth so children are signed before their parent bundle — codesign on
# a bundle re-seals it based on its current contents, so any later child
# modification (including a sign) would invalidate the outer signature.
# Match every signable artifact Sparkle ships: XPCServices, helper apps,
# Autoupdate launcher, and any standalone Mach-O under those bundles.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
while IFS= read -r -d '' nested; do
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$nested"
done < <(find "$SPARKLE_FW" -depth \
  \( -name "*.xpc" -o -name "Updater.app" -o -name "Autoupdate" \) -print0)

codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$SPARKLE_FW"

echo "==> Codesigning app bundle with hardened runtime"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" \
  "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Building DMG"
hdiutil create -volname "Nazar" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "==> Notarizing DMG (may take a few minutes)"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait

echo "==> Stapling notarization to DMG"
xcrun stapler staple "$DMG"

echo "==> Stapling notarization to app inside DMG"
# Mount, staple app inside, eject, rebuild dmg
MOUNT=$(hdiutil attach "$DMG" -nobrowse -noverify | tail -1 | awk '{print $3}')
xcrun stapler staple "$MOUNT/Nazar.app"
hdiutil detach "$MOUNT"

echo "==> Done"
echo "    App:  $APP"
echo "    DMG:  $DMG"
echo "    Verify with: spctl --assess --type execute --verbose $APP"
