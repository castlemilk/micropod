#!/bin/bash
# Install Micropod: desktop app + MCP server + CLI conveniences.
# Usage: ./scripts/install.sh [--uninstall]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Micropod"
APP_BUNDLE="$ROOT/dist/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"
MCP_DIR="$HOME/.local/bin"
MCP_BIN="$MCP_DIR/micropod-mcp"
CLI_BIN="$MCP_DIR/micropod"
SHAREDFS_BIN="$MCP_DIR/micropod-sharedfs"
UNINSTALL=0
[[ "${1:-}" == "--uninstall" ]] && UNINSTALL=1

uninstall() {
    echo "==> Stopping $APP_NAME"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
    echo "==> Stopping shared-fs daemon"
    launchctl bootout "gui/$(id -u)/com.skunkworq.micropod-sharedfs" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.skunkworq.micropod-sharedfs.plist"
    pkill -x "micropod-sharedfs" 2>/dev/null || true
    echo "==> Removing $INSTALL_APP"
    rm -rf "$INSTALL_APP"
    echo "==> Removing $MCP_BIN"
    rm -f "$MCP_BIN" "${MCP_BIN}-bin" "$CLI_BIN" "$SHAREDFS_BIN"
    # Drop the Launch Services registration so the icon/name vanish cleanly.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$INSTALL_APP" 2>/dev/null || true
    echo "Uninstalled. (Micropod data in ~/Library/Application Support/Micropod and"
    echo "preferences com.skunkworq.micropod were left in place.)"
    exit 0
}

[[ $UNINSTALL -eq 1 ]] && uninstall

if [ ! -d "$APP_BUNDLE" ]; then
    echo "==> $APP_BUNDLE not found — building it first"
    (cd "$ROOT" && ./scripts/package_app.sh)
fi

echo "==> Stopping any running instance"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

echo "==> Installing $INSTALL_APP"
rm -rf "$INSTALL_APP"
/usr/bin/ditto "$APP_BUNDLE" "$INSTALL_APP"
touch "$INSTALL_APP"

echo "==> Installing MCP server to $MCP_BIN"
mkdir -p "$MCP_DIR"
cp "$ROOT/dist/micropod-mcp-bin" "${MCP_BIN}-bin"
cat > "$MCP_BIN" <<WRAP
#!/bin/bash
exec "$MCP_DIR/micropod-mcp-bin" "\$@"
WRAP
chmod +x "$MCP_BIN" "${MCP_BIN}-bin"

# Docker Engine API shim: the app auto-starts it from inside the bundle, but
# a stable copy in ~/.local/bin lets agents (cuttlefish runner, docker CLI
# with DOCKER_HOST) launch it manually too.
if [ -f "$ROOT/dist/micropod-docker-shim-bin" ]; then
    cp "$ROOT/dist/micropod-docker-shim-bin" "$MCP_DIR/micropod-docker-shim"
    chmod +x "$MCP_DIR/micropod-docker-shim"
    echo "==> Installed Docker API shim to $MCP_DIR/micropod-docker-shim"
fi

# Synchronized file-shares daemon: same pattern — app can auto-start it,
# and a LaunchAgent keeps it alive for shim bind rewriting.
if [ -f "$ROOT/dist/micropod-sharedfs-bin" ]; then
    cp "$ROOT/dist/micropod-sharedfs-bin" "$SHAREDFS_BIN"
    chmod +x "$SHAREDFS_BIN"
    echo "==> Installed shared-fs daemon to $SHAREDFS_BIN"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$HOME/Library/LaunchAgents/com.skunkworq.micropod-sharedfs.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.skunkworq.micropod-sharedfs</string>
    <key>ProgramArguments</key><array><string>$SHAREDFS_BIN</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/micropod-sharedfs.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/micropod-sharedfs.log</string>
</dict>
</plist>
PLIST
    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.skunkworq.micropod-sharedfs.plist" 2>/dev/null || \
        launchctl bootout "gui/$(id -u)/com.skunkworq.micropod-sharedfs" 2>/dev/null; launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.skunkworq.micropod-sharedfs.plist" 2>/dev/null || true
    echo "==> Shared-fs daemon LaunchAgent installed (socket ~/micropod/share-cache/socket)"
fi

if [ -f "$ROOT/dist/micropod" ]; then
    echo "==> Installing CLI to $CLI_BIN"
    cp "$ROOT/dist/micropod" "$CLI_BIN"
    chmod +x "$CLI_BIN"
fi

# Refresh Launch Services so the app appears (with its icon) in
# Launchpad/Finder immediately instead of on next login.
echo "==> Refreshing Launch Services registration"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALL_APP" 2>/dev/null || true

echo "==> Starting $APP_NAME"
open "$INSTALL_APP"

echo
echo "Installed:"
echo "  App      $INSTALL_APP (Dock app + menu-bar item)"
echo "  MCP      $MCP_BIN"
[ -f "$CLI_BIN" ] && { echo "  CLI      $CLI_BIN"; } || true
if [[ ":$PATH:" != *":$MCP_DIR:"* ]]; then
    echo "           (add $MCP_DIR to PATH to use micropod anywhere)"
fi
echo
echo "MCP registration (~/Library/Application Support/Claude/claude_desktop_config.json):"
echo '  "mcpServers": { "micropod": { "command": "'"$MCP_BIN"'" } }'
