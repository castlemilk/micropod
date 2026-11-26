#!/bin/bash
# Fail a release whose HVF runtime is absent, incomplete or unsigned.
#
#   scripts/verify_release_payload.sh [--developer-id] [--source SHA] [--summary FILE] TARGET...
#
# A TARGET is a Micropod.app bundle, a Micropod.dmg (attached read-only) or
# the standalone Micropod.<version>.tgz (extracted to a scratch directory:
# its flat HVF payload and the Micropod.app inside it are both checked, and
# must be byte-identical).
#
# Every target must carry the whole HVF runtime that the app and the
# standalone CLI boot from without a further download:
#   micropod-vmm         arm64 Mach-O, validly signed, with
#                        com.apple.security.hypervisor
#   vmlinux-hvf          ARM64 Linux Image ("ARMd" magic at offset 56)
#   mp-hvf-init.cpio     the guest init initramfs (cpio or compressed)
#   micropod-oci-tools/  the guest tool bundle: crun, containerd and its shim,
#                        runner/bin/job, runner/bin/buildkitd (Linux arm64),
#                        runner/start.sh, both configs and runner/manifest.json
#
# --developer-id  also require the VMM's signature to be a Developer ID one
#                 with the hardened runtime, from the app's own team, and the
#                 app's seal (which covers the kernel, initrd and tools) to
#                 verify.
# --source SHA    require the tool bundle's engine to be built from SHA in a
#                 clean tree (runner/manifest.json).
# --summary FILE  append a Markdown table of the assets and their sizes (for
#                 $GITHUB_STEP_SUMMARY).
#
# Every problem is reported; the exit status is 0 only when all targets pass.
set -euo pipefail

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p;}' "$0"; }

developer_id=false
source_revision=""
summary=""
targets=()
while [ $# -gt 0 ]; do
    case "$1" in
        --developer-id) developer_id=true; shift ;;
        --source) source_revision="${2:-}"; shift 2 || { echo "--source needs a commit" >&2; exit 2; } ;;
        --summary) summary="${2:-}"; shift 2 || { echo "--summary needs a file" >&2; exit 2; } ;;
        -h | --help) usage; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) targets+=("$1"); shift ;;
    esac
done
if [ ${#targets[@]} -eq 0 ]; then usage >&2; exit 2; fi
if [ -n "$source_revision" ] && ! [[ "$source_revision" =~ ^[0-9a-f]{40}$ ]]; then
    echo "--source must be a 40-character lowercase commit" >&2
    exit 2
fi
if [ -n "$summary" ] && ! : >>"$summary"; then
    echo "cannot append to the summary $summary" >&2
    exit 2
fi

failures=0
fail() {
    failures=$((failures + 1))
    if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "::error::$*" >&2; else echo "!! $*" >&2; fi
}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/verify-release-payload.XXXXXX")
mounted=()
cleanup() {
    for point in ${mounted[@]+"${mounted[@]}"}; do
        hdiutil detach -quiet "$point" >/dev/null 2>&1 || hdiutil detach -force -quiet "$point" >/dev/null 2>&1 || true
    done
    rm -rf "$scratch"
}
trap cleanup EXIT

# Hex of COUNT bytes at OFFSET.
bytes_at() { od -An -tx1 -j "$1" -N "$2" "$3" 2>/dev/null | tr -d ' \n'; }
size_of() { stat -f %z "$1"; }
sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# asset TARGET NAME PATH [exec]: a non-empty regular file inside the payload
# (a symlink could point anywhere at install time).
asset() {
    local target=$1 name=$2 path=$3 mode=${4:-}
    if [ -L "$path" ]; then
        fail "$target: HVF asset $name is a symlink, not a bundled file ($path)"
    elif [ ! -e "$path" ]; then
        fail "$target: HVF asset $name is missing ($path)"
    elif [ ! -f "$path" ]; then
        fail "$target: HVF asset $name is not a regular file ($path)"
    elif [ ! -s "$path" ]; then
        fail "$target: HVF asset $name is empty ($path)"
    elif [ "$mode" = exec ] && [ ! -x "$path" ]; then
        fail "$target: HVF asset $name is not executable ($path)"
    else
        return 0
    fi
    return 1
}

linux_arm64_elf() {
    [ "$(bytes_at 0 6 "$1")" = 7f454c460201 ] && [ "$(bytes_at 18 2 "$1")" = b700 ]
}

# The VMM may only reach Hypervisor.framework through its signed entitlement.
hypervisor_entitled() {
    codesign --display --entitlements - --xml "$1" 2>/dev/null | /usr/bin/python3 -c '
import plistlib, sys
data = sys.stdin.buffer.read()
try:
    entitled = bool(data) and plistlib.loads(data).get("com.apple.security.hypervisor") is True
except Exception:
    entitled = False
sys.exit(0 if entitled else 1)
'
}

check_vmm() {
    local target=$1 vmm=$2 app=$3 info team app_team
    asset "$target" micropod-vmm "$vmm" exec || return 0
    if ! lipo -archs "$vmm" 2>/dev/null | tr ' ' '\n' | grep -qx arm64; then
        fail "$target: HVF asset micropod-vmm is not an arm64 Mach-O executable ($vmm)"
        return 0
    fi
    if ! codesign --verify --strict "$vmm" 2>/dev/null; then
        fail "$target: HVF asset micropod-vmm is unsigned or its signature is invalid ($vmm)"
        return 0
    fi
    if ! hypervisor_entitled "$vmm"; then
        fail "$target: HVF asset micropod-vmm is not signed with com.apple.security.hypervisor ($vmm)"
    fi
    "$developer_id" || return 0
    info=$(codesign -dvv "$vmm" 2>&1 || true)
    team=$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p')
    app_team=$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)
    if ! printf '%s\n' "$info" | grep -q '^Authority=Developer ID Application: '; then
        fail "$target: HVF asset micropod-vmm is not signed with a Developer ID Application identity ($vmm)"
    elif [ -z "$team" ] || [ "$team" = "not set" ] || [ "$team" != "$app_team" ]; then
        fail "$target: HVF asset micropod-vmm is signed by team '${team:-none}', not the app's '${app_team:-none}' ($vmm)"
    fi
    if ! printf '%s\n' "$info" | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime'; then
        fail "$target: HVF asset micropod-vmm is not signed with the hardened runtime ($vmm)"
    fi
}

check_kernel() {
    local target=$1 kernel=$2
    asset "$target" vmlinux-hvf "$kernel" || return 0
    if [ "$(bytes_at 56 4 "$kernel")" != 41524d64 ]; then
        fail "$target: HVF asset vmlinux-hvf is not an ARM64 Linux Image ($kernel)"
    fi
}

check_initrd() {
    local target=$1 initrd=$2
    asset "$target" mp-hvf-init.cpio "$initrd" || return 0
    case "$(bytes_at 0 6 "$initrd")" in
        303730373031 | 303730373032 | 1f8b* | 28b52ffd* | fd377a585a00) ;;
        *) fail "$target: HVF asset mp-hvf-init.cpio is not a cpio initramfs ($initrd)" ;;
    esac
}

