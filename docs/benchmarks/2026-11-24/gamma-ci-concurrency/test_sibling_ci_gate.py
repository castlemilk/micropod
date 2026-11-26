"""Exercise HTTP startup failure reporting before a benchmark gate opens."""

import gzip
import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import Mock, patch

import sibling_ci


class StartupGateTest(unittest.TestCase):
    def test_reports_observed_exec_failure_and_preserves_rows_after_later_timeouts(self):
        rows = [
            {"index": 0, "code": 1, "stderr": "", "receipt": {"window": {"error": "context deadline exceeded"}}},
            {"index": 1, "code": 1, "stderr": "OCI runtime exec failed: read pipe failed\n", "receipt": {"error": ""}},
            {"index": 2, "code": 1, "stderr": "", "receipt": {"window": {"error": "context deadline exceeded"}}},
        ]

        with TemporaryDirectory() as directory:
            folder = Path(directory)
            gate = folder / "gate"
            gate.mkdir()
            tag = "grouped-2-all-A"
            (gate / f"{tag}.0").write_text("100\n")

            def late_client():
                (gate / f"{tag}.2").write_text("200\n")
                return rows[2]

            futures = [Mock(**{"done.return_value": i == 1, "result.return_value": row}) for i, row in enumerate(rows)]
            futures[2].result.side_effect = late_client
            cohort = sibling_ci.Siblings((), "A", "fixture", folder, None, "grouped", 3, None, 1, 0, None, False, "all")
            with (patch.object(sibling_ci, "ThreadPoolExecutor") as pool,
                  patch.object(sibling_ci.sibling_build, "BuildWave") as builds,
                  patch.object(sibling_ci.sibling_paced, "score_wave") as score):
                pool.return_value.__enter__.return_value.submit.side_effect = futures
                with self.assertRaisesRegex(ValueError, "slot 1 before the gate.*read pipe failed"):
                    cohort.run_wave(folder, 2, [0, 1, 2], 200, 1500, 64_000)
                self.assertEqual(pool.return_value.__enter__.return_value.submit.call_count, 3)
                builds.assert_not_called()
                score.assert_not_called()

            detail = json.loads((folder / f"{tag}-startup-failure.json").read_text())
            self.assertEqual(detail["ready_slots"], [0])
            self.assertEqual(detail["missing_slots"], [1, 2])
            self.assertEqual(detail["finished_slots"], [1])
            self.assertEqual(detail["failures"], [{"slot": 1, "code": 1, "error": "OCI runtime exec failed: read pipe failed"}])
            self.assertEqual(detail["primary"], detail["failures"][0])
            self.assertTrue((gate / f"{tag}.2").is_file())
            self.assertFalse((gate / tag).exists())
            with gzip.open(folder / f"{tag}.json.gz", "rt") as raw:
                self.assertEqual(json.load(raw), rows)


if __name__ == "__main__":
    unittest.main()
