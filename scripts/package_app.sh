#!/bin/bash
# Assemble release .app bundles for Micropod (desktop) + MicropodMCP (STDIO server).
# Produces dist/Micropod.app, dist/micropod-mcp (wrapped), dist/Micropod.brew.tgz.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Micropod"
VERSION="${1:-0.1.0}"
BUNDLE_ID="com.skunkworq.micropod"
DIST="dist"

# Stamp the version into the CLI and MCP binaries for this build only.
# (The backup lives outside the target: SwiftPM warns about stray files.)
BUILD_INFO="Sources/MicropodBuildInfo/BuildInfo.swift"
BUILD_INFO_ORIG="$(mktemp)"
cp "$BUILD_INFO" "$BUILD_INFO_ORIG"
trap 'cp "$BUILD_INFO_ORIG" "$BUILD_INFO" && rm -f "$BUILD_INFO_ORIG"' EXIT
sed -i '' "s/static let version = \"dev\"/static let version = \"$VERSION\"/" "$BUILD_INFO"
grep -q "\"$VERSION\"" "$BUILD_INFO" || { echo "!! failed to stamp $BUILD_INFO"; exit 1; }

echo "==> Building release (swift build -c release)"
swift build -c release

echo "==> Assembling $APP_NAME.app"
APP_BUNDLE="$DIST/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

# App icon: use the uplift vector master/icon, retaining the previous icon as fallback.
if [ -f "$ROOT/assets/logo/Micropod-uplift.icns" ]; then
    cp "$ROOT/assets/logo/Micropod-uplift.icns" "$APP_BUNDLE/Contents/Resources/Micropod.icns"
    echo "==> Icon: Micropod uplift pod/terminal mark"
elif [ -f "$ROOT/assets/logo/Micropod.icns" ]; then
    cp "$ROOT/assets/logo/Micropod.icns" "$APP_BUNDLE/Contents/Resources/Micropod.icns"
    echo "==> Icon: BrandBrain brand mark (assets/logo/Micropod.icns)"
else
    ICON_ICNS="$(swift scripts/make_icon.swift "$DIST/icon-build" | tail -1)"
    cp "$ICON_ICNS" "$APP_BUNDLE/Contents/Resources/Micropod.icns"
    echo "==> Icon: fallback programmatic icon"
fi

# Write directly instead of a large heredoc: Bash versions that implement
# heredocs with a small pipe can block before the reader is executed.
python3 -c '
import pathlib, plistlib, sys
path, name, version, identifier = sys.argv[1:]
metadata = {
    "CFBundleName": name,
    "CFBundleDisplayName": name,
    "CFBundleExecutable": name,
    "CFBundleIdentifier": identifier,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": version,
    "CFBundleVersion": version,
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleDevelopmentRegion": "en",
    "CFBundleAllowMixedLocalizations": True,
    "CFBundleIconFile": "Micropod",
    "LSMinimumSystemVersion": "26.0",
    "LSApplicationCategoryType": "public.app-category.developer-tools",
    "NSHighResolutionCapable": True,
    "LSUIElement": False,
    "NSSupportsAutomaticTermination": False,
    "NSSupportsSuddenTermination": False,
    "SUFeedURL": "https://castlemilk.github.io/micropod/appcast.xml",
    "SUPublicEDKey": "nJEL+JijqhfC7zxPlqxifCqBM06A3DGki/JmBFTW/VM=",
    "SUEnableAutomaticChecks": True,
    "SUScheduledCheckInterval": "3600",
    "NSHumanReadableCopyright": "© 2026 skunkworq",
}
pathlib.Path(path).write_bytes(plistlib.dumps(metadata, sort_keys=False))
' "$APP_BUNDLE/Contents/Info.plist" "$APP_NAME" "$VERSION" "$BUNDLE_ID"

cp .build/release/MicropodApp "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Sparkle self-update framework: SwiftPM resolves it into the build dir at
# @loader_path; the .app layout puts it in Contents/Frameworks, so add that
# rpath. (update appcast signing: Sparkle EdDSA key, see docs/releasing.md)
SPARKLE_FW="$(find .build/release -name "Sparkle.framework" -maxdepth 1 | head -1)"
if [ -z "$SPARKLE_FW" ]; then
    SPARKLE_FW="$(find .build -name "Sparkle.framework" -path "*release*" | head -1)"
