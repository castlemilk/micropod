"""Bootstrap and verify the private 16 KiB file-fault-around experiment."""

import re
from pathlib import Path


SCHEMA = "micropod-file-fault-around-v1"
MARKER = "runner/file-fault-around.fixture"
MARKER_TEXT = b"micropod-file-fault-around-fixture-v1\n"
BOOT = "file-fault-around-boot.txt"
FINAL = "file-fault-around-final.txt"
ARG = "micropod.bench_file_fault_around"
DEFAULT_BYTES = 65536
WINDOWS = (DEFAULT_BYTES, 1048576)
PAGE_BYTES = 16384
BOOT_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
MMAP_SCHEMA = "micropod-file-fault-around-mmap-v1"
GO_PATH = "/usr/local/go/bin/go"
GO_SHA256 = "2c77b9243b17c9d5ecd5983acbdeaee36d470a9b62a2952f1279c319cc9b97fb"
SAMPLE_ORDERS = ("forward", "reverse", "reverse", "forward")

# Parent directory mode 0700 confines even the mounted debugfs root. Fail on
# teardown errors and leave no debugfs mount available to the workload.
_DEBUGFS = r'''
    isolated=$(mktemp -d)
    debug="$isolated/debug"
    mkdir "$debug"
    trap 'rmdir "$debug" "$isolated"' EXIT
    mount -t debugfs -o MOUNT_OPTIONS debugfs "$debug"
    trap 'status=$?; if ! umount "$debug" || ! rmdir "$debug" "$isolated"; then status=1; fi; exit "$status"' EXIT
    knob="$debug/fault_around_bytes"
    [ -r "$knob" ]
    page=$(awk '$1 == "KernelPageSize:" && $3 == "kB" { print $2*1024; exit }' /proc/self/smaps)
    [ "$page" = 16384 ] || { echo "File fault-around fixture requires 16 KiB pages" >&2; exit 1; }
    boot=$(cat /proc/sys/kernel/random/boot_id)
    [ -n "$boot" ]
'''

BOOTSTRAP = r'''# Trusted disposable fixture; ordinary workers never select this private key.
configure_file_fault_around() (
    selection=$(tr ' ' '\n' </proc/cmdline | sed -n '/^micropod\.bench_file_fault_around=/p')
    [ -n "$selection" ] || exit 0
    case "$selection" in
        micropod.bench_file_fault_around=65536) selected=65536 ;;
        micropod.bench_file_fault_around=1048576) selected=1048576 ;;
        *) echo "Unknown or repeated private file fault-around token" >&2; exit 1 ;;
    esac
    workspace=${MICROPOD_ENGINE_WORKSPACE:-}
    marker="$tools/runner/file-fault-around.fixture"
    if [ "$(id -u)" != 0 ] || [ "${MICROPOD_ENGINE_API:-}" != 1 ] ||
        [ "${MICROPOD_NATIVE_OCI:-}" != 1 ] || [ ! -d "$workspace" ] || [ -L "$workspace" ] ||
        ! printf '%s\n' "$workspace" | grep -Eq '^(/private)?/tmp/mp-t-[a-z0-9_]{8}/workspace$' ||
        [ ! -f "$marker" ] || [ -L "$marker" ] ||
        [ "$(cat "$marker")" != micropod-file-fault-around-fixture-v1 ]; then
        echo "File fault-around requires the trusted disposable native worker fixture" >&2
        exit 1
    fi
''' + _DEBUGFS.replace("MOUNT_OPTIONS", "nosuid,nodev,noexec") + r'''
    before=$(cat "$knob")
    [ "$before" = 65536 ] || { echo "Expected default file fault-around window, saw $before" >&2; exit 1; }
    # Send one numeric token to debugfs without a separate newline write.
    if ! printf '%s' "$selected" > "$knob"; then
        observed=$(cat "$knob" 2>&1) || observed="unreadable ($observed)"
        printf 'File fault-around write failed for %s bytes. Readback %s\n' "$selected" "$observed" >&2
        exit 1
    fi
    effective=$(cat "$knob")
    [ "$effective" = "$selected" ] || { echo "File fault-around readback mismatch: $effective" >&2; exit 1; }
    target="$workspace/file-fault-around-boot.txt"
    [ ! -e "$target" ] && [ ! -L "$target" ] || { echo "Stale file fault-around boot receipt" >&2; exit 1; }
    printf 'schema=micropod-file-fault-around-v1\nboot_id=%s\npage_size_bytes=%s\nbefore_bytes=%s\neffective_bytes=%s\n' \
        "$boot" "$page" "$before" "$effective" > "$target"
    echo "CI fixture file fault-around window: $before -> $effective bytes (boot $boot)" >&2
)
configure_file_fault_around
'''

FINAL_OBSERVER = r'''
(
    set -eu
    [ "$(id -u)" = 0 ]
''' + _DEBUGFS.replace("MOUNT_OPTIONS", "ro,nosuid,nodev,noexec") + r'''
    effective=$(cat "$knob")
    printf 'schema=micropod-file-fault-around-v1\nboot_id=%s\npage_size_bytes=%s\neffective_bytes=%s\n' \
        "$boot" "$page" "$effective"
)
'''


