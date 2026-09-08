#!/bin/bash
# Builds a Release archive and packages Postfrau.app into a DMG under dist/.
#
# Signing: uses $CODESIGN_IDENTITY when set (e.g. "Developer ID Application: …"),
# otherwise falls back to ad-hoc signing ("-"), which works without an Apple
# Developer account. Notarization runs only when NOTARY_PROFILE is set.
set -euo pipefail
cd "$(dirname "$0")/.."

XCODEGEN=$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)
"$XCODEGEN" generate --quiet

IDENTITY="${CODESIGN_IDENTITY:--}"
DIST="dist"
ARCHIVE="$DIST/Postfrau.xcarchive"
APPDIR="$DIST/root"
VERSION=$(awk -F': ' '/MARKETING_VERSION/{gsub(/"/,"",$2); print $2; exit}' project.yml)
DMG="$DIST/Postfrau-$VERSION.dmg"

rm -rf "$DIST"
mkdir -p "$DIST" "$APPDIR"

echo "▸ Archiving (identity: $IDENTITY)…"
xcodebuild -project Postfrau.xcodeproj -scheme Postfrau -configuration Release \
  -destination 'platform=macOS' -archivePath "$ARCHIVE" archive \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  ENABLE_HARDENED_RUNTIME=YES \
  2>&1 | grep -E "(error|warning): |^\*\* [A-Z]+ (SUCCEEDED|FAILED)" || true

APP="$ARCHIVE/Products/Applications/Postfrau.app"
[ -d "$APP" ] || { echo "Archive did not produce $APP" >&2; exit 1; }

# The command line tool ships inside the bundle, where Settings ▸ Advanced symlinks it from.
# Contents/Helpers, never Contents/MacOS: macOS filesystems are case-insensitive, so a file
# called `postfrau` beside the app's own `Postfrau` executable overwrites it.
echo "▸ Building the command line tool…"
( cd Packages/PostfrauCore && swift build -c release --product postfrau >/dev/null )
CLI="$(cd Packages/PostfrauCore && swift build -c release --show-bin-path)/postfrau"
mkdir -p "$APP/Contents/Helpers"
cp "$CLI" "$APP/Contents/Helpers/postfrau"

# Adding a binary invalidates the archive's signature, so the helper is signed and then the whole
# bundle is signed again. Ad-hoc ("-") works without a Developer account, which is the default.
codesign --force --options runtime --timestamp=none \
  --sign "$IDENTITY" "$APP/Contents/Helpers/postfrau"
codesign --force --options runtime --timestamp=none \
  --entitlements Postfrau/Resources/Postfrau.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" || {
  echo "The signed app does not verify." >&2; exit 1; }

cp -R "$APP" "$APPDIR/Postfrau.app"
ln -s /Applications "$APPDIR/Applications"

echo "▸ Building DMG…"
hdiutil create -volname "Postfrau" -srcfolder "$APPDIR" -ov -format UDZO "$DMG" >/dev/null

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "▸ Notarizing with profile $NOTARY_PROFILE…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

rm -rf "$APPDIR"
echo "$DMG"
