#!/usr/bin/env python3
"""Own a disposable APFS sparseimage for a benchmark worker on macOS.

Keep the receipt for verify() and detach(). Both resolve the actual disk image
attachment before trusting mount-path observations. FSEvents evidence covers the
on-disk per-volume journal, including a read-only remount when retiring the drive.
Spotlight evidence is the scoped mdutil status.
"""

import argparse
import json
import os
import plistlib
import re
import stat
import subprocess
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path


HDI = "/usr/bin/hdiutil"
DISKUTIL = "/usr/sbin/diskutil"
MDUTIL = "/usr/bin/mdutil"
SCHEMA = "micropod-worker-apfs-v1"
DISABLED = {"Indexing disabled.", "Indexing and searching disabled."}


def _now():
    return datetime.now(timezone.utc).isoformat()


def _command(*argv):
    proc = subprocess.run(argv, capture_output=True, timeout=30, check=False,
                          env={**os.environ, "LC_ALL": "C"})
    return {
        "argv": list(argv), "returncode": proc.returncode, "observed_at": _now(),
        "stdout": proc.stdout.decode(errors="replace"),
        "stderr": proc.stderr.decode(errors="replace"),
    }


def _checked(*argv):
    result = _command(*argv)
    if result["returncode"]:
        raise RuntimeError(f"{argv[0]} {argv[1]} failed: {result['stderr'].strip()}")
    return result


def _plist(*argv):
    return plistlib.loads(_checked(*argv)["stdout"].encode())


def _identity(st):
    return {"dev": st.st_dev, "ino": st.st_ino}


def _owned_paths(image, mount):
    image, mount = Path(image), Path(mount)
    image = image.parent.resolve(strict=True) / image.name
    mount = mount.parent.resolve(strict=True) / mount.name
    parent = image.parent.stat()
    if (image.parent != mount.parent or image.suffix != ".sparseimage" or
            mount == image.parent or parent.st_uid != os.getuid() or parent.st_mode & 0o022):
        raise ValueError("the sparseimage and existing empty mount directory must share an owned fixture directory")
    return image, mount


def _image_identity(image):
    st = Path(image).lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_nlink != 1:
        raise RuntimeError(f"invalid owned sparseimage file {image}")
    return _identity(st)


def _active(image):
    rows = [row for row in _plist(HDI, "info", "-plist")["images"]
            if row.get("image-path") and os.path.realpath(row["image-path"]) == image]
    if len(rows) > 1:
        raise RuntimeError(f"multiple attachments for {image}")
    return rows[0]["system-entities"] if rows else []


def _uuid(value):
    return str(uuid.UUID(value)).upper()


def _device(value):
    if not re.fullmatch(r"(?:/dev/)?disk[0-9]+(?:s[0-9]+)*", value or ""):
        raise RuntimeError(f"unexpected disk device {value!r}")
    return value if value.startswith("/dev/") else f"/dev/{value}"


def _unmounted(record):
    mount = Path(record["mount"])
    st = mount.lstat()
    if (not stat.S_ISDIR(st.st_mode) or _identity(st) != record["mountpoint_identity"] or
            mount.is_mount() or any(mount.iterdir())):
        raise RuntimeError(f"original empty mount directory was not restored: {mount}")


def _validate_image(record):
    image, mount = _owned_paths(record["image"], record["mount"])
    if (record.get("schema") != SCHEMA or str(image) != record["image"] or
            str(mount) != record["mount"]):
        raise RuntimeError("unexpected APFS receipt paths or schema")
    if _image_identity(image) != {key: record["image_identity"][key] for key in ("dev", "ino")}:
        raise RuntimeError(f"owned image identity changed: {image}")


