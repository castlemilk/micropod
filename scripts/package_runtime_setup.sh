#!/bin/bash
# Build a separate signed setup app; never replace the running Micropod app.
set -euo pipefail
runtime_project="$(cd "$(dirname "$0")/.." && pwd)"
cd "$runtime_project"
runtime_configuration="${MICROPOD_RUNTIME_CONFIGURATION:-debug}"
runtime_identity="${MICROPOD_RUNTIME_SIGN_IDENTITY:?Set MICROPOD_RUNTIME_SIGN_IDENTITY to the Developer ID Application identity}"
runtime_app="${MICROPOD_RUNTIME_OUTPUT:-$runtime_project/dist/Micropod Runtime Setup.app}"
case "$runtime_configuration" in debug|release) ;; *) echo 'Unknown runtime build configuration' >&2; exit 1 ;; esac
# The setup app reports the release it was packaged from. Packaging passes
# the desktop app's version and revision; a standalone build reports 0.0.0,
# which is never a release, with this checkout's revision.
runtime_version="${MICROPOD_RUNTIME_VERSION:-0.0.0}"
runtime_source_revision="${MICROPOD_RUNTIME_SOURCE_REVISION:-$(git -C "$runtime_project" rev-parse HEAD 2>/dev/null || echo unknown)}"
if [[ ! "$runtime_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    echo "MICROPOD_RUNTIME_VERSION must be a release version such as 0.14.0" >&2
    exit 1
fi
if [[ ! "$runtime_source_revision" =~ ^([0-9a-f]{40}|unknown)$ ]]; then
    echo "MICROPOD_RUNTIME_SOURCE_REVISION must be a full git revision" >&2
    exit 1
fi
if [[ "${MICROPOD_RUNTIME_SKIP_BUILD:-0}" != 1 ]]; then
    swift build -c "$runtime_configuration" --product MicropodRuntimeHost
    swift build -c "$runtime_configuration" --product MicropodRuntimeSetup
    swift build -c "$runtime_configuration" --product MicropodAPI
fi
mkdir -p "$runtime_project/dist"
runtime_stage_root="$(mktemp -d "$runtime_project/dist/runtime-setup.XXXXXX")"
runtime_stage="$runtime_stage_root/Micropod Runtime Setup.app"
trap 'rm -rf "$runtime_stage_root"' EXIT
mkdir -p "$runtime_stage/Contents/MacOS" "$runtime_stage/Contents/Resources" "$runtime_stage/Contents/Library/LaunchDaemons"
if [[ -n "${MICROPOD_RUNTIME_GUEST_TOOL:-}" ]]; then
    cp "$MICROPOD_RUNTIME_GUEST_TOOL" "$runtime_stage/Contents/Resources/micropod-guest"
else
    (cd guest && env -u GOROOT GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o "$runtime_stage/Contents/Resources/micropod-guest" .)
fi
cp ".build/$runtime_configuration/MicropodRuntimeHost" "$runtime_stage/Contents/MacOS/"
cp ".build/$runtime_configuration/MicropodRuntimeSetup" "$runtime_stage/Contents/MacOS/"
cp ".build/$runtime_configuration/MicropodAPI" "$runtime_stage/Contents/MacOS/"
python3 - "$runtime_stage" "$runtime_version" "$runtime_source_revision" <<'PY'
import pathlib,plistlib,sys
root=pathlib.Path(sys.argv[1])
version,revision=sys.argv[2],sys.argv[3]
(root/'Contents/Info.plist').write_bytes(plistlib.dumps({
 'CFBundleIdentifier':'com.skunkworq.micropod.runtime-setup',
 'CFBundleExecutable':'MicropodRuntimeSetup','CFBundleName':'Micropod Runtime Setup',
 'CFBundleDisplayName':'Micropod Runtime Setup','CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':version,'CFBundleVersion':version,
 'MicropodSourceRevision':revision,
 'LSMinimumSystemVersion':'26.0','NSHighResolutionCapable':True,
 'NSSupportsAutomaticTermination':False,'NSSupportsSuddenTermination':False,
 'NSHumanReadableCopyright':'© 2026 skunkworq',
}))
# The legacy SMAppService definition, byte-identical to earlier releases.
# Nothing registers it any more: a rig that still has the legacy job keeps
# it pointing at this bundle, whose helper yields to the root-owned runtime
# authority (a classic LaunchDaemon compiled into the helper, see
# docs/runtime-component-update.md), and Runtime Setup unregisters it.
(root/'Contents/Library/LaunchDaemons/com.skunkworq.micropod.runtime.host.plist').write_bytes(plistlib.dumps({
 'Label':'com.skunkworq.micropod.runtime.host',
 'BundleProgram':'Contents/MacOS/MicropodRuntimeHost',
 'MachServices':{'com.skunkworq.micropod.runtime.host':True},
 'RunAtLoad':True,'ProcessType':'Background','ThrottleInterval':10,
 'KeepAlive':{'SuccessfulExit':False},'Umask':0o077,
}))
(root.parent/'empty-entitlements.plist').write_bytes(plistlib.dumps({}))
PY
runtime_signature_options=(--options runtime)
if [[ "$runtime_identity" != - ]]; then runtime_signature_options+=(--timestamp); fi
codesign --force --sign "$runtime_identity" "${runtime_signature_options[@]}" --entitlements "$runtime_stage_root/empty-entitlements.plist" --identifier com.skunkworq.micropod.runtime-authority "$runtime_stage/Contents/MacOS/MicropodRuntimeHost"
codesign --force --sign "$runtime_identity" "${runtime_signature_options[@]}" --entitlements "$runtime_project/signing/micropod-cli.entitlements" --identifier com.skunkworq.micropod.api "$runtime_stage/Contents/MacOS/MicropodAPI"
codesign --force --sign "$runtime_identity" "${runtime_signature_options[@]}" --entitlements "$runtime_stage_root/empty-entitlements.plist" --identifier com.skunkworq.micropod.runtime-setup "$runtime_stage/Contents/MacOS/MicropodRuntimeSetup"
rm "$runtime_stage_root/empty-entitlements.plist"
codesign --force --sign "$runtime_identity" "${runtime_signature_options[@]}" "$runtime_stage"
codesign --verify --deep --strict "$runtime_stage"
# This path is solely the generated setup bundle, not the installed app.
if [[ -e "$runtime_app" ]]; then mv "$runtime_app" "$runtime_project/dist/RuntimeSetup.previous.$(uuidgen).app"; fi
mkdir -p "$(dirname "$runtime_app")"
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