tool_executables="crun-1.31-arm64 runner/bin/containerd runner/bin/containerd-shim-runc-v2 runner/bin/job runner/bin/buildkitd"
tool_files="runner/buildkitd.toml runner/containerd.toml runner/manifest.json"

check_tools() {
    local target=$1 tools=$2 name problem
    if [ -L "$tools" ] || [ ! -d "$tools" ]; then
        fail "$target: HVF asset micropod-oci-tools/ (guest tool bundle) is missing ($tools)"
        return 0
    fi
    for name in $tool_executables; do
        if asset "$target" "micropod-oci-tools/$name" "$tools/$name" exec && ! linux_arm64_elf "$tools/$name"; then
            fail "$target: HVF asset micropod-oci-tools/$name is not a Linux arm64 executable ($tools/$name)"
        fi
    done
    asset "$target" micropod-oci-tools/runner/start.sh "$tools/runner/start.sh" exec || true
    for name in $tool_files; do asset "$target" "micropod-oci-tools/$name" "$tools/$name" || true; done
    [ -f "$tools/runner/manifest.json" ] && [ ! -L "$tools/runner/manifest.json" ] || return 0
    problem=$(/usr/bin/python3 - "$tools/runner/manifest.json" "$source_revision" <<'PY'
import json, sys
path, source = sys.argv[1:]
try:
    manifest = json.load(open(path))
except Exception as error:
    print(f"is not JSON ({error})")
    sys.exit()
commit = manifest.get("engineCommit") if isinstance(manifest, dict) else None
if not isinstance(commit, str) or not commit:
    print("names no engineCommit")
elif "buildkit" not in (manifest.get("capabilities") or []):
    print("does not declare the buildkit capability")
elif source and commit != source:
    print(f"was built from {commit}, not the release source {source}")
elif source and manifest.get("engineDirty") is not False:
    print("was built from a modified tree")
PY
    )
    if [ -n "$problem" ]; then
        fail "$target: HVF asset micropod-oci-tools/runner/manifest.json $problem"
    fi
}

