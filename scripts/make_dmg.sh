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
        entitlements=()
        case "$(basename "$bin")" in
            MicropodAPI | micropod-cli) entitlements=(--entitlements "$ROOT/signing/micropod-cli.entitlements") ;;
            micropod-vmm) entitlements=(--entitlements "$ROOT/signing/micropod-vmm.entitlements") ;;
        esac
        identifiers=()
        case "$(basename "$bin")" in
            MicropodRuntimeHost) identifiers=(--identifier com.skunkworq.micropod.runtime-authority) ;;
            MicropodAPI) identifiers=(--identifier com.skunkworq.micropod.api) ;;
            micropod-cli) identifiers=(--identifier com.skunkworq.micropod.cli) ;;
            micropod-vmm) identifiers=(--identifier com.skunkworq.micropod.vmm) ;;
            MicropodMCP) identifiers=(--identifier com.skunkworq.micropod.mcp) ;;
            micropod-docker-shim) identifiers=(--identifier com.skunkworq.micropod.docker-shim) ;;
            micropod-sharedfs) identifiers=(--identifier com.skunkworq.micropod.sharedfs) ;;
        esac
        codesign --force --options runtime --timestamp ${identifiers[@]+"${identifiers[@]}"} ${entitlements[@]+"${entitlements[@]}"} \
            --sign "$IDENTITY" "$bin"
    done
    # Re-sign the setup app as the same release the desktop bundle declares.
    MICROPOD_RUNTIME_CONFIGURATION=release MICROPOD_RUNTIME_SIGN_IDENTITY="$IDENTITY" \
        MICROPOD_RUNTIME_SKIP_BUILD=1 \
        MICROPOD_RUNTIME_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" \
        MICROPOD_RUNTIME_SOURCE_REVISION="$(/usr/libexec/PlistBuddy -c 'Print :MicropodSourceRevision' "$APP/Contents/Info.plist")" \
        MICROPOD_RUNTIME_OUTPUT="$ROOT/$APP/Contents/Helpers/Micropod Runtime Setup.app" \
        MICROPOD_RUNTIME_GUEST_TOOL="$ROOT/$APP/Contents/Resources/micropod-guest" \
        bash scripts/package_runtime_setup.sh
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
    # The setup app's signature is final now: pin it in the signed runtime
    # component manifest before the outer seal covers the manifest.
    bash "$ROOT/scripts/write_runtime_components.sh" "$APP"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    vmm="$APP/Contents/MacOS/micropod-vmm"
    if [ -f "$vmm" ]; then
        if ! codesign --display --entitlements - --xml "$vmm" 2>/dev/null | python3 -c '
import plistlib, sys
data = sys.stdin.buffer.read()
sys.exit(not data or plistlib.loads(data).get("com.apple.security.hypervisor") is not True)
'; then
            echo "!! $vmm is missing the signed Hypervisor.framework entitlement" >&2
            exit 1
        fi
    fi
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

# Bare filename in the sidecar so `shasum -c` works next to the downloaded DMG.
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")") | tee "$DMG.sha256"
ls -lh "$DMG"
echo "Done."
