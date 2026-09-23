#!/bin/bash
# make_dmg.sh — package dist/Micropod.app into dist/Micropod.dmg.
#
#   scripts/make_dmg.sh [--sign "Developer ID Application: Name (TEAMID)"]
#                       [--notarize --key-profile PROFILE]
#
# Signing is opt-in so local builds still work unsigned. With --notarize,
# the signed DMG is submitted via `xcrun notarytool` (expects a stored
# keychain profile, e.g. created by CI with --key/--key-id/--issuer) and
# the ticket is stapled before shipping.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="dist/Micropod.app"
DMG="dist/Micropod.dmg"
STAGING="dist/.dmg-staging"
IDENTITY=""
NOTARIZE=0
PROFILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --sign) IDENTITY="$2"; shift 2 ;;
        --notarize) NOTARIZE=1; shift ;;
        --key-profile) PROFILE="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -d "$APP" ] || { echo "!! $APP missing — run scripts/package_app.sh first" >&2; exit 1; }

if [ -n "$IDENTITY" ]; then
    echo "==> Signing app bundle ($IDENTITY)"
    # Hardened runtime is required for notarization. Sign inside-out:
    # helper binaries first, then the bundle itself.
    for bin in "$APP"/Contents/MacOS/*; do
        codesign --force --options runtime --timestamp \
            --sign "$IDENTITY" "$bin"
    done
    # Sparkle.framework (SwiftPM artifact ships unsigned): XPC services and
    # helper apps first, then the framework dylib + bundle.
    FW="$APP/Contents/Frameworks/Sparkle.framework"
    if [ -d "$FW" ]; then
        for piece in "$FW"/Versions/B/XPCServices/*.xpc \
            "$FW"/Versions/B/Updater.app "$FW"/Versions/B/Autoupdate; do
            [ -e "$piece" ] && codesign --force --options runtime --timestamp \
                --sign "$IDENTITY" "$piece"
        done
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW"
    fi
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "==> Staging DMG contents"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "==> Building $DMG"
rm -f "$DMG"
hdiutil create -volname Micropod -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

if [ -n "$IDENTITY" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

if [ "$NOTARIZE" = "1" ]; then
    [ -n "$PROFILE" ] || { echo "!! --notarize needs --key-profile <profile>" >&2; exit 1; }
    echo "==> Notarizing (profile: $PROFILE)"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
ls -lh "$DMG"
echo "Done."
