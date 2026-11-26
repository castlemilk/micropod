"""Verify the archived backing-disk and retirement receipts for a private APFS worker volume."""

import argparse
import ast
import json
import plistlib
import re
import stat
from pathlib import Path

from qualify import require, terminal
from sibling_results import docker_time_ns, read


POLICY = "apfs-no-index"
ORDINARY = "ordinary"
SCHEMA = "micropod-worker-apfs-v1"
VOLUME_GIB = 16
WORKER_GIB = 6
RECEIPTS = ("a/host-volume-created.json", "a/host-volume-live.json", "a/host-volume-before-detach.json",
            "a/host-volume-detached.json")
SOURCES = {"sibling_worker_volume.py": "host_volume_driver_sha256", "worker_apfs_drive.py": "host_volume_helper_sha256"}
PROVIDER_SOURCE = "local_worker_drive.py"
PROVIDER_FIELD = "host_volume_provider_sha256"
VOLUME_FIELD = "host_worker_volume"
SIZE_FIELD = "host_worker_volume_gib"
FINAL_HISTORY = "host_worker_volume_final_history"
UUID = r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}"


def volume_strategy(folder, plan):
    if VOLUME_FIELD in plan:
        size = plan.get(SIZE_FIELD)
        require(plan[VOLUME_FIELD] == POLICY and type(size) is int and size == VOLUME_GIB and
                type(plan.get(FINAL_HISTORY, False)) is bool,
                "invalid worker host-volume strategy or image capacity")
        return POLICY
    require(SIZE_FIELD not in plan and FINAL_HISTORY not in plan and PROVIDER_FIELD not in plan and
            all(name not in plan for name in SOURCES.values()) and
            not any((folder / name).exists() for name in (*RECEIPTS, *SOURCES, PROVIDER_SOURCE)),
            "ordinary worker claim carries undeclared dedicated volume evidence")
    return ORDINARY


def verify_sources(folder, plan):
    require(all((folder / name).is_file() and terminal.digest(folder / name) == plan.get(key)
                for name, key in SOURCES.items()), "archived APFS worker adapter or provisioning helper differs")
    adapter = ast.parse((folder / "sibling_worker_volume.py").read_text())
    shared = any((isinstance(node, ast.Import) and any(alias.name == "local_worker_drive" for alias in node.names)) or
                 (isinstance(node, ast.ImportFrom) and node.module == "local_worker_drive")
                 for node in ast.walk(adapter))
    provider = folder / PROVIDER_SOURCE
    require(shared == (PROVIDER_FIELD in plan) == (provider.exists() or provider.is_symlink()),
            "APFS worker provider evidence does not match the archived adapter")
    if shared:
        require(provider.is_file() and not provider.is_symlink() and terminal.digest(provider) == plan[PROVIDER_FIELD],
                "archived shared APFS worker provider differs")
        require(plan.get(FINAL_HISTORY) is True, "shared APFS worker provider requires read-only history")


def same_path(value, expected):
    path = Path(value)
    return path.is_absolute() and path.resolve() == expected


def identity_uuid(value):
    require(isinstance(value, str) and re.fullmatch(UUID, value.lower()) and value.replace("-", "").strip("0"),
            "invalid private APFS identity UUID")
    return value.lower()


def device_name(value, *, whole=False):
    device = value.removeprefix("/dev/")
    require(re.fullmatch(r"disk[0-9]+" if whole else r"disk[0-9]+s[0-9]+", device), "invalid private APFS device identifier")
    return device


def positive(value):
    return type(value) is int and value > 0


def volume_identity(record, mount, image):
    require(same_path(record["image"], image) and same_path(record["mount"], mount) and record["disabled"] is True and
            type(record["size_gib"]) is int and record["size_gib"] == VOLUME_GIB,
            "APFS receipt has the wrong private scope, volume policy or image capacity")
    require(record["volume_name"] == record["volume"]["name"], "private APFS volume name changed")
    return storage_identity(record)


def storage_identity(record):
    actual, container, backing, file = (record[key] for key in ("volume", "container", "backing", "image_identity"))
    mountpoint = record["mountpoint_identity"]
    require(record["schema"] == SCHEMA and actual["fs"].lower() == "apfs" and actual["snapshot"] is False and
            positive(file["dev"]) and positive(file["ino"]) and file["format"] == "SPRS" and
            positive(actual["dev"]) and actual["dev"] != file["dev"] and mountpoint["dev"] == file["dev"] and
            positive(mountpoint["ino"]) and re.fullmatch(r"MicropodCI-[a-f0-9]{12}", actual["name"]),
            "expected a separate APFS mount backed by the private sparseimage")
    volume_device = device_name(actual["device"])
    container_device = device_name(container["device"], whole=True)
    image_device = device_name(backing["image_device"], whole=True)
    partition_device = device_name(backing["partition_device"])
    require(container_device != image_device and volume_device.startswith(container_device + "s") and
            partition_device.startswith(image_device + "s"), "APFS volume, container and sparseimage device ancestry disagree")
    return {"volume_uuid": identity_uuid(actual["uuid"]), "container_uuid": identity_uuid(container["uuid"]),
            "partition_uuid": identity_uuid(backing["partition_uuid"]), "device": volume_device,
            "container_device": container_device, "image_device": image_device, "partition_device": partition_device,
            "volume_st_dev": actual["dev"], "image_st_dev": file["dev"], "image_inode": file["ino"],
            "volume_name": actual["name"], "mountpoint_inode": mountpoint["ino"]}