def _read_volume(record):
    _validate_image(record)
    mount = record["mount"]
    entities = _active(record["image"])
    mounted = [x for x in entities if x.get("mount-point")]
    st = Path(mount).lstat()
    if (len(mounted) != 1 or os.path.realpath(mounted[0]["mount-point"]) != mount or
            not stat.S_ISDIR(st.st_mode) or st.st_dev == record["mountpoint_identity"]["dev"]):
        raise RuntimeError(f"owned APFS image is not mounted at {mount}")
    info = _plist(DISKUTIL, "info", "-plist", mount)
    volume = _device(info["DeviceNode"])
    if (mounted[0]["dev-entry"] != volume or os.path.realpath(info["MountPoint"]) != mount or
            info["FilesystemType"] != "apfs" or info["VolumeName"] != record["volume_name"] or
            info.get("APFSSnapshot") is not False or info.get("Internal") is not False or
            info.get("BusProtocol") != "Disk Image"):
        raise RuntimeError(f"unexpected APFS volume at {mount}")
    container = _device(info["APFSContainerReference"])
    stores = info["APFSPhysicalStores"]
    if len(stores) != 1:
        raise RuntimeError(f"unexpected APFS physical stores for {volume}")
    partition = _device(stores[0]["APFSPhysicalStore"])
    store = _plist(DISKUTIL, "info", "-plist", partition)
    whole = _device(store["ParentWholeDisk"])
    devices = {x.get("dev-entry") for x in entities}
    if len({volume, container, whole, partition}) != 4 or not {volume, container, whole, partition} <= devices:
        raise RuntimeError(f"APFS devices do not belong to the owned sparseimage at {mount}")
    containers = _plist(DISKUTIL, "apfs", "list", "-plist", container)["Containers"]
    if len(containers) != 1:
        raise RuntimeError(f"unexpected APFS container inventory for {volume}")
    apfs = containers[0]
    partition_uuid = _uuid(store["DiskUUID"])
    if (_device(apfs["ContainerReference"]) != container or
            _device(apfs["DesignatedPhysicalStore"]) != partition or
            len(apfs["PhysicalStores"]) != 1 or
            _uuid(apfs["PhysicalStores"][0]["DiskUUID"]) != partition_uuid):
        raise RuntimeError(f"APFS container and physical store disagree for {volume}")
    return {
        "volume": {"device": volume, "uuid": _uuid(info["VolumeUUID"]), "name": info["VolumeName"],
                   "dev": st.st_dev, "fs": "apfs", "snapshot": False},
        "container": {"device": container, "uuid": _uuid(apfs["APFSContainerUUID"])},
        "backing": {"image_device": whole, "partition_device": partition, "partition_uuid": partition_uuid},
    }


def _same_uuid_chain(left, right):
    return (left["volume"]["uuid"] == right["volume"]["uuid"] and
            left["container"]["uuid"] == right["container"]["uuid"] and
            left["backing"]["partition_uuid"] == right["backing"]["partition_uuid"])


def _file_record(path, dev):
    try:
        st = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_dev != dev:
        raise RuntimeError(f"unexpected file on APFS volume: {path}")
    return {"path": str(path), "name": path.name, **_identity(st), "mode": st.st_mode,
            "size": st.st_size, "mtime_ns": st.st_mtime_ns}


def _read_files(mount, dev):
    root = Path(mount)
    log_dir = root / ".fseventsd"
    files = []
    if os.path.lexists(log_dir):
        st = log_dir.lstat()
        if not stat.S_ISDIR(st.st_mode) or st.st_dev != dev:
            raise RuntimeError(f"unexpected FSEvents directory on APFS volume: {log_dir}")
        files = [_file_record(path, dev) for path in sorted(log_dir.iterdir())]
    files = [item for item in files if item is not None]
    journal = [item for item in files if item["name"] not in {"no_log", "fseventsd-uuid"}]
    return {
        "markers": {"no_log": next((item for item in files if item["name"] == "no_log"), None),
                    "metadata_never_index": _file_record(root / ".metadata_never_index", dev)},
        "fsevents": {"journal": journal, "journal_files": len(journal),
                     "journal_bytes": sum(item["size"] for item in journal),
                     "directory_present": os.path.lexists(log_dir),
                     "identity_file": next((item for item in files if item["name"] == "fseventsd-uuid"), None)},
    }


