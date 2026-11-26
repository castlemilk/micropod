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

# A release carries the whole HVF runtime: the entitled micropod-vmm,
# vmlinux-hvf, mp-hvf-init.cpio and the micropod-oci-tools guest bundle.
# scripts/verify_release_payload.sh checks the app and the tarball at the end.
# CI builds none of them, so it must be handed the qualified distribution (or
# an explicit VMM tree); say so before the long release build.
if [[ "${GITHUB_ACTIONS:-false}" == true ]]; then
    if [[ "${MICROPOD_PACKAGE_WITHOUT_HVF:-0}" == 1 ]]; then
        echo "!! MICROPOD_PACKAGE_WITHOUT_HVF is for local development packages; CI packages a release" >&2
        exit 1
    fi
    if [[ -z "${MICROPOD_HVF_DISTRIBUTION:-}" && -z "${MICROPOD_VMM_DIR:-}" ]]; then
        echo "!! CI packaging needs MICROPOD_HVF_DISTRIBUTION (the qualified HVF runtime): a release without micropod-vmm, vmlinux-hvf, mp-hvf-init.cpio and micropod-oci-tools is refused" >&2
        exit 1
    fi
fi

# Stamp the version and source revision into the CLI, MCP and API binaries
# for this build only.
# (The backup lives outside the target: SwiftPM warns about stray files.)
BUILD_INFO="Sources/MicropodBuildInfo/BuildInfo.swift"
BUILD_INFO_ORIG="$(mktemp)"
cp "$BUILD_INFO" "$BUILD_INFO_ORIG"
trap 'cp "$BUILD_INFO_ORIG" "$BUILD_INFO" && rm -f "$BUILD_INFO_ORIG"' EXIT
SOURCE_REVISION="$(git rev-parse HEAD)"
sed -i '' "s/static let version = \"dev\"/static let version = \"$VERSION\"/" "$BUILD_INFO"
sed -i '' "s/static let sourceRevision = \"unknown\"/static let sourceRevision = \"$SOURCE_REVISION\"/" "$BUILD_INFO"
grep -q "\"$VERSION\"" "$BUILD_INFO" || { echo "!! failed to stamp $BUILD_INFO"; exit 1; }
grep -q "\"$SOURCE_REVISION\"" "$BUILD_INFO" || { echo "!! failed to stamp the revision into $BUILD_INFO"; exit 1; }

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
# The updater floor and workload protocol come from the one release policy
# that the feed scripts also stamp into every workload item.
python3 -c '
import json, pathlib, plistlib, re, sys
path, name, version, identifier, source, policy_path = sys.argv[1:]
policy = json.loads(pathlib.Path(policy_path).read_text())
if policy.get("schema") != 1 or not re.fullmatch(r"(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)", str(policy.get("minimumUpdateVersion"))) \
        or type(policy.get("workloadProtocol")) is not int or policy["workloadProtocol"] < 1:
    sys.exit("invalid updater policy: " + policy_path)
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
    "SUAllowsAutomaticUpdates": True,
    "MicropodWorkloadProtocol": policy["workloadProtocol"],
    "MicropodMinimumUpdateVersion": policy["minimumUpdateVersion"],
    "MicropodSourceRevision": source,
    "SUScheduledCheckInterval": "3600",
    "NSHumanReadableCopyright": "© 2026 skunkworq",
}
pathlib.Path(path).write_bytes(plistlib.dumps(metadata, sort_keys=False))
' "$APP_BUNDLE/Contents/Info.plist" "$APP_NAME" "$VERSION" "$BUNDLE_ID" "$SOURCE_REVISION" \
    "$ROOT/release/updater-policy.json"

