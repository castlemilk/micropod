import json
from pathlib import Path
import sys
import tempfile
import time
import unittest

import gamma_pilot as pilot
import peer_verdict as peer
from test_peer_verdict import CLI_SHA, completed_run, write


class PeerClientWindowTests(unittest.TestCase):
    def test_live_recorder_brackets_the_spawned_process(self):
        receipt, checks = {}, []

        def check_window():
            checks.append(time.time_ns())

        # Use the same launcher and a child that reports its own wall clock.
        result = pilot.run_in_window([sys.executable, "-c", "import time; print(time.time_ns())"],
                                     check_window, receipt)
        self.assertEqual(result.returncode, 0)
        self.assertLessEqual(checks[0], receipt["client_spawn_start_ns"])
        child = int(result.stdout)
        self.assertLessEqual(receipt["client_spawn_start_ns"], child)
        self.assertLessEqual(child, receipt["client_reaped_ns"])

    def test_completed_holdout_rejects_shifted_or_short_client_windows(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            completed_run(root)
            self.assertEqual(peer.directory(root, CLI_SHA)["client_timing"], "legacy")
            plan = json.loads((root / "plan.json").read_bytes())
            write(root, "plan.json", {**plan, "client_timing": "spawn-to-reap"})
            for pattern in ("warmup-*.json", "scored-*.json"):
                for path in root.glob(pattern):
                    row = json.loads(path.read_bytes())
                    row.update(client_spawn_start_ns=row["before"]["epoch_ns"],
                               client_reaped_ns=row["after"]["epoch_ns"])
                    write(root, path.name, row)
            self.assertEqual(peer.directory(root, CLI_SHA)["client_timing"], "spawn-to-reap")
            for name in ("warmup-1-A.json", "scored-16-B.json"):
                row = json.loads((root / name).read_bytes())
                start, end = row["client_spawn_start_ns"], row["client_reaped_ns"]
                for left, right, error in ((start-1, end-1, "bracket"), (start+1, end+1, "bracket"),
                                           (start, start+6_000_000_000-1, "lifetime"),
                                           (None, end, "bracket")):
                    invalid = dict(row, client_spawn_start_ns=left, client_reaped_ns=right)
                    if left is None:
                        del invalid["client_spawn_start_ns"]
                    write(root, name, invalid)
                    with self.subTest(name=name, error=error), self.assertRaisesRegex(ValueError, error):
                        peer.directory(root, CLI_SHA)
                write(root, name, row)


if __name__ == "__main__":
    unittest.main()