def _seed(mount, dev):
    root = Path(mount)
    log_dir = root / ".fseventsd"
    log_dir.mkdir(mode=0o755, exist_ok=True)
    st = log_dir.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_dev != dev:
        raise RuntimeError(f"unexpected FSEvents directory on APFS volume: {log_dir}")
    for path in (log_dir / "no_log", root / ".metadata_never_index"):
        fd = os.open(path, os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o644)
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_size or st.st_dev != dev:
                raise RuntimeError(f"unexpected APFS policy marker: {path}")
        finally:
            os.close(fd)


def _spotlight(mount, *, require_disabled):
    for retry in range(12):
        info = _command(MDUTIL, "-s", "-v", mount)
        lines = [line.strip() for line in info["stdout"].splitlines() if line.strip()]
        info["disabled"] = (info["returncode"] == 0 and len(lines) == 2 and
                            lines[0] in {f"{mount}:", f"/System/Volumes/Data{mount}:"} and
                            lines[1] in DISABLED)
        if info["disabled"] or not require_disabled:
            return info
        if retry != 11:
            time.sleep(0.25)
    raise RuntimeError(f"Spotlight did not report disabled for {mount}: {json.dumps(info)}")


def _observe(record, actual):
    files = _read_files(record["mount"], actual["volume"]["dev"])
    if record["disabled"] and any(item is None or item["size"] != 0 for item in files["markers"].values()):
        raise RuntimeError("the remounted image is missing an empty APFS policy marker")
    return {**record, **actual, **files,
            "spotlight": _spotlight(record["mount"], require_disabled=record["disabled"]),
            "observed_at": _now()}


def _mount_image(record, *, read_only=False):
    _validate_image(record)
    _unmounted(record)
    # A normal, browse-eligible attachment registers with Spotlight even at a
    # private mount point. Keep Finder from opening that mount point.
    return _checked(HDI, "attach", *(["-readonly"] if read_only else []),
                    "-noautoopen", "-owners", "off", "-mountpoint", record["mount"],
                    "-plist", record["image"])


def _attach(record):
    _mount_image(record)
    return _read_volume(record)


def _release(record, device):
    _validate_image(record)
    if device not in {entry.get("dev-entry") for entry in _active(record["image"])}:
        raise RuntimeError(f"refusing to detach {device} without the owned sparseimage attachment")
    command = _checked(HDI, "detach", _device(device))
    if _active(record["image"]):
        raise RuntimeError(f"sparseimage remains attached: {record['image']}")
    _unmounted(record)
    return command


def _detach_owned_attachment(record):
    _validate_image(record)
    active = _active(record["image"])
    if active:
        whole = [x["dev-entry"] for x in active if x.get("content-hint") == "GUID_partition_scheme"]
        if len(whole) == 1:
            device = _device(whole[0])
        else:
            device = _read_volume(record)["backing"]["image_device"]
        _release(record, device)
    _unmounted(record)


def _rollback(record):
    _detach_owned_attachment(record)
    _validate_image(record)
    Path(record["image"]).unlink()


