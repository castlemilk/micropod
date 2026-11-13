#!/bin/bash
# Build a separate signed setup app; never replace the running Micropod app.
set -euo pipefail
runtime_project="$(cd "$(dirname "$0")/.." && pwd)"
cd "$runtime_project"
runtime_configuration="${MICROPOD_RUNTIME_CONFIGURATION:-debug}"
runtime_identity="${MICROPOD_RUNTIME_SIGN_IDENTITY:?Set MICROPOD_RUNTIME_SIGN_IDENTITY to the Developer ID Application identity}"
runtime_app="$runtime_project/dist/Micropod Runtime Setup.app"
case "$runtime_configuration" in debug|release) ;; *) echo 'Unknown runtime build configuration' >&2; exit 1 ;; esac
swift build -c "$runtime_configuration" --product MicropodRuntimeHost
swift build -c "$runtime_configuration" --product MicropodRuntimeSetup
swift build -c "$runtime_configuration" --product MicropodAPI
mkdir -p "$runtime_project/dist"
runtime_stage_root="$(mktemp -d "$runtime_project/dist/runtime-setup.XXXXXX")"
runtime_stage="$runtime_stage_root/Micropod Runtime Setup.app"
trap 'rm -rf "$runtime_stage_root"' EXIT
mkdir -p "$runtime_stage/Contents/MacOS" "$runtime_stage/Contents/Resources" "$runtime_stage/Contents/Library/LaunchDaemons"
(cd guest && env -u GOROOT GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o "$runtime_stage/Contents/Resources/micropod-guest" .)
cp ".build/$runtime_configuration/MicropodRuntimeHost" "$runtime_stage/Contents/MacOS/"
cp ".build/$runtime_configuration/MicropodRuntimeSetup" "$runtime_stage/Contents/MacOS/"
cp ".build/$runtime_configuration/MicropodAPI" "$runtime_stage/Contents/MacOS/"
python3 - "$runtime_stage" <<'PY'
import pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1])
(root/'Contents/Info.plist').write_bytes(plistlib.dumps({
 'CFBundleIdentifier':'com.skunkworq.micropod.runtime-setup',
 'CFBundleExecutable':'MicropodRuntimeSetup','CFBundleName':'Micropod Runtime Setup',
 'CFBundleDisplayName':'Micropod Runtime Setup','CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1',
 'LSMinimumSystemVersion':'26.0','NSHighResolutionCapable':True,
 'NSSupportsAutomaticTermination':False,'NSSupportsSuddenTermination':False,
 'NSHumanReadableCopyright':'© 2026 skunkworq',
}))
(root/'Contents/Library/LaunchDaemons/com.skunkworq.micropod.runtime.host.plist').write_bytes(plistlib.dumps({
 'Label':'com.skunkworq.micropod.runtime.host',
 'BundleProgram':'Contents/MacOS/MicropodRuntimeHost',
 'MachServices':{'com.skunkworq.micropod.runtime.host':True},
 'RunAtLoad':True,'ProcessType':'Background','ThrottleInterval':10,
 'KeepAlive':{'SuccessfulExit':False},'Umask':0o077,
}))
(root.parent/'empty-entitlements.plist').write_bytes(plistlib.dumps({}))
PY
codesign --force --sign "$runtime_identity" --options runtime --timestamp --entitlements "$runtime_stage_root/empty-entitlements.plist" --identifier com.skunkworq.micropod.runtime.host "$runtime_stage/Contents/MacOS/MicropodRuntimeHost"
codesign --force --sign "$runtime_identity" --options runtime --timestamp --entitlements "$runtime_project/signing/micropod-cli.entitlements" --identifier com.skunkworq.micropod.api "$runtime_stage/Contents/MacOS/MicropodAPI"
codesign --force --sign "$runtime_identity" --options runtime --timestamp --entitlements "$runtime_stage_root/empty-entitlements.plist" --identifier com.skunkworq.micropod.runtime-setup "$runtime_stage/Contents/MacOS/MicropodRuntimeSetup"
rm "$runtime_stage_root/empty-entitlements.plist"
codesign --force --sign "$runtime_identity" --options runtime --timestamp "$runtime_stage"
codesign --verify --deep --strict "$runtime_stage"
# This path is solely the generated setup bundle, not the installed app.
if [[ -e "$runtime_app" ]]; then mv "$runtime_app" "$runtime_project/dist/RuntimeSetup.previous.$(date +%s).app"; fi
mv "$runtime_stage" "$runtime_app"
rmdir "$runtime_stage_root"
trap - EXIT
printf '%s\n' "$runtime_app"
if [[ -n "${MICROPOD_RUNTIME_NOTARY_PROFILE:-}" ]]; then
    runtime_notary_dir="$(mktemp -d /private/tmp/micropod-runtime-notary.XXXXXX)"
    runtime_notary_zip="$runtime_notary_dir/candidate.zip"
    trap 'rm -f "$runtime_notary_zip"; rmdir "$runtime_notary_dir"' EXIT
    /usr/bin/ditto -c -k --keepParent "$runtime_app" "$runtime_notary_zip"
    xcrun notarytool submit "$runtime_notary_zip" --keychain-profile "$MICROPOD_RUNTIME_NOTARY_PROFILE" --wait --timeout 10m --output-format json > "$runtime_project/dist/runtime-setup-notary.json"
    python3 - "$runtime_project/dist/runtime-setup-notary.json" <<'PYNOTARY'
import json,sys
result=json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept the runtime setup candidate')
print('Apple accepted the runtime setup candidate: '+result['id'])
PYNOTARY
    xcrun stapler staple "$runtime_app"
    xcrun stapler validate "$runtime_app"
    spctl --assess --type execute "$runtime_app"
    rm -f "$runtime_notary_zip"
    rmdir "$runtime_notary_dir"
    trap - EXIT
fi