def raw_identity(disk, volume, mount):
    expected = mount / "worker.ext4"
    require(same_path(disk["mount"], mount) and same_path(disk["raw_disk"], expected) and
            identity_uuid(disk["volume_uuid"]) == volume["volume_uuid"] and
            device_name(disk["device"]) == volume["device"] and disk["filesystem"].lower() == "apfs",
            "worker RAW disk points outside the attested APFS volume or scope")
    require(all(positive(disk[key]) for key in ("mount_st_dev", "raw_st_dev", "parent_st_dev", "raw_inode", "raw_bytes")) and
            disk["mount_st_dev"] == disk["raw_st_dev"] == volume["volume_st_dev"] != disk["parent_st_dev"] and
            disk["parent_st_dev"] == volume["image_st_dev"], "worker RAW disk is on the wrong host device")
    require(type(disk["configured_disk_gib"]) is int and disk["configured_disk_gib"] == WORKER_GIB and
            WORKER_GIB * 2**30 <= disk["raw_bytes"] < VOLUME_GIB * 2**30, "worker RAW disk capacity differs")
    return {"path": str(expected), **{key: disk[key] for key in ("raw_st_dev", "parent_st_dev", "raw_inode",
                                                                 "raw_bytes", "configured_disk_gib")}}


def check_markers(markers, mount, dev):
    wanted = {"no_log": ".fseventsd/no_log", "metadata_never_index": ".metadata_never_index"}
    require(markers.keys() == wanted.keys(), "required FSEvents or Spotlight marker missing")
    for label, relative in wanted.items():
        row = markers[label]
        require(file_on_volume(row, mount / relative, dev) and row["size"] == 0,
                f"invalid {label} marker on the private APFS volume")


def file_on_volume(row, path, dev):
    return (isinstance(row, dict) and row["name"] == path.name and same_path(row["path"], path) and
            positive(row["ino"]) and row["dev"] == dev and positive(row["mtime_ns"]) and
            type(row["mode"]) is int and stat.S_ISREG(row["mode"]) and type(row["size"]) is int and row["size"] >= 0)


def spotlight_state(spotlight, mount):
    args = spotlight["argv"]
    require(args[:3] == ["/usr/bin/mdutil", "-s", "-v"] and len(args) == 4 and same_path(args[-1], mount) and
            type(spotlight["returncode"]) is int and spotlight["returncode"] == 0 and spotlight["disabled"] is True and
            not spotlight["stderr"].strip(), "fresh Spotlight status did not query the attested private volume")
    lines = [line.strip() for line in spotlight["stdout"].splitlines() if line.strip()]
    require(len(lines) == 2 and lines[0].endswith(":") and
            (same_path(lines[0][:-1], mount) or lines[0] == f"/System/Volumes/Data{mount}:") and
            lines[1] in ("Indexing disabled.", "Indexing and searching disabled."),
            "fresh mdutil output did not confirm disabled indexing on the private volume")
    return lines[1]


def journal_state(fsevents, mount, dev):
    entries = fsevents["journal"]
    directory = mount / ".fseventsd"
    identity = fsevents["identity_file"]
    require(fsevents["directory_present"] is True and
            (identity is None or file_on_volume(identity, directory / "fseventsd-uuid", dev)),
            "FSEvents journal directory or identity did not belong to the private volume")
    names = set()
    for row in entries:
        name = row["name"]
        require(name and name not in (".", "..", "no_log", "fseventsd-uuid") and Path(name).name == name and
                name not in names and file_on_volume(row, directory / name, dev), "invalid or unreadable FSEvents journal inventory")
        names.add(name)
    require(fsevents["journal_files"] == len(entries) and fsevents["journal_bytes"] == sum(row["size"] for row in entries),
            "FSEvents journal counts do not match the raw inventory")
    return sorted(entries, key=lambda row: row["name"])


