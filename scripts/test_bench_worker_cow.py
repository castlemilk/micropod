import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import bench_worker_cow as cow


class WorkerCOWTests(unittest.TestCase):
    def test_schedules_balance_first_and_last_positions_and_bound_work(self):
        for rounds in (4, 8):
            orders = cow.schedule(rounds, 23802)
            for i in range(0, rounds, 4):
                for column in zip(*orders[i:i + 4]):
                    self.assertCountEqual(column, cow.CASES)
        for invalid in (0, 1, 5, 128):
            with self.assertRaises(ValueError):
                cow.schedule(invalid, 23802)

    def test_replays_every_acknowledged_edit_and_paired_inputs_from_receipt(self):
        receipt = Path(__file__).resolve().parents[1] / "docs/benchmarks/2026-11-23/apfs-cow-local.json"
        data = json.loads(receipt.read_text())
        self.assertRegex(data["program_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(data["median_over_rounds"], cow.summarize(data["rows"]))
        self.assertEqual([row["case"] for row in data["rows"]], sum(data["orders"], []))
        base = hashlib.shake_256(b"micropod-dense-apfs-v1").digest(data["file_bytes"])
        self.assertEqual(data["source_sha256"], hashlib.sha256(base).hexdigest())
        paired = {}
        for row in data["rows"]:
            number, case = row["round"], row["case"]
            kind, layout = case.split("-")
            step = data["edit_bytes"] * (1 if layout == "adjacent" else 16)
            offsets = [data["edit_bytes"] * (number - 1) * 4 + i * step for i in range(8)]
            self.assertEqual(row["offsets"], offsets)
            payload = bytearray(base)
            for i, phase in enumerate(row["passes"], 1):
                self.assertEqual(phase["pass"], i)
                for j, offset in enumerate(offsets):
                    count = data["edit_bytes"]
                    payload[offset:offset + count] = hashlib.shake_256(f"{number}/{i}/{j}".encode()).digest(count)
                self.assertEqual(phase["target_sha256"], hashlib.sha256(payload).hexdigest())
                for key in ("pwrite_ns", "fsync_ns", "private_bytes_after_each_fsync"):
                    self.assertEqual(len(phase[key]), 8)
                    self.assertTrue(all(type(n) is int and n >= 0 for n in phase[key]))
                paired.setdefault((number, layout, i), {})[kind] = phase["target_sha256"]
        for values in paired.values():
            self.assertEqual(values["clone"], values["private"])

    def test_misidentified_independent_file_is_rejected_and_only_trial_removed(self):
        class IncorrectAllocation:
            def read(self, path):
                return (cow.FILE_BYTES, 123)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "base").write_bytes(b"base")
            with self.assertRaisesRegex(ValueError, "clone-family or inode"):
                cow.run_case(root, b"base", "private-adjacent", 1, None, IncorrectAllocation())
            self.assertEqual([p.name for p in root.iterdir()], ["base"])
            self.assertEqual((root / "base").read_bytes(), b"base")
