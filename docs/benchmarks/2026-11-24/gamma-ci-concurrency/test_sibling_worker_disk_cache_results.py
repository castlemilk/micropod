"""Exercise the disk replay's independent attachment and calibration gates."""

import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

import sibling_worker_disk_cache_results as report


class DiskCacheReplayTest(unittest.TestCase):
    def test_actual_attachment_must_match_mode_sync_vm_and_owned_disk(self):
        with TemporaryDirectory() as directory:
            folder = Path(directory).resolve()
            (folder / "a").mkdir()
            instance = "00000000-0000-0000-0000-000000000001"
            plan = {report.MODE: "uncached", "scope": str(folder / "temporary")}
            (folder / "worker-identity.json").write_text(json.dumps({"instance": instance, "relay_pid": 20}))
            (folder / "launch-role.json").write_text(json.dumps({"pid": 20}))
            attach = {"cache_mode": "uncached", "sync_mode": "fsync", "vm_id": "ci-" + instance,
                      "pid": 20, "storage_device_index": 1, "read_only": False, "image_format": "raw",
                      "device_type": "VZVirtioBlockDeviceConfiguration",
                      "disk_path": str(folder / "temporary/a/worker.ext4")}
            log = folder / "a/service.stderr"

            def record(value):
                log.write_text(report.ATTACHMENT_PREFIX + json.dumps(value) + "\n")

            record(attach)
            self.assertEqual(report.check_attachment(folder, plan), attach)
            for key, replacement in (("cache_mode", "cached"), ("sync_mode", "none"), ("pid", 21),
                                     ("storage_device_index", 0), ("disk_path", "/disks/foreign.ext4")):
                with self.subTest(key=key):
                    record({**attach, key: replacement})
                    with self.assertRaisesRegex(ValueError, "actual native VZ attachment"):
                        report.check_attachment(folder, plan)

    def test_calibration_requires_device_reads_flush_and_warm_distinction(self):
        stages = {phase: {"stat_delta": {"read_sectors": 2048 if phase in ("cold", "direct") else 0,
                                        "write_sectors": 2048 if phase == "write" else 0,
                                        "flushes": int(phase == "write")}}
                  for phase in ("write", "cold", "warm", "direct")}
        calibration = {"bytes": 1 << 20, "stages": stages, "guest_fsync_succeeded": True}
        queue = {"write_cache": "write back", "fua": "0"}
        self.assertEqual(report.check_calibration(calibration, queue)["device_read_bytes"],
                         {"cold": 1 << 20, "warm": 0, "direct": 1 << 20})
        for phase, field, replacement in (("write", "flushes", 0), ("cold", "read_sectors", 2047),
                                          ("warm", "read_sectors", 2048)):
            with self.subTest(phase=phase, field=field):
                counters = stages[phase]["stat_delta"]
                original = counters[field]
                counters[field] = replacement
                with self.assertRaisesRegex(ValueError, "disk calibration did not distinguish"):
                    report.check_calibration(calibration, queue)
                counters[field] = original
        stages["write"]["stat_delta"]["flushes"] = 0
        for cache, fua, witness in (("write through", "0", "write_through_without_separate_flush"),
                                    ("write back", "1", "fua_capable_without_separate_flush")):
            observed = report.check_calibration(calibration, {"write_cache": cache, "fua": fua})
            self.assertEqual(observed["flush_evidence"], witness)

    def test_only_advertised_cache_flags_can_vary_between_devices(self):
        cached = {"features": "0" * 64, "queue": {"write_cache": "write back", "logical_block_size": "512"}}
        uncached = {"features": "0" * 9 + "101" + "0" * 52,
                    "queue": {"write_cache": "write through", "fua": "1", "logical_block_size": "512"}}
        self.assertEqual(report.device_geometry(cached), report.device_geometry(uncached))
        uncached["queue"]["logical_block_size"] = "4096"
        self.assertNotEqual(report.device_geometry(cached), report.device_geometry(uncached))

    def test_mixed_host_volume_strategies_rejected_before_scoring(self):
        with TemporaryDirectory() as directory:
            folders = [Path(directory) / str(index) for index in range(4)]
            dedicated = {"host_worker_volume": "apfs-no-index", "host_worker_volume_gib": 16}
            for folder, plan in zip(folders, ({}, {}, dedicated, dedicated), strict=True):
                folder.mkdir()
                (folder / "plan.json").write_text(json.dumps(plan))
            with self.assertRaisesRegex(ValueError, "mixes ordinary and dedicated worker host volumes"):
                report.compare(folders)


if __name__ == "__main__":
    unittest.main()