def check_detach(detached, volume, mount, image):
    require(same_path(detached["mount"], mount) and same_path(detached["image"], image) and
            detached["mounted"] is False and detached["image_exists"] is False,
            "dedicated APFS image or mount remained after retirement")
    result = detached["result"]
    require(same_path(result["mount"], mount) and same_path(result["image"], image) and
            storage_identity(result) == volume and result["detached"] is True and result["image_absent"] is True and
            result["removed_image"] is True and result["mount_restored"] is True and
            detach_time(result["detach"], volume["image_device"]) < docker_time_ns(result["observed_at"]),
            "detach receipt does not retire the attested APFS image")
    return result


def detach_time(command, device):
    require(command["argv"] == ["/usr/bin/hdiutil", "detach", "/dev/" + device] and
            type(command["returncode"]) is int and command["returncode"] == 0,
            "hdiutil detach did not succeed on the attested sparseimage device")
    return docker_time_ns(command["observed_at"])


def check_provisioning(created, identity, mount):
    seed = created["seed_identity"]
    cmd = created["spotlight_apply"]
    require(created["remounted"] is True and cmd["argv"] == ["/usr/bin/mdutil", "-i", "off", str(mount)] and
            identity_uuid(seed["volume"]["uuid"]) == identity["volume_uuid"] and
            identity_uuid(seed["container"]["uuid"]) == identity["container_uuid"] and
            identity_uuid(seed["backing"]["partition_uuid"]) == identity["partition_uuid"],
            "APFS volume was not observed after remounting its seeded policy markers")
    seed_detached = detach_time(created["seed_detach"], device_name(seed["backing"]["image_device"], whole=True))
    require(0 < docker_time_ns(cmd["observed_at"]) < seed_detached < docker_time_ns(created["spotlight"]["observed_at"]),
            "APFS marker seed and positive Spotlight status are out of order")


def same_persisted_file(left, right):
    fields = ("name", "ino", "mode", "size", "mtime_ns")
    return all(left[key] == right[key] for key in fields)


def verify_persisted_history(result, policy, raw, prior_journal, mount, image):
    history = result["persisted_policy"]
    identity = storage_identity({**history, "schema": result["schema"],
                                 "mountpoint_identity": result["mountpoint_identity"]})
    before = storage_identity(result)
    require(all(identity[key] == before[key] for key in ("volume_uuid", "container_uuid", "partition_uuid",
                                                         "volume_name", "image_st_dev", "image_inode")),
            "read-only history was observed on a different APFS image or volume")
    attach = history["attach"]
    require(attach["argv"] == ["/usr/bin/hdiutil", "attach", "-readonly", "-noautoopen", "-owners", "off",
                               "-mountpoint", str(mount), "-plist", str(image)] and
            type(attach["returncode"]) is int and attach["returncode"] == 0 and
            history["mounted_read_only"] is True and type(history["mount_read_only_bit"]) is int and
            history["mount_read_only_bit"] == 1 and type(history["mount_flags"]) is int and history["mount_flags"] & 1 and
            history["diskutil_writable"].keys() == {"Writable", "WritableMedia", "WritableVolume"} and
            all(value is False for value in history["diskutil_writable"].values()),
            "post-shutdown APFS history did not use an actual read-only attachment")
    entities = plistlib.loads(attach["stdout"].encode())["system-entities"]
    mounted = [entry for entry in entities if entry.get("mount-point")]
    devices = {entry["dev-entry"].removeprefix("/dev/") for entry in entities}
    require(len(mounted) == 1 and same_path(mounted[0]["mount-point"], mount) and
            device_name(mounted[0]["dev-entry"]) == identity["device"] and
            {identity[key] for key in ("device", "container_device", "image_device", "partition_device")} <= devices,
            "read-only attachment output does not identify the observed private volume")
    spotlight = spotlight_state(history["spotlight"], mount)
    require(detach_time(result["detach"], before["image_device"]) < docker_time_ns(attach["observed_at"]) <=
            docker_time_ns(history["spotlight"]["observed_at"]) <= docker_time_ns(history["observed_at"]) <
            detach_time(history["detach"], identity["image_device"]) <
            docker_time_ns(result["observed_at"]), "read-only history and detach timestamps are out of order")

    check_markers(history["markers"], mount, identity["volume_st_dev"])
    require(history["markers_unchanged"] is True and all(same_persisted_file(marker, history["markers"][key])
                                                        for key, marker in policy["markers"].items()),
            "read-only remount found different on-disk policy markers")
    journal = journal_state(history["fsevents"], mount, identity["volume_st_dev"])
    require(history["journal_unchanged"] is True and len(journal) == len(prior_journal) and
            all(same_persisted_file(left, right) for left, right in zip(prior_journal, journal, strict=True)),
            "read-only remount found a new or changed persistent FSEvents journal")
    original, persisted = history["raw_disk_before_detach"], history["raw_disk"]
    path = mount / "worker.ext4"
    require(file_on_volume(original, path, raw["raw_st_dev"]) and original["ino"] == raw["raw_inode"] and
            original["size"] == raw["raw_bytes"] and file_on_volume(persisted, path, identity["volume_st_dev"]) and
            history["raw_disk_unchanged"] is True and original["ino"] == persisted["ino"] and original["size"] == persisted["size"],
            "read-only remount has the wrong worker RAW disk inode or size")
    return {"read_only": True, "device": identity["device"], "volume_st_dev": identity["volume_st_dev"],
            "raw_inode": persisted["ino"], "raw_bytes": persisted["size"], "spotlight": spotlight,
            "journal_files": len(journal), "journal_bytes": sum(row["size"] for row in journal)}