mkdir -p "$APP_BUNDLE/Contents/Library/LaunchDaemons"
cp .build/release/MicropodRuntimeHost "$APP_BUNDLE/Contents/MacOS/MicropodRuntimeHost"
python3 - "$APP_BUNDLE/Contents/Library/LaunchDaemons/com.skunkworq.micropod.runtime.host.plist" <<'PYPLIST'
import pathlib,plistlib,sys
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'Label':'com.skunkworq.micropod.runtime.host',
    'BundleProgram':'Contents/MacOS/MicropodRuntimeHost',
    'MachServices':{'com.skunkworq.micropod.runtime.host':True},
    'RunAtLoad':True,'ProcessType':'Background','ThrottleInterval':10,
    'KeepAlive':{'SuccessfulExit':False},'Umask':0o077,
}))
PYPLIST
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

# The ARM Linux executables are read-only VM resources. The Mac client stays beside the CLI.
oci_tools="$ROOT/.build/oci-tools"
oci_archive=()
if command -v rustup >/dev/null && command -v go >/dev/null && rustup target list --installed | grep -qx aarch64-unknown-linux-musl; then
    bash ci/build-runner-tools.sh "$oci_tools"
fi
if [[ -x "$oci_tools/client" && -x "$oci_tools/guest/service" && -x "$oci_tools/guest/runner/bin/job" ]]; then
    for dir in "$APP_BUNDLE/Contents/Resources/micropod-oci-tools" "$DIST/micropod-oci-tools"; do
        mkdir -p "$dir"
        install -m 755 "$oci_tools/guest/service" "$oci_tools/guest/executor" "$oci_tools/guest/crun-1.31-arm64" "$dir/"
        rm -rf "$dir/runner"
        mkdir -p "$dir/runner"
        cp -R "$oci_tools/guest/runner/." "$dir/runner/"
    done
    for client in "$APP_BUNDLE/Contents/MacOS/micropod-oci" "$DIST/micropod-oci"; do
        install -m 755 "$oci_tools/client" "$client"
        codesign --force --sign - "$client"
    done
    oci_archive=(micropod-oci micropod-oci-tools)
    echo "==> Native CI guest service and client bundled"
fi

