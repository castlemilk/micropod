#!/usr/bin/env bash
set -euo pipefail

# Exercise the production window scene in an isolated native app. Never launch
# Micropod, its runtime, helpers, or jobs. Requires a logged-in macOS GUI session.
repo=$(cd "$(dirname "$0")/.." && pwd)
output=${1:-$(mktemp -d "${TMPDIR:-/tmp}/micropod-window-qa.XXXXXX")}
mkdir -p "$output"
output=$(cd "$output" && pwd)
bundle="$output/WindowQA.app"
mkdir -p "$bundle/Contents/MacOS" "$output/module-cache"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.skunkworq.micropod.windowqa</string>
<key>CFBundleExecutable</key><string>WindowQA</string>
<key>CFBundleName</key><string>Micropod Window QA</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>qa</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSUIElement</key><false/>
</dict></plist>
PLIST

swiftc -parse-as-library -swift-version 6 \
  -module-cache-path "$output/module-cache" \
  "$repo/Sources/MicropodApp/Support/MainWindowPresenter.swift" \
  "$repo/scripts/main_window_smoke.swift" \
  -o "$bundle/Contents/MacOS/WindowQA"

# Bound startup and native lifecycle checks. A timeout stops only this QA app.
python3 - "$bundle/Contents/MacOS/WindowQA" "$output" <<'PY'
import os
import subprocess
import sys

binary, output = sys.argv[1:]
environment = os.environ.copy()
environment["MICROPOD_WINDOW_QA_DIR"] = output
try:
    result = subprocess.run([binary], env=environment, timeout=45, check=False)
except subprocess.TimeoutExpired:
    print("Native window QA timed out; its own process was stopped.", file=sys.stderr)
    sys.exit(1)
sys.exit(result.returncode)
PY

cat "$output/result.json"
printf '\nNative window evidence: %s\n' "$output"
