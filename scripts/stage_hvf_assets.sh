#!/bin/bash
# Copy a built HVF runtime between the app and standalone distribution layouts.
set -euo pipefail

bin_source=${1:?source binary directory}
resources=${2:?source resources directory}
bin_dest=${3:?destination binary directory}
resource_dest=${4:?destination resources directory}
vmm="$bin_source/micropod-vmm"
tools="$resources/micropod-oci-tools"

[[ -x "$vmm" && -s "$resources/vmlinux-hvf" && -s "$resources/mp-hvf-init.cpio" &&
   -x "$tools/runner/start.sh" && -x "$tools/runner/bin/job" ]] || {
    echo "Incomplete HVF runtime in $bin_source and $resources" >&2
    exit 1
}
codesign --verify --strict "$vmm"
codesign --display --entitlements - --xml "$vmm" 2>/dev/null |
    /usr/bin/python3 -c '
import plistlib
import sys

data = sys.stdin.buffer.read()
if not data or plistlib.loads(data).get("com.apple.security.hypervisor") is not True:
    sys.exit("The distribution VMM requires com.apple.security.hypervisor")
'

mkdir -p "$bin_dest" "$resource_dest"
staged=$(mktemp -d "$resource_dest/.hvf-stage.XXXXXX")
trap 'rm -rf "$staged"' EXIT
ditto "$tools" "$staged/micropod-oci-tools"
install -m 644 "$resources/vmlinux-hvf" "$resources/mp-hvf-init.cpio" "$staged/"
install -m 755 "$vmm" "$staged/micropod-vmm"
mv -f "$staged/micropod-vmm" "$bin_dest/micropod-vmm"
mv -f "$staged/vmlinux-hvf" "$staged/mp-hvf-init.cpio" "$resource_dest/"
if [[ -e "$resource_dest/micropod-oci-tools" || -L "$resource_dest/micropod-oci-tools" ]]; then
    mv "$resource_dest/micropod-oci-tools" "$staged/previous-tools"
fi
if ! mv "$staged/micropod-oci-tools" "$resource_dest/micropod-oci-tools"; then
    if [[ -e "$staged/previous-tools" || -L "$staged/previous-tools" ]]; then
        mv "$staged/previous-tools" "$resource_dest/micropod-oci-tools"
    fi
    exit 1
fi
