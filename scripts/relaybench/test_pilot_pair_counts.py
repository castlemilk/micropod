"""Exercise the CLI schedules and mode-specific admission without contacting Gamma."""
import json
import subprocess
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

import gamma_pilot as pilot
from test_host_role import make_window


def cli(*args):
    return subprocess.run([sys.executable, "-B", str(Path(pilot.__file__)), *args],
                          capture_output=True, text=True, timeout=10)


def measured(arm):
    counters = {"cpu_s_per_gib": .5, "runnable_s_per_s": .4, "wait_s_per_s": .1}
    return dict(clean=True, mib_s=120 if arm == "B" else 100, arrivals=240, bulk_streams_with_bytes=32,
                fresh_failed=0, reopened=0, fresh_p50_us=5000, fresh_p95_us=14000, fresh_p99_us=81000,
                host={"vmm": counters.copy(), "relay": counters.copy()})


class PilotPairCountTests(unittest.TestCase):
    def test_four_and_six_pair_screens_change_only_the_intended_control(self):
        for mode, count, workers, lever, expected in (
            ("workers", 4, 2, "relay_workers", (2, 4)),
            ("size", 6, 4, "vcpus", (4, 6)),
        ):
            args = ("--mode", mode, "--relay-workers", str(workers), "--seed", "34202")
            original = json.loads(cli(*args).stdout)
            result = json.loads(cli(*args, "--scored-pairs", str(count)).stdout)
            holdout = json.loads(cli(*args, "--holdout").stdout)
            self.assertEqual(result["arms"], original["arms"])
            a, b = result["arms"]["A"], result["arms"]["B"]
            self.assertEqual([k for k in a if a[k] != b[k]], [lever])
            self.assertEqual((a[lever], b[lever]), expected)
            self.assertEqual(len(original["order"]["scored"]), 2)
            self.assertEqual(len(holdout["order"]["scored"]), 16)
            self.assertEqual(result["order"]["warmup"], original["order"]["warmup"])
            scored = result["order"]["scored"]
            self.assertEqual(scored, holdout["order"]["scored"][:count])
            self.assertEqual(len(scored), count)
            for i in range(0, count, 2):
                self.assertCountEqual(scored[i:i + 2], ["AB", "BA"])

    def test_conflicting_and_invalid_modes_and_counts_are_usage_errors(self):
        for args in (("--mode", "size", "--scored-pairs", "2"),
                     ("--mode", "workers", "--scored-pairs", "5"),
                     ("--mode", "peer", "--scored-pairs", "4"),
                     ("--mode", "host-role", "--scored-pairs", "4"),
                     ("--holdout", "--scored-pairs", "4")):
            with self.subTest(args=args):
                result = cli(*args)
                self.assertEqual(result.returncode, 2)
                self.assertIn("--scored-pairs", result.stderr)
        for action in ("--check", "--run"):
            result = cli("--mode", "workers", "--scored-pairs", "4", action,
                         "--a", "a", "--b", "b", "--out", "unused")
            self.assertEqual(result.returncode, 2)
            self.assertIn("--fleet and --release", result.stderr)

    def test_faster_candidate_cannot_hide_a_failed_or_incomplete_first_attempt(self):
        for change in (dict(clean=False, fresh_failed=1), dict(arrivals=239), dict(reopened=1),
                       dict(bulk_streams_with_bytes=31), dict(fresh_p50_us=None), dict(host={}),
                       dict(fresh_p95_us=75001)):
            with self.subTest(change=change):
                rows = {(n, arm): measured(arm) for n in range(1, 5) for arm in "AB"}
                rows[2, "B"].update(change)
                result = pilot.screening_result(rows, 4)
                self.assertEqual(result["verdict"], "reject")
                self.assertIsNone(result["median_paired_throughput_change_pct"])
                self.assertEqual(len(result["pairs"]), 4)
                self.assertTrue(result["pairs"][1]["B"]["problems"])
        rows = {(n, arm): measured(arm) for n in range(1, 5) for arm in "AB"}
        for n in range(1, 5):
            rows[n, "B"]["mib_s"] = 90
        result = pilot.screening_result(rows, 4)
        self.assertEqual(result["verdict"], "reject")
        self.assertAlmostEqual(result["median_paired_throughput_change_pct"], -10)

    def test_live_screen_uses_its_own_handoff_before_probes_and_while_timing(self):
        now = 1_795_385_000
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            a, b = root / "a", root / "b"
            a.mkdir()
            b.mkdir()
            fleet, release = make_window(root, now, (a, b))
            args = Namespace(mode="workers", seed=34202, scored_pairs=4, tools=root,
                             a=a, b=b, fleet=fleet, release=release, check=False, out=root/"denied")
            def fixture(path, cpus, orb):
                return dict(engine=path.name, id=path.name, address=path.name, name=path.name,
                            cpuset="0-3", instance=path.name, worker=path.name, kernel_image_sha256=pilot.STOCK_KERNEL,
                            release="same", engine_version="same", cli_sha256="same", service_env_sha256="same",
                            relay_workers=2 if path == a else 4, callback_events=128, route=pilot.DIRECT_ROUTE,
                            pids={"vmm": 1 if path == a else 2})
            def measure(tools, fixture, birth, row, window):
                self.assertEqual(window()["reservation"], row["admission"]["reservation"])
                row.update(measured(row["arm"]))

            orders = pilot.plan(args.seed, args.scored_pairs)
            with patch.object(pilot.platform, "node", return_value="Gamma-128GB"), \
                    patch.object(pilot.time, "time", return_value=now), \
                    patch.object(pilot, "digest", side_effect=lambda p: dict(pilot.HASHES, fixed=pilot.host_role.CLIENT_SHA256)[p.name]), \
                    patch.object(pilot, "inspect", side_effect=fixture) as inspect, \
                    patch.object(pilot, "snapshot", return_value={"tasks": []}), \
                    patch.object(pilot, "attempt", side_effect=measure) as attempt:
                with self.assertRaisesRegex(ValueError, "owner handoff"):
                    pilot.run(args, orders)
                inspect.assert_not_called()
                attempt.assert_not_called()

                data = json.loads(release.read_text())
                data["modes"] = ["workers"]
                release.write_text(json.dumps(data))
                args.out = root / "accepted"
                pilot.run(args, orders)
                self.assertEqual(attempt.call_count, (3 + 4) * 2)
                complete = json.loads((args.out / "complete.json").read_text())["screen"]
                self.assertEqual(complete["verdict"], "eligible for confirmation")
                self.assertAlmostEqual(complete["median_paired_throughput_change_pct"], 20)
                last = complete["pairs"][-1]["B"]
                self.assertEqual((last["vmm_cpu_s_per_gib"], last["relay_wait_s_per_s"]), (.5, .1))
                self.assertEqual((last["fresh_p50_us"], last["fresh_p95_us"], last["fresh_p99_us"]),
                                 (5000, 14000, 81000))

                def drop(tools, fixture, birth, row, window):
                    measure(tools, fixture, birth, row, window)
                    if (row["phase"], row["pair"], row["arm"]) == ("scored", 1, "B"):
                        row.update(clean=False, fresh_failed=1)
                attempt.side_effect = drop
                args.out = root / "loss"
                pilot.run(args, orders)
                failed = json.loads((args.out / "complete.json").read_text())["screen"]
                self.assertEqual(failed["verdict"], "reject")
                self.assertIsNone(failed["median_paired_throughput_change_pct"])
                self.assertEqual(failed["pairs"][0]["B"]["fresh_failed"], 1)


if __name__ == "__main__":
    unittest.main()