# Bundle the signed Rust Hypervisor.framework VMM and matching Linux initrd so
# MICROPOD_CI_VMM=hvf works out of the box from both Micropod.app and dist/micropod.
hvf_archive=()
if [[ -n "${MICROPOD_HVF_DISTRIBUTION:-}" ]]; then
    bash scripts/stage_hvf_assets.sh "$MICROPOD_HVF_DISTRIBUTION" "$MICROPOD_HVF_DISTRIBUTION" \
        "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
    bash scripts/stage_hvf_assets.sh "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$DIST" "$DIST"
    # The qualified tools replace the locally built copy. Archive the Mac OCI client once.
    if (( ${#oci_archive[@]} )); then oci_archive=(micropod-oci); fi
    hvf_archive=(micropod-vmm mp-hvf-init.cpio vmlinux-hvf micropod-oci-tools)
elif [[ "${GITHUB_ACTIONS:-false}" != true || -n "${MICROPOD_VMM_DIR:-}" ]]; then
    VMM_DIR="${MICROPOD_VMM_DIR:-$ROOT/vmm}"
    if [[ -z "${MICROPOD_VMM_DIR:-}" && ! -d "$VMM_DIR" ]]; then
        for sibling in "$ROOT/../../vmm" "$ROOT/../vmm"; do
            if [[ -d "$sibling" ]]; then VMM_DIR="$sibling"; break; fi
        done
    fi
    if [ -d "$VMM_DIR" ] && [ "${MICROPOD_SKIP_VMM_BUILD:-0}" != "1" ] && command -v cargo >/dev/null && command -v go >/dev/null; then
        echo "==> Building HVF VMM (micropod-vmm + mp-hvf-init.cpio)"
        bash "$VMM_DIR/build.sh"
    fi
    if [ -x "$VMM_DIR/target/release/micropod-vmm" ] && [ -f "$VMM_DIR/target/mp-hvf-init.cpio" ]; then
        for vmm_dst in "$APP_BUNDLE/Contents/MacOS/micropod-vmm" "$DIST/micropod-vmm"; do
            install -m 755 "$VMM_DIR/target/release/micropod-vmm" "$vmm_dst"
            codesign --force --sign - --entitlements "$ROOT/signing/micropod-vmm.entitlements" "$vmm_dst"
            codesign --verify --strict "$vmm_dst"
        done
        install -m 644 "$VMM_DIR/target/mp-hvf-init.cpio" "$APP_BUNDLE/Contents/Resources/mp-hvf-init.cpio"
        install -m 644 "$VMM_DIR/target/mp-hvf-init.cpio" "$DIST/mp-hvf-init.cpio"
        hvf_archive=(micropod-vmm mp-hvf-init.cpio)
        if [ -n "${MICROPOD_HVF_KERNEL:-}" ]; then
            HVF_KERNEL="$MICROPOD_HVF_KERNEL"
        elif [ -f "$ROOT/.build/b8-kernel-out/Image" ]; then
            HVF_KERNEL="$ROOT/.build/b8-kernel-out/Image"
        else
            HVF_KERNEL="$ROOT/.build/local-kernel-pages/20261125-b5-16k/full-16k/Image"
        fi
        if [ -f "$HVF_KERNEL" ]; then
            install -m 644 "$HVF_KERNEL" "$APP_BUNDLE/Contents/Resources/vmlinux-hvf"
            install -m 644 "$HVF_KERNEL" "$DIST/vmlinux-hvf"
            hvf_archive+=(vmlinux-hvf)
            echo "==> HVF kernel bundled (vmlinux-hvf)"
        fi
        echo "==> HVF VMM bundled and signed (micropod-vmm + mp-hvf-init.cpio)"
    fi
fi

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

# Setup is copied outside this app before approval, so desktop replacement
# cannot replace the approved daemon or its future maintenance workers.
MICROPOD_RUNTIME_CONFIGURATION=release MICROPOD_RUNTIME_SIGN_IDENTITY=- \
    MICROPOD_RUNTIME_SKIP_BUILD=1 \
    MICROPOD_RUNTIME_VERSION="$VERSION" MICROPOD_RUNTIME_SOURCE_REVISION="$SOURCE_REVISION" \
    MICROPOD_RUNTIME_OUTPUT="$ROOT/$APP_BUNDLE/Contents/Helpers/Micropod Runtime Setup.app" \
    MICROPOD_RUNTIME_GUEST_TOOL="$ROOT/$APP_BUNDLE/Contents/Resources/micropod-guest" \
    bash scripts/package_runtime_setup.sh

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
tar -czf "$DIST/Micropod.$VERSION.tgz" -C "$DIST" "$APP_NAME.app" micropod-mcp micropod-mcp-bin micropod ${oci_archive[@]+"${oci_archive[@]}"} ${hvf_archive[@]+"${hvf_archive[@]}"}

# Nothing above fails when a piece of the HVF runtime could not be built or
# found: this does, naming each one. MICROPOD_PACKAGE_WITHOUT_HVF=1 makes a
# local development package without it, which make_dmg.sh then refuses.
if [[ "${MICROPOD_PACKAGE_WITHOUT_HVF:-0}" == 1 ]]; then
    echo "!! MICROPOD_PACKAGE_WITHOUT_HVF=1: $APP_BUNDLE is a development package, not a release (no HVF runtime check)"
elif ! bash scripts/verify_release_payload.sh "$APP_BUNDLE" "$DIST/Micropod.$VERSION.tgz"; then
    echo "!! The package lacks the HVF runtime. Point MICROPOD_HVF_DISTRIBUTION at a qualified payload (README), or build vmm/ with cargo, go, the aarch64-unknown-linux-musl target and MICROPOD_HVF_KERNEL. MICROPOD_PACKAGE_WITHOUT_HVF=1 packages a local development build without it." >&2
    exit 1
fi
ls -lh "$DIST"
echo "Done. Install: cp -R $APP_BUNDLE /Applications/"