def verify_volume(folder):
    """Verify host-volume evidence for a completed disk trial or phase diagnostic."""
    folder = Path(folder).resolve()
    plan = read(folder, "plan.json")
    require(volume_strategy(folder, plan) == POLICY, "archive has no dedicated APFS worker volume")
    status, cleanup = (read(folder, name) for name in ("status.json", "cleanup.json"))
    scope = Path(plan["scope"]).resolve()
    require(scope.parent == Path("/private/tmp") and re.fullmatch(r"mp-t-[a-z0-9_]{8}", scope.name),
            "APFS worker is outside the disposable benchmark scope")
    require(status["complete"] is True and not status.get("error") and cleanup["scope"] == plan["scope"] and
            cleanup["retained"] is False and cleanup["errors"] == [] and not scope.exists(), "APFS worker cleanup did not complete")
    require(all((folder / name).is_file() for name in RECEIPTS), "missing dedicated APFS worker lifecycle or detach receipt")
    verify_sources(folder, plan)
    mount, image = scope / "a", scope / "a-worker.sparseimage"
    launch = plistlib.loads((folder / "a/job.plist").read_bytes())
    env = launch["EnvironmentVariables"]
    require(same_path(env["MICROPOD_CI_HOME"], mount) and env["MICROPOD_CI_DISK_GIB"] == str(WORKER_GIB) and
            read(folder, "a/worker.json")["diskGiB"] == WORKER_GIB and launch["ProgramArguments"][1:] == ["ci", "serve"],
            "native launch did not use the private worker volume and expected disk capacity")

    created, live, post, detached = (read(folder, name) for name in RECEIPTS)
    records = (created, live["volume"], post["volume"])
    identities = [volume_identity(record, mount, image) for record in records]
    first = identities[0]
    require(all(identity == first for identity in identities), "private APFS volume changed during the worker lifetime")
    check_provisioning(created, first, mount)
    dev = first["volume_st_dev"]
    journal, spotlight = [], []
    for record in records:
        check_markers(record["markers"], mount, dev)
        journal.append(journal_state(record["fsevents"], mount, dev))
        spotlight.append(spotlight_state(record["spotlight"], mount))
    require(journal[0] == journal[1] == journal[2] and all(record["journal_unchanged"] is True for record in records[1:]),
            "persistent FSEvents journal changed during the worker lifetime")
    require(all(record["markers"] == created["markers"] for record in records[1:]),
            "private APFS policy marker identity changed during the worker lifetime")
    before, after = (raw_identity(record["disk"], first, mount) for record in (live, post))
    require(before == after, "worker RAW disk identity changed before retirement")
    retirement = check_detach(detached, first, mount, image)
    observed = [docker_time_ns(record["observed_at"]) for record in records]
    status_times = [docker_time_ns(record["spotlight"]["observed_at"]) for record in records]
    require(0 < status_times[0] <= observed[0] < status_times[1] <= observed[1] < status_times[2] <= observed[2] <
            detach_time(retirement["detach"], first["image_device"]),
            "APFS creation, fresh status checks and detachment are out of order")
    output = {"host_worker_volume": POLICY, "scope": str(scope), "mount": str(mount), "image": str(image), **first,
              "raw_disk": before, "spotlight": {"live": spotlight[1], "post": spotlight[2]},
              "journal_files": len(journal[0]), "journal_bytes": sum(row["size"] for row in journal[0]),
              "journal_observed_through": "pre_detach", "live_observed_unix_ns": observed[1],
              "post_observed_unix_ns": observed[2], "detached": True}
    history = retirement.get("persisted_policy")
    require((history is not None) is plan.get(FINAL_HISTORY, False), "read-only history differs from the worker volume plan")
    if history is not None:
        output["persisted_policy"] = verify_persisted_history(retirement, records[2], before, journal[2], mount, image)
        output["journal_observed_through"] = "read_only_remount"
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    print(json.dumps(verify_volume(parser.parse_args().folder), indent=2, allow_nan=False))
