"""Provide and attest a disposable APFS-backed disk for each native arm."""

from importlib.util import module_from_spec, spec_from_file_location
import json
import os
from pathlib import Path
import plistlib
import subprocess


POLICY = "apfs-no-index"
VOLUME_GIB = 16
WORKER_GIB = 6
APFS_SOURCE = Path(__file__).resolve().parent.parent / "gamma-ci-concurrency/worker_apfs_drive.py"


def load_apfs():
    # Load the shared implementation in its sibling directory without loading
    # the dense benchmark or altering how the CLI resolves other modules.
    spec = spec_from_file_location("local_worker_apfs_drive", APFS_SOURCE)
    module = module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require(condition, message):
    if not condition:
        raise ValueError(message)


def disk_state(home):
    raw = home / "worker.ext4"
    info = plistlib.loads(subprocess.check_output(["/usr/sbin/diskutil", "info", "-plist", home], timeout=10))
    root, disk, parent = home.stat(), raw.stat(), home.parent.stat()
    config = json.loads((home / "worker.json").read_bytes())
    require(home.is_mount() and raw.is_file() and not raw.is_symlink() and
            root.st_dev == disk.st_dev != parent.st_dev and config["diskGiB"] == WORKER_GIB
            and disk.st_size >= config["diskGiB"] * 1024**3,
            "the configured worker disk does not reside on its dedicated volume")
    require(info["FilesystemType"].lower() == "apfs" and Path(info["MountPoint"]).resolve() == home
            and info.get("VolumeUUID"), "unexpected host filesystem under worker.ext4")
    return {"mount": str(home), "raw_disk": str(raw), "mount_st_dev": root.st_dev,
            "raw_st_dev": disk.st_dev, "parent_st_dev": parent.st_dev, "raw_inode": disk.st_ino,
            "raw_bytes": disk.st_size, "configured_disk_gib": config["diskGiB"], "volume_uuid": info["VolumeUUID"],
            "device": info["DeviceIdentifier"], "filesystem": info["FilesystemType"]}


class WorkerDrive:
    def __init__(self, apfs, save):
        self.apfs = apfs
        self.save = save
        self.drives = {}
        self.live_disks = {}

    def attach(self, root, home, manifest):
        require(root.parent == Path("/private/tmp") and home.parent == root
                and home not in self.drives and not any(home.iterdir()), "unexpected private worker directory")
        image = root / (home.name + "-worker.sparseimage")
        drive = self.apfs.create(image, home, size_gib=VOLUME_GIB, disabled=True)
        self.drives[home] = drive
        self.save(manifest / "host-volume-created.json", drive)
        require(home.is_mount() and home.stat().st_dev != root.stat().st_dev,
                "expected APFS volume at the worker home")
        home.chmod(0o700)
        attrs = home.stat()
        require(attrs.st_uid == os.getuid() and attrs.st_mode & 0o777 == 0o700,
                "mounted worker home must be private and owned by this account")

    def verify_disk(self, home, manifest):
        checked = self.apfs.verify(self.drives[home])
        raw = disk_state(home)
        self.live_disks[home] = (raw["raw_inode"], raw["raw_bytes"])
        self.save(manifest / "host-volume-live.json", {"volume": checked, "disk": raw})
        require(checked["journal_unchanged"] is True, "FSEvents journal changed before timing")

    def close(self, home, manifest):
        drive = self.drives.get(home)
        if drive is None:
            require(not home.is_mount(), "unreconciled worker volume attachment")
            return
        # Run checks the launchd job and its disk holders before calling close.
        try:
            state = disk_state(home) if (home / "worker.ext4").exists() else None
            checked = self.apfs.verify(drive)
            self.save(manifest / "host-volume-before-detach.json", {"volume": checked, "disk": state})
            require(checked["journal_unchanged"] is True, "FSEvents journal changed during the worker run")
        finally:
            result = self.apfs.detach(drive, remove_image=True, inspect_history=True,
                                      expected_raw_identity=self.live_disks.get(home))
            image = home.parent / (home.name + "-worker.sparseimage")
            require(not home.is_mount() and not image.exists(), "worker image or mount remains")
            self.save(manifest / "host-volume-detached.json",
                      {"mount": str(home), "image": str(image), "mounted": False,
                       "image_exists": False, "result": result})
            del self.drives[home]
            self.live_disks.pop(home, None)