fi
if [ -n "$SPARKLE_FW" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    cp -R "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    echo "==> Sparkle.framework bundled (auto-update via appcast feed)"
else
    echo "!! Sparkle.framework not found — auto-update disabled in this build"
fi

# SwiftPM resource bundle (icons, brandbrain assets, Localizable.xcstrings):
# must live under Contents/Resources — anything at the .app root makes
# codesign fail with "unsealed contents". Bundle.micropodResources finds it.
if [ -d ".build/release/Micropod_MicropodApp.bundle" ]; then
    cp -R ".build/release/Micropod_MicropodApp.bundle" "$APP_BUNDLE/Contents/Resources/Micropod_MicropodApp.bundle"
    echo "==> Resource bundle: Micropod_MicropodApp.bundle (brandbrain + strings catalog)"
fi

codesign --force --sign - "$APP_BUNDLE" 2>/dev/null || true

echo "==> Wrapping MicropodMCP (STDIO server)"
cp .build/release/MicropodMCP "$DIST/micropod-mcp-bin"
cat > "$DIST/micropod-mcp" <<WRAP
#!/bin/bash
# MCP STDIO server for Micropod. Register as:
#   "mcpServers": { "micropod": { "command": "$DIST/micropod-mcp" } }
exec "$(cd "$DIST" && pwd)/micropod-mcp-bin" "\$@"
WRAP
chmod +x "$DIST/micropod-mcp" "$DIST/micropod-mcp-bin"

# Bundle the Docker Engine API shim inside the .app so the app can auto-start
# it — external agents (cuttlefish runner, Testcontainers, docker CLI) speak
# Docker API over ~/.micropod/docker.sock.
if [ -f ".build/release/micropod-docker-shim" ]; then
    cp .build/release/micropod-docker-shim "$APP_BUNDLE/Contents/MacOS/micropod-docker-shim"
    chmod +x "$APP_BUNDLE/Contents/MacOS/micropod-docker-shim"
    cp .build/release/micropod-docker-shim "$DIST/micropod-docker-shim-bin"
    chmod +x "$DIST/micropod-docker-shim-bin"
    echo "==> Docker shim bundled (micropod-docker-shim)"
else
    echo "!! micropod-docker-shim not found in .build/release — shim auto-start disabled"
fi

# Bundle the local HTTP API server — the app supervises it as a managed
# agent (spawn on bootstrap, health-probe /health, restart on death,
# terminate on quit) so scripts/curl have 127.0.0.1:45454 whenever the app runs.
if [ -f ".build/release/MicropodAPI" ]; then
    cp .build/release/MicropodAPI "$APP_BUNDLE/Contents/MacOS/MicropodAPI"
    chmod +x "$APP_BUNDLE/Contents/MacOS/MicropodAPI"
    cp .build/release/MicropodAPI "$DIST/micropod-api-bin"
    chmod +x "$DIST/micropod-api-bin"
    # The sandbox runtime boots micro-VMs inside the API process.
    for api in "$APP_BUNDLE/Contents/MacOS/MicropodAPI" "$DIST/micropod-api-bin"; do
        codesign --force --sign - --entitlements signing/micropod-cli.entitlements "$api"
    done
    echo "==> HTTP API server bundled (MicropodAPI)"
else
    echo "!! MicropodAPI not found in .build/release — API agent disabled"
fi

# The CLI and MCP server ride in the bundle so Sparkle updates them with the
# app, which links ~/.local/bin/micropod and micropod-mcp to these at launch.
# `micropod-cli`, not `micropod`: a case-insensitive volume would make that the
# app's own `Micropod` executable.
cp .build/release/micropod "$APP_BUNDLE/Contents/MacOS/micropod-cli"
cp .build/release/MicropodMCP "$APP_BUNDLE/Contents/MacOS/MicropodMCP"
chmod +x "$APP_BUNDLE/Contents/MacOS/micropod-cli" "$APP_BUNDLE/Contents/MacOS/MicropodMCP"
# `micropod sandbox` drives Virtualization.framework in-process.
codesign --force --sign - --entitlements signing/micropod-cli.entitlements "$APP_BUNDLE/Contents/MacOS/micropod-cli"
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/MicropodMCP"
echo "==> CLI + MCP server bundled (micropod-cli, MicropodMCP)"

# The in-VM helper for sandbox file operations, watches and idle sandboxes
# (a static linux/arm64 ELF — sealed as a resource, not signed as code).
# The API finds it at ../Resources relative to its executable.
if command -v go >/dev/null 2>&1; then
    bash scripts/build_guest.sh "$APP_BUNDLE/Contents/Resources/micropod-guest" >/dev/null
    echo "==> Sandbox guest helper bundled (micropod-guest)"
else
    echo "!! go not found — micropod-guest not bundled; sandbox file operations fall back to the image's shell"
fi

# Bundle the synchronized file-shares daemon — the shim auto-discovers it
# at ~/micropod/share-cache/socket and rewrites directory binds through it.
if [ -f ".build/release/micropod-sharedfs" ]; then
    cp .build/release/micropod-sharedfs "$APP_BUNDLE/Contents/MacOS/micropod-sharedfs"
    chmod +x "$APP_BUNDLE/Contents/MacOS/micropod-sharedfs"
    cp .build/release/micropod-sharedfs "$DIST/micropod-sharedfs-bin"
    chmod +x "$DIST/micropod-sharedfs-bin"
    echo "==> Shared-fs daemon bundled (micropod-sharedfs)"
else
    echo "!! micropod-sharedfs not found in .build/release — shared mounts will fall back to plain virtiofs"
fi

# Re-seal: the helpers above were copied into Contents/MacOS after the
# first bundle signature, which left it invalid ("a sealed resource is
# missing or invalid") for unsigned/local installs. No --deep, so the
# helpers keep their own signatures (MicropodAPI's virtualization
# entitlement). make_dmg.sh re-signs everything for Developer ID builds.
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "==> Staging micropod CLI"
cp .build/release/micropod "$DIST/micropod"
chmod +x "$DIST/micropod"
# `micropod sandbox` drives Virtualization.framework in-process.
codesign --force --sign - --entitlements signing/micropod-cli.entitlements "$DIST/micropod"

echo "==> Staging tarball"
tar -czf "$DIST/Micropod.$VERSION.tgz" -C "$DIST" "$APP_NAME.app" micropod-mcp micropod-mcp-bin micropod
ls -lh "$DIST"
echo "Done. Install: cp -R $APP_BUNDLE /Applications/"
