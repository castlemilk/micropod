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

echo "==> Building release (swift build -c release)"
swift build -c release

echo "==> Assembling $APP_NAME.app"
APP_BUNDLE="$DIST/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

# App icon: prefer the BrandBrain-generated brand mark (assets/logo/Micropod.icns);
# fall back to the programmatic SF-Symbol icon if it is not checked in.
if [ -f "$ROOT/assets/logo/Micropod.icns" ]; then
    cp "$ROOT/assets/logo/Micropod.icns" "$APP_BUNDLE/Contents/Resources/Micropod.icns"
    echo "==> Icon: BrandBrain brand mark (assets/logo/Micropod.icns)"
else
    ICON_ICNS="$(swift scripts/make_icon.swift "$DIST/icon-build" | tail -1)"
    cp "$ICON_ICNS" "$APP_BUNDLE/Contents/Resources/Micropod.icns"
    echo "==> Icon: fallback programmatic icon"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleAllowMixedLocalizations</key><true/>
    <key>CFBundleIconFile</key><string>Micropod</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><false/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>© 2026 skunkworq</string>
</dict>
</plist>
PLIST

cp .build/release/MicropodApp "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# SwiftPM resource bundle (icons, brandbrain assets, Localizable.xcstrings):
# Bundle.module looks for it at Bundle.main.bundleURL/<name>.bundle, which for a
# packaged .app resolves to the app bundle root.
if [ -d ".build/release/Micropod_MicropodApp.bundle" ]; then
    cp -R ".build/release/Micropod_MicropodApp.bundle" "$APP_BUNDLE/Micropod_MicropodApp.bundle"
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

echo "==> Staging micropod CLI"
cp .build/release/micropod "$DIST/micropod"
chmod +x "$DIST/micropod"

echo "==> Staging tarball"
tar -czf "$DIST/Micropod.$VERSION.tgz" -C "$DIST" "$APP_NAME.app" micropod-mcp micropod-mcp-bin micropod
ls -lh "$DIST"
echo "Done. Install: cp -R $APP_BUNDLE /Applications/"
