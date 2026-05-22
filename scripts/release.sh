#!/usr/bin/env bash
#
# End-to-end release helper:
#   1. Build, sign (Developer ID), notarize, staple — produces build/Nazar-VERSION.dmg
#   2. EdDSA-sign the DMG (Sparkle) and print the signature + size
#   3. Optionally publish a GitHub Release with the DMG attached
#
# Then you manually edit appcast.xml with the new <item> and push.
#
# Usage:
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/release.sh [--publish]
#
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:?Set IDENTITY env var to your Developer ID Application identity}"
PUBLISH="${1:-}"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Nazar/Info.plist)
DMG="build/Nazar-${VERSION}.dmg"

echo "==> Step 1/3: notarize"
./scripts/notarize.sh

echo
echo "==> Step 2/3: Sparkle signing"
if [ ! -x scripts/sparkle/bin/sign_update ]; then
  echo "Sparkle tools missing — running setup."
  ./scripts/setup_sparkle.sh
fi
SIG_LINE=$(./scripts/sparkle/bin/sign_update "$DMG")
echo "$SIG_LINE"
echo
echo "Add this to appcast.xml's new <item>:"
echo
echo "    <enclosure"
echo "      url=\"https://github.com/emircbngl/nazar/releases/download/v${VERSION}/Nazar-${VERSION}.dmg\""
echo "      $SIG_LINE"
echo "      type=\"application/octet-stream\" />"
echo

if [ "$PUBLISH" = "--publish" ]; then
  echo "==> Step 3/3: gh release create v${VERSION}"
  gh release create "v${VERSION}" "$DMG" \
    --title "Nazar ${VERSION}" \
    --notes-file CHANGELOG.md
else
  echo "==> Skipping GitHub release (pass --publish to upload)"
fi

echo
echo "==> Done. Manual step left:"
echo "    1. Edit appcast.xml with the <enclosure> snippet above + a new <item> block."
echo "    2. git commit + push appcast.xml."
echo "    Existing installs will pick up the update within 24h."
