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

# Docker Engine API shim: the app owns it as a supervised agent (spawned
# from the bundle, health-probed, restarted on death, killed on quit). A
# stable copy in ~/.local/bin is kept only for manual/debug launches —
# nothing auto-starts it outside the app anymore.
if [ -f "$ROOT/dist/micropod-docker-shim-bin" ]; then
    cp "$ROOT/dist/micropod-docker-shim-bin" "$MCP_DIR/micropod-docker-shim"
    chmod +x "$MCP_DIR/micropod-docker-shim"
    echo "==> Installed Docker API shim to $MCP_DIR/micropod-docker-shim"
fi

# Synchronized file-shares daemon: same ownership model — the app supervises
# it (socket ~/micropod/share-cache/socket). Remove the legacy LaunchAgent
# so launchd no longer fights the app's supervisor for the endpoint.
if [ -f "$ROOT/dist/micropod-sharedfs-bin" ]; then
    cp "$ROOT/dist/micropod-sharedfs-bin" "$SHAREDFS_BIN"
    chmod +x "$SHAREDFS_BIN"
    echo "==> Installed shared-fs daemon to $SHAREDFS_BIN"
fi
if [ -f "$HOME/Library/LaunchAgents/com.skunkworq.micropod-sharedfs.plist" ]; then
    launchctl bootout "gui/$(id -u)/com.skunkworq.micropod-sharedfs" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.skunkworq.micropod-sharedfs.plist"
    echo "==> Retired legacy shared-fs LaunchAgent (app now supervises it)"
fi

if [ -f "$ROOT/dist/micropod" ]; then
    echo "==> Installing CLI to $CLI_BIN"
    cp "$ROOT/dist/micropod" "$CLI_BIN"
    chmod +x "$CLI_BIN"
fi

# Agent skill: canonical copy lives at plugins/micropod/skills/micropod/
# (also shipped via the Claude Code plugin marketplace). Install it where
# Claude Code auto-discovers personal skills.
if [ -f "$ROOT/plugins/micropod/skills/micropod/SKILL.md" ]; then
    mkdir -p "$HOME/.claude/skills"
    rm -rf "$HOME/.claude/skills/micropod"
    cp -R "$ROOT/plugins/micropod/skills/micropod" "$HOME/.claude/skills/micropod"
    echo "==> Installed agent skill to ~/.claude/skills/micropod"
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