def kernel_arg(window_bytes):
    if type(window_bytes) is not int or window_bytes not in WINDOWS:
        raise ValueError("the file fault-around trial permits only 65536 or 1048576 bytes")
    return f"{ARG}={window_bytes}"


def stage_marker(oci):
    path = Path(oci) / MARKER
    with path.open("xb") as f:
        f.write(MARKER_TEXT)
    path.chmod(0o600)
    return path


def patch_start(source):
    anchor = b"configure_scheduler\n# Each containerd shim"
    hook = b"(umask 022; exec containerd "
    if source.count(anchor) != 1 or source.count(hook) != 1 or source.index(anchor) > source.index(hook):
        raise ValueError("unknown sealed worker bootstrap")
    return source.replace(anchor, b"configure_scheduler\n" + BOOTSTRAP.encode() + b"# Each containerd shim", 1)


def parse_readback(raw, window_bytes, boot_id, *, before_work):
    kernel_arg(window_bytes)
    if BOOT_ID.fullmatch(boot_id) is None:
        raise ValueError("invalid measured boot ID")
    expected = {"schema": SCHEMA, "boot_id": boot_id, "page_size_bytes": str(PAGE_BYTES),
                "effective_bytes": str(window_bytes)}
    if before_work:
        expected["before_bytes"] = str(DEFAULT_BYTES)
    lines = [line.split("=", 1) for line in raw.splitlines()]
    if (len(lines) != len(expected) or any(len(row) != 2 for row in lines)
            or dict(lines) != expected):
        raise ValueError("fault-around receipt differs from the pinned kernel or measured boot/window")
    return {key: int(value) if key.endswith("_bytes") else value for key, value in expected.items()}


def read(folder, window_bytes, boot_id):
    folder = Path(folder)
    return {
        "boot": parse_readback((folder / BOOT).read_text(), window_bytes, boot_id, before_work=True),
        "final": parse_readback((folder / FINAL).read_text(), window_bytes, boot_id, before_work=False),
    }


def check_mmap(receipt, boot_id, go_inode, selected_window_bytes):
    """Verify the off-timing witness against independent job and boot identity."""
    kernel_arg(selected_window_bytes)
    window = WINDOWS[-1]
    total_pages = window // PAGE_BYTES
    around_pages = selected_window_bytes // PAGE_BYTES
    if (BOOT_ID.fullmatch(boot_id) is None or receipt["schema"] != MMAP_SCHEMA or
            receipt["boot_id"] != boot_id or receipt["page_bytes"] != PAGE_BYTES or receipt["window_bytes"] != window):
        raise ValueError("mapped Go proof has the wrong guest, granule or window")
    tool = receipt["tool"]
    numeric = ("inode", "device", "device_major", "device_minor", "size_bytes", "segment_offset",
               "segment_size_bytes", "window_offset")
    if (tool["path"] != GO_PATH or tool["sha256"] != GO_SHA256 or tool["inode"] != go_inode
            or any(type(tool[k]) is not int or tool[k] < 0 for k in numeric) or tool["inode"] == 0):
        raise ValueError("mapped Go proof does not match the pinned installed tool")
    dev = tool["device"]
    major, minor = (dev >> 8 & 0xfff) | (dev >> 32 & 0xfffff000), (dev & 0xff) | (dev >> 12 & 0xffffff00)
    begin, end = tool["segment_offset"], tool["segment_offset"] + tool["segment_size_bytes"]
    offset = tool["window_offset"]
    if (major, minor) != (tool["device_major"], tool["device_minor"]) or not (
            offset == (begin + window - 1) // window * window and offset + window <= end <= tool["size_bytes"]):
        raise ValueError("mapped Go proof has the wrong executable window/device geometry")
    rows = receipt["samples"]
    if [row["order"] for row in rows] != list(SAMPLE_ORDERS):
        raise ValueError("mapped Go proof lacks balanced sequential samples")
    checksums = {}
    for row in rows:
        fields = row["maps_line"].split()
        if len(fields) != 6:
            raise ValueError("invalid maps evidence for the Go window")
        left, right = (int(v, 16) for v in fields[0].split("-"))
        device = tuple(int(v, 16) for v in fields[3].split(":"))
        if (left % window or right - left != window or fields[1] != "r--p" or int(fields[2], 16) != offset or
                device != (major, minor) or int(fields[4]) != go_inode or fields[5] != GO_PATH):
            raise ValueError("aligned read-only mapping differs from the installed executable identity")
        start = 0 if row["order"] == "forward" else total_pages - around_pages
        expected = list(range(start, start + around_pages))
        checksum = row["checksum"]
        if (row["present_before_pages"] != 0 or row["resident_before_pages"] != total_pages or
                row["present_after_first_indices"] != expected or type(row["minor_faults"]) is not int or
                row["minor_faults"] < 1 or row["major_faults"] != 0 or
                re.fullmatch(r"[0-9a-f]{16}", checksum) is None or row["expected_checksum"] != checksum or
                checksums.setdefault(row["order"], checksum) != checksum):
            raise ValueError("warm executable mapping disagrees with page footprint, fault counts, or byte digest")
    return rows
