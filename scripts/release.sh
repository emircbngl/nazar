#!/usr/bin/env bash
#
# End-to-end release helper:
#   1. Bump CFBundleVersion in Info.plist (Sparkle's canonical build number)
#   2. Build, sign (Developer ID), notarize, staple → build/Nazar-VERSION.dmg
#   3. EdDSA-sign the DMG (Sparkle) and print a ready-to-paste appcast snippet
#   4. Optionally publish a GitHub Release with the DMG attached
#
# Then you manually edit appcast.xml with the new <item> and push.
#
# Usage:
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#     ./scripts/release.sh [--publish]
#
# Before running, bump CFBundleShortVersionString in Nazar/Info.plist if you
# haven't already (e.g. 1.0.0 → 1.0.1). This script then auto-increments
# CFBundleVersion so Sparkle's SUStandardVersionComparator can detect the new
# build — without it, every release looks identical to the running install.
#
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:?Set IDENTITY env var to your Developer ID Application identity}"
PUBLISH="${1:-}"

# --- Step 0: derive version + bump build number ------------------------------

# `set -e` does NOT abort on failed $(...) in assignments, so we capture then
# explicitly guard.
VERSION=""
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Nazar/Info.plist) \
  || { echo "ERROR: could not read CFBundleShortVersionString from Info.plist" >&2; exit 1; }
[ -n "$VERSION" ] || { echo "ERROR: CFBundleShortVersionString is empty" >&2; exit 1; }

BUILD=""
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Nazar/Info.plist) \
  || { echo "ERROR: could not read CFBundleVersion from Info.plist" >&2; exit 1; }
[ -n "$BUILD" ] || { echo "ERROR: CFBundleVersion is empty" >&2; exit 1; }

NEW_BUILD=$((BUILD + 1))
echo "==> Step 0/4: bumping CFBundleVersion $BUILD → $NEW_BUILD (short version: $VERSION)"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $NEW_BUILD" Nazar/Info.plist

DMG="build/Nazar-${VERSION}.dmg"

# --- Step 1: build, sign, notarize -------------------------------------------

echo
echo "==> Step 1/4: notarize"
./scripts/notarize.sh

# --- Step 2: Sparkle EdDSA signing -------------------------------------------

echo
echo "==> Step 2/4: Sparkle signing"
if [ ! -x scripts/sparkle/bin/sign_update ]; then
  echo "Sparkle tools missing — running setup."
  ./scripts/setup_sparkle.sh
fi

SIG_LINE=""
SIG_LINE=$(./scripts/sparkle/bin/sign_update "$DMG") \
  || { echo "ERROR: sign_update failed — aborting before generating broken enclosure" >&2; exit 1; }
[ -n "$SIG_LINE" ] || { echo "ERROR: sign_update returned empty signature line" >&2; exit 1; }

# Sanity check: sign_update output must contain sparkle:edSignature
case "$SIG_LINE" in
  *sparkle:edSignature*) ;;
  *)
    echo "ERROR: sign_update output doesn't look like a Sparkle signature line:" >&2
    echo "  $SIG_LINE" >&2
    exit 1
    ;;
esac

DMG_SIZE=$(/usr/bin/stat -f%z "$DMG")

echo
echo "Add this to appcast.xml's new <item>:"
echo
echo "    <enclosure"
echo "      url=\"https://github.com/emircbngl/nazar/releases/download/v${VERSION}/Nazar-${VERSION}.dmg\""
echo "      sparkle:version=\"${NEW_BUILD}\""
echo "      sparkle:shortVersionString=\"${VERSION}\""
echo "      length=\"${DMG_SIZE}\""
echo "      $SIG_LINE"
echo "      type=\"application/octet-stream\" />"
echo

# --- Step 3: optional GitHub Release ----------------------------------------

if [ "$PUBLISH" = "--publish" ]; then
  echo "==> Step 3/4: gh release create v${VERSION}"
  gh release create "v${VERSION}" "$DMG" \
    --title "Nazar ${VERSION}" \
    --notes-file CHANGELOG.md
else
  echo "==> Skipping GitHub release (pass --publish to upload)"
fi

echo
echo "==> Step 4/4: Manual steps left:"
echo "    1. Edit appcast.xml with the <enclosure> snippet above + a new <item> block."
echo "    2. git add Nazar/Info.plist appcast.xml; git commit -m \"Release v${VERSION}\"; git push"
echo "    Existing installs pick up the update within 24h."
