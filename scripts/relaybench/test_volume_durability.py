import errno
import hashlib
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

import volume_durability as bench


class VolumeDurabilityTests(unittest.TestCase):
    def test_replacement_receipts_cover_sync_and_readback(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            sentinel = root / "published"
            sentinel.write_bytes(b"existing user data")
            receipt = bench.measure(root, 3)
            self.assertEqual(list(root.iterdir()), [sentinel])
            self.assertEqual(sentinel.read_bytes(), b"existing user data")
            self.assertEqual(receipt["volume_device"], root.stat().st_dev)
        self.assertTrue(receipt["same_boot_readback_verified"])
        self.assertFalse(receipt["crash_survival_tested"])
        self.assertEqual(receipt["logical_bytes_written_in_samples"], 3 * 256 * 1024)
        self.assertEqual([s["round"] for s in receipt["samples"]], [1, 2, 3])
        for index, sample in enumerate(receipt["samples"]):
            seed = f"micropod-volume-v1-{index}".encode()
            expected = hashlib.sha256(hashlib.shake_256(seed).digest(256 * 1024)).hexdigest()
            self.assertEqual(sample["sha256"], expected)
            phases = [sample[key] for key in ("write_ns", "file_fsync_ns", "close_and_replace_ns", "directory_fsync_ns")]
            self.assertTrue(all(ns >= 0 for ns in phases))
            self.assertEqual(sum(phases), sample["acknowledged_ns"])

    def test_a_stale_replacement_is_rejected_and_cleaned_up(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(bench.os, "replace"):
            with self.assertRaisesRegex(ValueError, "digest mismatch at replacement 1"):
                bench.measure(temp, 2)
            self.assertEqual(list(Path(temp).iterdir()), [])

    def test_failed_directory_sync_cannot_count_as_acknowledged(self):
        real_fsync = os.fsync
        directory_syncs = 0

        def sync(fd):
            nonlocal directory_syncs
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                directory_syncs += 1
                if directory_syncs == 2:
                    raise OSError(errno.EIO, "directory sync failed")
            real_fsync(fd)

        with tempfile.TemporaryDirectory() as temp, patch.object(bench.os, "fsync", side_effect=sync):
            with self.assertRaisesRegex(OSError, "directory sync failed"):
                bench.measure(temp, 2)
            self.assertEqual(list(Path(temp).iterdir()), [])

    def test_work_is_bounded_before_creation(self):
        with patch.object(bench.tempfile, "TemporaryDirectory") as create:
            for rounds in (0, -1, 65, 2.5, True):
                with self.subTest(rounds=rounds), self.assertRaises(ValueError):
                    bench.measure(rounds=rounds)
            create.assert_not_called()


if __name__ == "__main__":
    unittest.main()
