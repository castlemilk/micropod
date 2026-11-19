#!/bin/bash
# Writes Contents/Resources/runtime-components.json, and its release-key
# signature (.sig), into a desktop app whose nested Micropod Runtime
# Setup.app already carries its final signature. scripts/make_dmg.sh runs it
# after signing the setup app and before signing the outer bundle, so the
# outer seal covers both files. See docs/runtime-component-update.md.
#
# Signing needs SPARKLE_SIGN_UPDATE (Sparkle's sign_update) and
# SPARKLE_ED_KEY_FILE. Without them no .sig is written, and the root helper
# will refuse to self-update from this build.
set -euo pipefail
app="${1:?usage: write_runtime_components.sh <Micropod.app>}"
setup="$app/Contents/Helpers/Micropod Runtime Setup.app"
daemon="$setup/Contents/Library/LaunchDaemons/com.skunkworq.micropod.runtime.host.plist"
resources="$app/Contents/Resources"
manifest="$resources/runtime-components.json"
[ -d "$setup" ] || { echo "!! $setup is missing" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
cdhash=$(codesign -dvvv "$setup" 2>&1 | sed -n 's/^CDHash=//p' | head -1)
[ "${#cdhash}" = 40 ] || { echo "!! no code directory hash for $setup" >&2; exit 1; }
guest="$setup/Contents/Resources/micropod-guest"
guest_sha=""
if [ -f "$guest" ]; then guest_sha=$(sha "$guest"); fi
# The staged helper reports its own release table; its first entry is the
# Apple build this release installs.
probe=$("$setup/Contents/MacOS/MicropodRuntimeHost" --component-probe)
python3 - "$manifest" "$setup/Contents/Info.plist" "$cdhash" "$(sha "$daemon")" \
    "$(sha "$setup/Contents/MacOS/MicropodRuntimeHost")" "$(sha "$setup/Contents/MacOS/MicropodAPI")" \
    "$guest_sha" "$probe" "${MICROPOD_COMPONENTS_MINIMUM_HELPER:-0.13.10}" <<'PY'
import json, plistlib, sys
out, info, cdhash, daemon, helper, api, guest, probe, minimum = sys.argv[1:]
info = plistlib.load(open(info, "rb"))
probe = json.loads(probe)
if probe["version"] != info["CFBundleShortVersionString"] or probe["revision"] != info["MicropodSourceRevision"]:
    raise SystemExit("the probed helper's compiled-in release is not this setup app's (stamp MicropodBuildInfo)")
runtimes = probe["appleRuntimes"]
manifest = {
    "schema": "micropod-runtime-components-v1",
    "componentProtocol": probe["componentProtocol"],
    "version": info["CFBundleShortVersionString"],
    "sourceRevision": info["MicropodSourceRevision"],
    "minimumHelperVersion": minimum,
    "setup": {"bundleIdentifier": "com.skunkworq.micropod.runtime-setup", "cdhash": cdhash.lower(),
              "daemonPlistSHA256": daemon},
    "helper": {"identifier": "com.skunkworq.micropod.runtime-authority", "sha256": helper},
    "api": {"identifier": "com.skunkworq.micropod.api", "sha256": api},
    "appleRuntime": runtimes[0],
    "appleRuntimes": runtimes,
}
floor = __import__("os").environ.get("MICROPOD_COMPONENTS_SECURITY_FLOOR")
if floor:
    manifest["securityFloor"] = floor
if guest:
    manifest["guestSHA256"] = guest
open(out, "w").write(json.dumps(manifest, sort_keys=True, separators=(",", ":")))
PY
rm -f "$manifest.sig"
if [ -n "${SPARKLE_SIGN_UPDATE:-}" ] && [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then
    signature=$("$SPARKLE_SIGN_UPDATE" --ed-key-file "$SPARKLE_ED_KEY_FILE" "$manifest" \
        | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
    [ -n "$signature" ] || { echo "!! sign_update printed no signature" >&2; exit 1; }
    printf '%s\n' "$signature" > "$manifest.sig"
    echo "==> Runtime components $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$setup/Contents/Info.plist") signed (setup CDHash $cdhash)"
else
    echo "!! No release signing key: runtime-components.json is unsigned; rigs will not self-update from this build"
fi