summary_row() {
    local target=$1 name=$2 path=$3 bytes digest
    [ -n "$summary" ] || return 0
    if [ -L "$path" ] || [ ! -e "$path" ]; then
        printf '| %s | %s | missing | |\n' "$target" "$name" >>"$summary"
    elif [ -d "$path" ]; then
        bytes=$(find "$path" -type f -exec stat -f %z {} + | awk '{ total += $1 } END { print total + 0 }')
        printf '| %s | %s | %s | %s files |\n' "$target" "$name" "$bytes" "$(find "$path" -type f | wc -l | tr -d ' ')" \
            >>"$summary"
    else
        bytes=$(size_of "$path")
        digest=$(sha_of "$path")
        printf '| %s | %s | %s | `%s` |\n' "$target" "$name" "$bytes" "$digest" >>"$summary"
    fi
}

# check_payload TARGET BIN RESOURCES APP: the four HVF assets in one layout.
check_payload() {
    local target=$1 bin=$2 resources=$3 app=$4
    check_vmm "$target" "$bin/micropod-vmm" "$app"
    check_kernel "$target" "$resources/vmlinux-hvf"
    check_initrd "$target" "$resources/mp-hvf-init.cpio"
    check_tools "$target" "$resources/micropod-oci-tools"
    summary_row "$target" micropod-vmm "$bin/micropod-vmm"
    summary_row "$target" vmlinux-hvf "$resources/vmlinux-hvf"
    summary_row "$target" mp-hvf-init.cpio "$resources/mp-hvf-init.cpio"
    summary_row "$target" micropod-oci-tools/ "$resources/micropod-oci-tools"
    summary_row "$target" micropod-oci-tools/runner/bin/job "$resources/micropod-oci-tools/runner/bin/job"
    summary_row "$target" micropod-oci-tools/runner/bin/buildkitd "$resources/micropod-oci-tools/runner/bin/buildkitd"
}

check_app() {
    local target=$1 app=$2
    if [ ! -d "$app/Contents" ]; then
        fail "$target: no app bundle at $app"
        return 0
    fi
    check_payload "$target" "$app/Contents/MacOS" "$app/Contents/Resources" "$app"
    if "$developer_id" && ! codesign --verify --deep --strict "$app" 2>/dev/null; then
        fail "$target: the app's signature does not seal its contents ($app)"
    fi
}

# The standalone tarball repeats the app's runtime beside the CLI; the two
# copies must be the same bytes.
check_flat_matches_app() {
    local target=$1 root=$2 app=$3 name
    [ -d "$app/Contents" ] || return 0
    for name in micropod-vmm vmlinux-hvf mp-hvf-init.cpio; do
        local bundled="$app/Contents/Resources/$name"
        if [ "$name" = micropod-vmm ]; then bundled="$app/Contents/MacOS/$name"; fi
        if [ -f "$root/$name" ] && [ -f "$bundled" ] && ! cmp -s "$root/$name" "$bundled"; then
            fail "$target: the standalone $name differs from the app's copy"
        fi
    done
    if [ -d "$root/micropod-oci-tools" ] && [ -d "$app/Contents/Resources/micropod-oci-tools" ] &&
        ! diff -rq "$root/micropod-oci-tools" "$app/Contents/Resources/micropod-oci-tools" >/dev/null 2>&1; then
        fail "$target: the standalone micropod-oci-tools/ differs from the app's copy"
    fi
}

if [ -n "$summary" ]; then
    {
        echo
        echo "### HVF runtime payload"
        echo
        echo "| Target | Asset | Bytes | SHA-256 |"
        echo "|---|---|---:|---|"
    } >>"$summary"
fi

index=0
for target in "${targets[@]}"; do
    index=$((index + 1))
    label=$(basename "$target")
    case "$target" in
        *.app | *.app/)
            check_app "$label" "${target%/}"
            ;;
        *.dmg)
            if [ ! -f "$target" ]; then
                fail "$label: no disk image at $target"
                continue
            fi
            point="$scratch/volume-$index"
            mkdir -p "$point"
            if ! hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$point" "$target" >/dev/null; then
                fail "$label: could not attach $target"
                continue
            fi
            mounted+=("$point")
            check_app "$label" "$point/Micropod.app"
            ;;
        *.tgz | *.tar.gz)
            if [ ! -f "$target" ]; then
                fail "$label: no tarball at $target"
                continue
            fi
            root="$scratch/tarball-$index"
            mkdir -p "$root"
            if ! tar -xzf "$target" -C "$root"; then
                fail "$label: could not extract $target"
                continue
            fi
            check_payload "$label" "$root" "$root" "$root/Micropod.app"
            check_app "$label: Micropod.app" "$root/Micropod.app"
            check_flat_matches_app "$label" "$root" "$root/Micropod.app"
            ;;
        *)
            fail "$label: not an .app, .dmg or .tgz release target"
            ;;
    esac
done

if [ "$failures" -gt 0 ]; then
    echo "Release HVF payload verification failed with $failures problem(s)" >&2
    exit 1
fi
echo "Release HVF payload verified: ${targets[*]}"
