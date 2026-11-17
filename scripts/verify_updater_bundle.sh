#!/bin/bash
# Check the signed producer contract before any qualification asset is uploaded.
set -euo pipefail
updater_bundle="${1:?app bundle}"
updater_version="${2:?version}"
updater_source="${3:?source revision}"
updater_info="$updater_bundle/Contents/Info.plist"
updater_policy="$(cd "$(dirname "$0")/.." && pwd)/release/updater-policy.json"
[[ "$updater_source" =~ ^[0-9a-f]{40}$ ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MicropodWorkloadProtocol' "$updater_info")" = "$(jq -er .workloadProtocol "$updater_policy")" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MicropodMinimumUpdateVersion' "$updater_info")" = "$(jq -er .minimumUpdateVersion "$updater_policy")" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$updater_info")" = "$updater_version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MicropodSourceRevision' "$updater_info")" = "$updater_source" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$updater_info")" = 'nJEL+JijqhfC7zxPlqxifCqBM06A3DGki/JmBFTW/VM=' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUAllowsAutomaticUpdates' "$updater_info")" = true ]]
updater_setup="$updater_bundle/Contents/Helpers/Micropod Runtime Setup.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$updater_setup/Contents/Info.plist")" = com.skunkworq.micropod.runtime-setup ]]
# The setup app reports the release it shipped in (Ping's setup-helper component).
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$updater_setup/Contents/Info.plist")" = "$updater_version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :MicropodSourceRevision' "$updater_setup/Contents/Info.plist")" = "$updater_source" ]]
[[ -x "$updater_setup/Contents/MacOS/MicropodRuntimeHost" ]]
[[ -x "$updater_setup/Contents/MacOS/MicropodAPI" ]]
[[ -f "$updater_setup/Contents/Resources/micropod-guest" ]]
codesign --verify --deep --strict "$updater_bundle"
codesign --verify --deep --strict "$updater_setup"