def create(image, mount, *, size_gib=16, disabled=True):
    """Provision and attest a fresh volume at an existing empty mount path."""
    image, mount = _owned_paths(image, mount)
    if type(size_gib) is not int or size_gib < 1 or type(disabled) is not bool:
        raise ValueError("size_gib must be a positive integer and disabled must be a boolean")
    if os.path.lexists(image):
        raise FileExistsError(image)
    label = f"MicropodCI-{uuid.uuid4().hex[:12]}"
    record = {"schema": SCHEMA, "image": str(image), "mount": str(mount), "size_gib": size_gib,
              "disabled": disabled, "volume_name": label, "mountpoint_identity": _identity(mount.lstat())}
    _unmounted(record)
    published = False
    try:
        with tempfile.TemporaryDirectory(prefix=".worker-apfs-", dir=image.parent) as staging:
            staged_image = Path(staging) / image.name
            _checked(HDI, "create", "-size", f"{size_gib}g", "-type", "SPARSE", "-fs", "APFS",
                     "-volname", label, *(["-nospotlight"] if disabled else []), str(staged_image))
            format_name = _plist(HDI, "imageinfo", "-plist", str(staged_image))["Format"]
            if format_name != "SPRS":
                raise RuntimeError(f"unexpected disk image format {format_name}")
            record["image_identity"] = {**_image_identity(staged_image), "format": format_name}
            os.link(staged_image, image, follow_symlinks=False)
            published = True
            staged_image.unlink()
        actual = _attach(record)
        if disabled:
            _seed(str(mount), actual["volume"]["dev"])
            record["spotlight_apply"] = _command(MDUTIL, "-i", "off", str(mount))
            record["seed_identity"] = actual
            record["seed_detach"] = _release(record, actual["backing"]["image_device"])
            actual = _attach(record)
            if not _same_uuid_chain(actual, record["seed_identity"]):
                raise RuntimeError("APFS volume identities changed across marker remount")
            record["remounted"] = True
        else:
            record["remounted"] = False
        return _observe(record, actual)
    except BaseException as original:
        if published:
            try:
                _rollback(record)
            except Exception as cleanup:
                sidecar = image.with_suffix(".apfs-recovery.json")
                try:
                    with sidecar.open("x") as out:
                        json.dump({**record, "error": str(original), "cleanup_error": str(cleanup)}, out, indent=2)
                except OSError as journal_error:
                    raise RuntimeError(f"APFS cleanup failed for {image}: {cleanup}; recovery receipt: {record}; "
                                       f"could not write {sidecar}: {journal_error}") from original
                raise RuntimeError(f"APFS cleanup requires inspection of {sidecar}: {cleanup}") from original
        raise


def verify(receipt):
    """Read actual identities, markers, journal and Spotlight again on a live volume."""
    actual = _read_volume(receipt)
    if any(actual[key] != receipt[key] for key in ("volume", "container", "backing")):
        raise RuntimeError("the mounted APFS volume no longer matches its original receipt")
    fresh = _observe(receipt, actual)
    fresh["journal_unchanged"] = fresh["fsevents"]["journal"] == receipt["fsevents"]["journal"]
    return fresh


def _without_device(file):
    # APFS file inode and metadata persist. Darwin assigns st_dev on each mount.
    return None if file is None else {key: value for key, value in file.items() if key != "dev"}


def _raw_identity(file):
    return None if file is None else (file["ino"], file["size"])


