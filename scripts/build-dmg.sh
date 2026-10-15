#!/usr/bin/env bash
# Builds a Release StickyNotch.app, packages build/releases/StickyNotch-<version>.dmg and (when
# FEED_BASE_URL is set) writes a signed build/releases/appcast.xml for Sparkle updates.
#
#   scripts/build-dmg.sh                       # version/build number from the Xcode project
#   VERSION=1.1 BUILD=2 scripts/build-dmg.sh   # next release: BUILD must go up every time
#
# Then upload the new DMG and appcast.xml to FEED_BASE_URL, or set SITE_DIR to the folder GitHub Pages
# serves (docs/ in this repo) and they're copied there for you to commit and push:
#   FEED_BASE_URL=https://arsallls.github.io/StickyNotch/ SITE_DIR=docs scripts/build-dmg.sh
#
# Signing: set SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" for a build that opens
# without Gatekeeper warnings (then notarize the DMG). Default "-" = ad-hoc (users must approve
# the app in System Settings → Privacy & Security on first launch).
set -euo pipefail

# Folder on your website that will hold the DMGs and appcast.xml (must end with "/").
# Empty = build without updates.
FEED_BASE_URL="${FEED_BASE_URL:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
RELEASES="$BUILD_DIR/releases" # keep old DMGs here: generate_appcast lists every version it finds
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
# Hardened runtime requires app + bundled frameworks to share a Team ID, which ad-hoc signing never has
# (the app would refuse to load MediaRemoteAdapter). It's needed for notarization, so only Developer ID keeps it.
HARDENED=$([ "$SIGN_IDENTITY" = "-" ] && echo NO || echo YES)

EXTRA=()
[ -n "${VERSION:-}" ] && EXTRA+=("MARKETING_VERSION=$VERSION")
[ -n "${BUILD:-}" ] && EXTRA+=("CURRENT_PROJECT_VERSION=$BUILD")
FEED_URL=""
[ -n "$FEED_BASE_URL" ] && FEED_URL="${FEED_BASE_URL}appcast.xml"

# Stripping drops debug-map paths (they contain your home folder and username) from the shipped binaries.
xcodebuild -project "$ROOT/boringNotch.xcodeproj" -scheme boringNotch -configuration Release \
  -derivedDataPath "$BUILD_DIR/DerivedData" -skipMacroValidation -skipPackagePluginValidation \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO ENABLE_HARDENED_RUNTIME="$HARDENED" \
  STICKYNOTCH_FEED_URL="$FEED_URL" ${EXTRA[@]+"${EXTRA[@]}"} \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=non-global DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="" build | grep -E 'error:|\*\* BUILD'

APP="$BUILD_DIR/DerivedData/Build/Products/Release/StickyNotch.app"
# Xcode doesn't strip the embedded XPC helper: strip it and re-sign it, then the app around it
HELPER="$APP/Contents/XPCServices/BoringNotchXPCHelper.xpc"
strip -S -x "$HELPER/Contents/MacOS/BoringNotchXPCHelper"
codesign --force --preserve-metadata=entitlements,requirements,flags,runtime -s "$SIGN_IDENTITY" "$HELPER"
codesign --force --preserve-metadata=entitlements,requirements,flags,runtime -s "$SIGN_IDENTITY" "$APP"
if LC_ALL=C grep -rqa "$HOME" "$APP"; then echo "error: $APP still contains $HOME paths" >&2; exit 1; fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
mkdir -p "$RELEASES"
DMG="$RELEASES/StickyNotch-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# GPL-3.0: ship the license (and where the source is) with every copy of the binary
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_LICENSES" "$STAGE/THIRD_PARTY_LICENSES.txt"
printf "StickyNotch is free software under the GNU GPL v3 (see LICENSE.txt), a modified version of boring.notch.\nSource code: https://github.com/arsallls/StickyNotch\nThird-party licenses: THIRD_PARTY_LICENSES.txt\n" > "$STAGE/Source Code.txt"

rm -f "$DMG"
hdiutil create -volname "StickyNotch" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"

if [ -n "$FEED_BASE_URL" ]; then
  # Signs every DMG with the "stickynotch" key from your Keychain and (re)writes appcast.xml
  "$BUILD_DIR/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    --account stickynotch --download-url-prefix "$FEED_BASE_URL" "$RELEASES"
  if [ -n "${SITE_DIR:-}" ]; then
    cp "$DMG" "$RELEASES/appcast.xml" "$SITE_DIR/"
    echo "Copied $(basename "$DMG") and appcast.xml into $SITE_DIR — commit and push it to publish."
  else
    echo "Upload $(basename "$DMG") and appcast.xml from $RELEASES to $FEED_BASE_URL"
  fi
else
  echo "FEED_BASE_URL not set: this build has updates switched off."
fi
