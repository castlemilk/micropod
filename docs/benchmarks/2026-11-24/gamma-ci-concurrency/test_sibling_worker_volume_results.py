"""Exercise exact APFS, indexing, journal and retirement evidence."""

import json
import plistlib
import stat
import unittest
from copy import deepcopy
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import sibling_worker_volume as driver
import sibling_worker_volume_results as report


class WorkerVolumeReplayTest(unittest.TestCase):
    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.folder = Path(directory.name)
        (self.folder / "a").mkdir()
        self.scope = Path("/private/tmp/mp-t-test0001")
        self.mount = self.scope / "a"
        self.image = self.scope / "a-worker.sparseimage"
        plan = {report.VOLUME_FIELD: report.POLICY, report.SIZE_FIELD: 16, "scope": str(self.scope)}
        for name, key in report.SOURCES.items():
            path = self.folder / name
            path.write_text("# frozen test fixture source\n")
            plan[key] = report.terminal.digest(path)
        self.save("plan.json", plan)
        self.save("status.json", {"complete": True, "diagnostic_only": True})
        self.save("cleanup.json", {"scope": str(self.scope), "retained": False, "errors": []})
        self.save("a/worker.json", {"diskGiB": 6})
        (self.folder / "a/job.plist").write_bytes(plistlib.dumps({
            "ProgramArguments": ["/test/micropod", "ci", "serve"],
            "EnvironmentVariables": {"MICROPOD_CI_HOME": str(self.mount), "MICROPOD_CI_DISK_GIB": "6"},
        }))
        volume = {"device": "disk12s1", "uuid": "00000000-0000-0000-0000-000000000001", "name": "MicropodCI-123456abcdef",
                  "dev": 90, "fs": "apfs", "snapshot": False}
        markers = {label: {"path": str(self.mount / relative), "ino": inode, "dev": 90, "size": 0,
                           "mode": stat.S_IFREG | 0o600, "name": Path(relative).name, "mtime_ns": 10}
                   for label, relative, inode in (("no_log", ".fseventsd/no_log", 18),
                                                   ("metadata_never_index", ".metadata_never_index", 20))}
        identity = {"schema": report.SCHEMA, "image": str(self.image), "mount": str(self.mount),
                    "image_identity": {"dev": 99, "ino": 12, "format": "SPRS"}, "volume": volume,
                    "mountpoint_identity": {"dev": 99, "ino": 14},
                    "container": {"device": "disk12", "uuid": "00000000-0000-0000-0000-000000000002"},
                    "backing": {"image_device": "/dev/disk11", "partition_device": "/dev/disk11s2",
                                "partition_uuid": "00000000-0000-0000-0000-000000000003"}}
        self.created = {**identity, "disabled": True, "size_gib": 16, "volume_name": volume["name"],
                        "markers": markers, "observed_at": "2026-11-25T05:00:00Z",
                        "spotlight": {"argv": ["/usr/bin/mdutil", "-s", "-v", str(self.mount)], "stderr": "",
                                      "stdout": f"/System/Volumes/Data{self.mount}:\n\tIndexing and searching disabled.\n",
                                      "disabled": True, "returncode": 0, "observed_at": "2026-11-25T04:59:57Z"},
                        "fsevents": {"journal_files": 1, "journal_bytes": 32, "directory_present": True, "identity_file": None,
                                     "journal": [{"name": "0000000000000001", "dev": 90, "ino": 26, "size": 32, "mtime_ns": 10,
                                                  "path": str(self.mount / ".fseventsd/0000000000000001"), "mode": stat.S_IFREG}]},
                        "seed_identity": {key: identity[key] for key in ("volume", "container", "backing")},
                        "spotlight_apply": {"argv": ["/usr/bin/mdutil", "-i", "off", str(self.mount)],
                                            "observed_at": "2026-11-25T04:59:51Z"},
                        "seed_detach": {"argv": ["/usr/bin/hdiutil", "detach", "/dev/disk11"], "returncode": 0,
                                        "observed_at": "2026-11-25T04:59:53Z"}, "remounted": True}
        disk = {"mount": str(self.mount), "raw_disk": str(self.mount / "worker.ext4"), "mount_st_dev": 90, "raw_st_dev": 90,
                "parent_st_dev": 99, "raw_inode": 123, "raw_bytes": 6_576_668_672, "configured_disk_gib": 6,
                "volume_uuid": volume["uuid"], "device": volume["device"], "filesystem": "apfs"}
        self.live = {"volume": {**deepcopy(self.created), "observed_at": "2026-11-25T05:01:00Z", "journal_unchanged": True},
                     "disk": disk}
        self.post = {"volume": {**deepcopy(self.created), "observed_at": "2026-11-25T05:03:00Z", "journal_unchanged": True},
                     "disk": disk.copy()}
        self.live["volume"]["spotlight"]["observed_at"] = "2026-11-25T05:00:59Z"
        self.post["volume"]["spotlight"]["observed_at"] = "2026-11-25T05:02:59Z"
        self.detached = {"mount": str(self.mount), "image": str(self.image), "mounted": False, "image_exists": False,
                         "result": {**identity, "detached": True, "image_absent": True, "removed_image": True,
                                    "mount_restored": True, "observed_at": "2026-11-25T05:04:00Z",
                                    "detach": {"argv": ["/usr/bin/hdiutil", "detach", "/dev/disk11"], "returncode": 0,
                                               "observed_at": "2026-11-25T05:03:59Z"}}}
        for name, data in zip(report.RECEIPTS, (self.created, self.live, self.post, self.detached), strict=True):
            self.save(name, data)

    def save(self, name, data):
        (self.folder / name).write_text(json.dumps(data))

    def test_qualifies_phase_archive_and_distinct_raw_disk_device(self):
        record = report.verify_volume(self.folder)
        self.assertEqual(record["volume_uuid"], "00000000-0000-0000-0000-000000000001")
        self.assertEqual(record["raw_disk"]["raw_st_dev"], record["volume_st_dev"])
        self.assertNotEqual(record["raw_disk"]["parent_st_dev"], record["volume_st_dev"])
        self.assertEqual(record["journal_files"], 1)
        self.assertTrue(record["detached"])

    def test_rejects_symlink_marker_wrong_scope_and_unobserved_spotlight(self):
        for fail in ("marker", "scope", "spotlight"):
            with self.subTest(fail=fail):
                changed = deepcopy(self.live)
                if fail == "marker":
                    changed["volume"]["markers"]["no_log"]["mode"] = stat.S_IFLNK | 0o777
                    message = "invalid no_log marker"
                elif fail == "scope":
                    changed["disk"]["raw_disk"] = "/private/tmp/mp-t-another0/a/worker.ext4"
                    message = "outside the attested APFS volume or scope"
                else:
                    changed["volume"]["spotlight"]["stdout"] = f"{self.mount}:\n\tIndexing enabled.\n"
                    message = "did not confirm disabled indexing"
                self.save(report.RECEIPTS[1], changed)
                with self.assertRaisesRegex(ValueError, message):
                    report.verify_volume(self.folder)

    def test_rejects_wrong_backing_device_or_replacement_journal(self):
        changed = deepcopy(self.post)
        changed["disk"]["raw_st_dev"] = 99
        self.save(report.RECEIPTS[2], changed)
        with self.assertRaisesRegex(ValueError, "wrong host device"):
            report.verify_volume(self.folder)
        changed = deepcopy(self.post)
        journal = changed["volume"]["fsevents"]["journal"][0]
        journal["name"] = "0000000000000002"
        journal["path"] = str(self.mount / ".fseventsd" / journal["name"])
        self.save(report.RECEIPTS[2], changed)
        with self.assertRaisesRegex(ValueError, "persistent FSEvents journal changed"):
            report.verify_volume(self.folder)

    def test_requires_confirmed_detachment_and_rejects_stripped_plan_marker(self):
        detach = self.folder / report.RECEIPTS[-1]
        detach.unlink()
        with self.assertRaisesRegex(ValueError, "missing dedicated APFS worker lifecycle or detach receipt"):
            report.verify_volume(self.folder)
        self.save(report.RECEIPTS[-1], {**self.detached, "result": {**self.detached["result"], "removed_image": False}})
        with self.assertRaisesRegex(ValueError, "does not retire"):
            report.verify_volume(self.folder)
        with self.assertRaisesRegex(ValueError, "undeclared dedicated volume"):
            report.volume_strategy(self.folder, {"scope": str(self.scope)})

    def test_read_only_history_proves_new_device_numbers_for_same_files(self):
        plan = report.read(self.folder, "plan.json")
        self.save("plan.json", {**plan, report.FINAL_HISTORY: True})
        with self.assertRaisesRegex(ValueError, "history differs from the worker volume plan"):
            report.verify_volume(self.folder)
        history = self.add_read_only_history()
        result = report.verify_volume(self.folder)
        self.assertEqual(result["journal_observed_through"], "read_only_remount")
        self.assertEqual(result["persisted_policy"]["volume_st_dev"], 91)

        history["mount_flags"] = 0
        self.save(report.RECEIPTS[-1], self.detached)
        with self.assertRaisesRegex(ValueError, "actual read-only attachment"):
            report.verify_volume(self.folder)
        history["mount_flags"] = 1
        history["raw_disk"]["ino"] = 124
        self.save(report.RECEIPTS[-1], self.detached)
        with self.assertRaisesRegex(ValueError, "wrong worker RAW disk inode or size"):
            report.verify_volume(self.folder)

    def add_read_only_history(self):
        device = 91
        persisted = deepcopy(self.created)
        persisted["volume"].update(dev=device, device="/dev/disk22s1")
        persisted["container"]["device"] = "/dev/disk22"
        persisted["backing"].update(image_device="/dev/disk21", partition_device="/dev/disk21s2")
        for row in (*persisted["markers"].values(), *persisted["fsevents"]["journal"]):
            row["dev"] = device
        raw = {"path": str(self.mount / "worker.ext4"), "name": "worker.ext4", "dev": 90, "ino": 123,
               "size": 6_576_668_672, "mode": stat.S_IFREG | 0o600, "mtime_ns": 10}
        attachment = {"system-entities": [{"mount-point": str(self.mount), "dev-entry": "/dev/disk22s1"},
                                          *({"dev-entry": node} for node in ("/dev/disk21", "/dev/disk21s2", "/dev/disk22"))]}
        history = {**persisted, "mounted_read_only": True, "mount_flags": 1, "mount_read_only_bit": 1,
                   "diskutil_writable": {"Writable": False, "WritableMedia": False, "WritableVolume": False},
                   "raw_disk_before_detach": raw, "raw_disk": {**raw, "dev": device}, "raw_disk_unchanged": True,
                   "journal_unchanged": True, "markers_unchanged": True, "observed_at": "2026-11-25T05:03:59.2Z",
                   "spotlight": {**persisted["spotlight"], "observed_at": "2026-11-25T05:03:59.15Z"},
                   "attach": {"argv": ["/usr/bin/hdiutil", "attach", "-readonly", "-noautoopen", "-owners", "off",
                                       "-mountpoint", str(self.mount), "-plist", str(self.image)], "returncode": 0,
                              "stdout": plistlib.dumps(attachment).decode(), "observed_at": "2026-11-25T05:03:59.1Z"},
                   "detach": {"argv": ["/usr/bin/hdiutil", "detach", "/dev/disk21"], "returncode": 0,
                              "observed_at": "2026-11-25T05:03:59.3Z"}}
        self.detached["result"]["persisted_policy"] = history
        self.save(report.RECEIPTS[-1], self.detached)
        return history

    def test_stage_and_replay_share_the_same_provider_source(self):
        with patch.object(driver.sibling_tmpfs, "stage", return_value={}), driver.mounted_worker_volume():
            staged = driver.sibling_tmpfs.stage(None, None, self.folder, "tmpfs")
            provider = driver.terminal.Run.keywords["worker_drive"]
            self.assertIs(type(provider), driver.local_worker_drive.WorkerDrive)
            self.assertIs(provider.apfs, driver.worker_apfs_drive)
        self.add_read_only_history()
        plan = report.read(self.folder, "plan.json") | staged
        self.save("plan.json", plan)
        source = self.folder / report.PROVIDER_SOURCE
        self.assertEqual(source.read_bytes(), Path(driver.local_worker_drive.__file__).read_bytes())
        self.assertEqual(report.terminal.digest(source), plan[report.PROVIDER_FIELD])
        self.assertEqual(report.verify_volume(self.folder)["journal_observed_through"], "read_only_remount")
        self.save("plan.json", {key: value for key, value in plan.items() if key != report.PROVIDER_FIELD})
        with self.assertRaisesRegex(ValueError, "provider evidence does not match"):
            report.verify_volume(self.folder)
        self.save("plan.json", {**plan, report.FINAL_HISTORY: False})
        with self.assertRaisesRegex(ValueError, "requires read-only history"):
            report.verify_volume(self.folder)
        self.save("plan.json", plan)
        source.write_text("# replaced provider\n")
        with self.assertRaisesRegex(ValueError, "shared APFS worker provider differs"):
            report.verify_volume(self.folder)

    def test_legacy_adapter_accepts_no_unrelated_provider(self):
        self.assertEqual(report.verify_volume(self.folder)["journal_observed_through"], "pre_detach")
        source = self.folder / report.PROVIDER_SOURCE
        source.write_text("# unrelated provider\n")
        with self.assertRaisesRegex(ValueError, "provider evidence does not match"):
            report.verify_volume(self.folder)


if __name__ == "__main__":
    unittest.main()