def _inspect_history(receipt, raw_disk_before_detach):
    mount = receipt["mount"]
    try:
        attach = _mount_image(receipt, read_only=True)
        actual = _read_volume(receipt)
        if not _same_uuid_chain(actual, receipt):
            raise RuntimeError("APFS UUIDs changed on the read-only remount")
        mount_flags = os.statvfs(mount).f_flag
        read_only = bool(mount_flags & os.ST_RDONLY)
        flags = _plist(DISKUTIL, "info", "-plist", mount)
        writable = {key: flags.get(key) for key in ("Writable", "WritableMedia", "WritableVolume")}
        if not read_only or not all(value is False for value in writable.values()):
            raise RuntimeError(f"APFS history mount is not read-only: {mount_flags}, {writable}")
        raw_disk = _file_record(Path(mount) / "worker.ext4", actual["volume"]["dev"])
        same_raw_disk = _raw_identity(raw_disk) == _raw_identity(raw_disk_before_detach)
        if not same_raw_disk:
            raise RuntimeError("worker.ext4 inode or size changed on the read-only remount")
        observation = _observe(receipt, actual)
        journal_before = [_without_device(item) for item in receipt["fsevents"]["journal"]]
        journal_after = [_without_device(item) for item in observation["fsevents"]["journal"]]
        markers_unchanged = all(_without_device(item) == _without_device(receipt["markers"][key])
                                for key, item in observation["markers"].items())
        retired = _release(receipt, actual["backing"]["image_device"])
        return {**actual, **{key: observation[key] for key in ("markers", "fsevents", "spotlight", "observed_at")},
                "attach": attach, "detach": retired, "image_identity": receipt["image_identity"],
                "mounted_read_only": read_only, "mount_flags": mount_flags, "mount_read_only_bit": os.ST_RDONLY,
                "diskutil_writable": writable, "journal_unchanged": journal_before == journal_after,
                "markers_unchanged": markers_unchanged, "raw_disk_before_detach": raw_disk_before_detach,
                "raw_disk": raw_disk, "raw_disk_unchanged": same_raw_disk}
    except BaseException as original:
        # A rejected readback still owns the attachment. Leave the image file
        # for inspection only after attempting to restore the empty mountpoint.
        try:
            _detach_owned_attachment(receipt)
        except Exception as cleanup:
            raise RuntimeError(f"could not retire history mount {mount}: {cleanup}; "
                               f"preserved image {receipt['image']}") from original
        raise


def detach(receipt, *, remove_image=True, inspect_history=True):
    """Retire a drive and attest flushed policy on a read-only remount before removal."""
    _validate_image(receipt)
    actual = _read_volume(receipt)
    if any(actual[key] != receipt[key] for key in ("volume", "container", "backing")):
        raise RuntimeError("refusing to detach an APFS volume that differs from the original receipt")
    try:
        raw_disk = (_file_record(Path(receipt["mount"]) / "worker.ext4", actual["volume"]["dev"])
                    if inspect_history else None)
    finally:
        retired = _release(receipt, actual["backing"]["image_device"])
    history = {"persisted_policy": _inspect_history(receipt, raw_disk)} if inspect_history else {}
    if inspect_history and receipt["disabled"]:
        unchanged = ("journal_unchanged", "markers_unchanged", "raw_disk_unchanged")
        changed = [key for key in unchanged if not history["persisted_policy"][key]]
        if changed:
            raise RuntimeError(f"disabled APFS read-only history check failed for {', '.join(changed)}; "
                               f"preserved detached image {receipt['image']}")
    image = Path(receipt["image"])
    _validate_image(receipt)
    if remove_image:
        image.unlink()
    return {"schema": SCHEMA, "image": str(image), "mount": receipt["mount"],
            "image_identity": receipt["image_identity"], **actual, "detach": retired, "detached": True,
            "image_absent": not os.path.lexists(image), "removed_image": remove_image,
            "mountpoint_identity": receipt["mountpoint_identity"], "mount_restored": True,
            "observed_at": _now(), **history}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    provision = commands.add_parser("create")
    provision.add_argument("image", type=Path)
    provision.add_argument("mount", type=Path)
    provision.add_argument("--size-gib", type=int, default=16)
    provision.add_argument("--control", action="store_true")
    observe = commands.add_parser("verify")
    observe.add_argument("receipt", type=Path)
    retire = commands.add_parser("detach")
    retire.add_argument("receipt", type=Path)
    retire.add_argument("--keep-image", action="store_true")
    retire.add_argument("--skip-history", action="store_true")
    args = parser.parse_args()
    if args.command == "create":
        result = create(args.image, args.mount, size_gib=args.size_gib, disabled=not args.control)
    else:
        receipt = json.loads(args.receipt.read_text())
        result = (verify(receipt) if args.command == "verify" else
                  detach(receipt, remove_image=not args.keep_image, inspect_history=not args.skip_history))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
