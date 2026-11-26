import gzip
import json
from pathlib import Path
from subprocess import CompletedProcess
import unittest
from unittest.mock import patch

from compare import measure


class RelayWorkloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(__file__).resolve().parents[2]
        with gzip.open(root / "docs/benchmarks/2026-11-22/gamma-relay-workers.json.gz", "rt") as f:
            rows = json.load(f)["independent_client_confirmation"]["rounds"]
        cls.sample = next(r["sample"] for r in rows if r["arm"] == "candidate2" and r["ok"] and r["ports"] == 32)

    def score(self, raw, ports=32):
        result = CompletedProcess([], 0, json.dumps(raw), "")
        with patch("compare.subprocess.run", return_value=result):
            return measure(Path("fixture"), 6, ports, 2, 512, False, False)

    def test_balanced_port_layouts_require_distinct_receipts(self):
        self.assertEqual(self.sample["bulk_flows_per_owner"], [16, 16])
        self.assertGreater(self.score(self.sample)["mib_s"], 0)
        with self.assertRaisesRegex(ValueError, "ports"):
            self.score(self.sample, ports=1)

    def test_fixed_controls_and_minimum_window(self):
        for key, value in (("ports", True), ("ports", None), ("client_buffer_kib", 128),
                           ("profile", 1), ("elapsed_ns", 5_999_999_999)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.score(dict(self.sample, **{key: value}))
