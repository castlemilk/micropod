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


def worker_row(arm, rate=None):
    row = measured(arm)
    if rate is not None:
        row["mib_s"] = rate
    window = 6.25
    total = int(row["mib_s"] * 2**20 * window)
    counts = [total // 32] * 32
    counts[0] -= 2**20
    counts[-1] += 2**20
    raw = dict(published_ports=1, streams=32, arrivals=240, period_us=25000, reopened=0, errors=None,
               bytes=total, window_s=window, mib_s=row["mib_s"], per_stream_bytes=counts,
               fresh_p50_us=row["fresh_p50_us"], fresh_p95_us=row["fresh_p95_us"], fresh_p99_us=row["fresh_p99_us"])
    return dict(row, stdout=json.dumps(raw))


class PilotPairCountTests(unittest.TestCase):
    def test_worker_streams_distinguish_missing_and_invalid_raw_evidence(self):
        row = worker_row("A")
        payload = json.loads(row["stdout"])
        invalid_counts = [1.0, *payload["per_stream_bytes"][1:]]
        for changes in (dict(per_stream_bytes=payload["per_stream_bytes"][:-1]),
                        dict(per_stream_bytes=invalid_counts, bytes=int(sum(invalid_counts))),
                        dict(per_stream_bytes=[True] * 32, bytes=32), dict(bytes=payload["bytes"] + 1),
                        dict(mib_s=payload["mib_s"] * 2), dict(window_s=0), dict(streams=31)):
            with self.subTest(changes=list(changes)):
                bad = dict(row, stdout=json.dumps(dict(payload, **changes)))
                self.assertEqual(pilot.worker_stream_rates(bad)["status"], "invalid")
        for output in ("[]", "{"):
            self.assertEqual(pilot.worker_stream_rates(dict(row, stdout=output))["status"], "invalid")
        self.assertEqual(pilot.worker_stream_rates(dict(row, mib_s=81))["status"], "invalid")
        self.assertEqual(pilot.worker_stream_rates(measured("A"))["status"], "unavailable")
        del payload["window_s"]
        self.assertEqual(pilot.worker_stream_rates(dict(row, stdout=json.dumps(payload)))["status"], "unavailable")
        rows = {(1, "A"): row, (1, "B"): dict(worker_row("B"), clean=False)}
        comparison = pilot.worker_stream_comparison(rows, 1)
        self.assertEqual(comparison["pairs"][0]["four_workers"]["status"], "unclean")
        self.assertIsNone(comparison["pairs"][0]["four_slowest_over_two_fastest"])
        self.assertEqual(comparison["measured_pairs"], 0)

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

    def test_read_size_screen_requires_same_build_and_booted_caps(self):
        now = 1_795_385_000
        seed = 34215
        result = json.loads(cli("--mode", "read-size", "--relay-workers", "4", "--seed", str(seed)).stdout)
        self.assertEqual(result["order"], pilot.plan(seed, 4))
        settings = result["arms"]
        self.assertEqual([key for key in settings["A"] if settings["A"][key] != settings["B"][key]], ["read_bytes"])
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            a, b = root / "a", root / "b"
            a.mkdir()
            b.mkdir()
            fleet, release = make_window(root, now, (a, b))
            args = Namespace(mode="read-size", seed=seed, a=a, b=b, tools=root, check=False,
                             fleet=fleet, release=release, out=root / "no-handoff")
            fixtures = {path: dict(settings[arm], engine=arm, id=arm, name=arm, instance=arm, worker=arm,
                                   address=f"127.0.0.1:{port}", pids={"relay": port}, cpuset="0-3",
                                   route=pilot.DIRECT_ROUTE, service_env_sha256="same", engine_version="same", release="7.3.5",
                                   kernel_image_sha256=pilot.STOCK_KERNEL, cli_sha256="same-build", job_controls_sha256="same")
                        for path, arm, port in ((a, "A", 9041), (b, "B", 9042))}
            def inspect(path, cpus, orb, *, read_kib):
                self.assertEqual((cpus, orb, read_kib), (4, False, 256 if path == a else 512))
                return fixtures[path].copy()
            def attempt(_tools, fixture, _birth, row, check):
                self.assertEqual(check()["mode"], "read-size")
                row.update(worker_row(row["arm"]),
                           client_arguments=["http://" + fixture["address"], fixture["name"]])
            with patch.object(pilot.platform, "node", return_value="Gamma-128GB"), patch.object(pilot.time, "time", return_value=now), \
                    patch.object(pilot, "digest", side_effect=lambda p: dict(pilot.HASHES, fixed=pilot.host_role.CLIENT_SHA256)[p.name]), \
                    patch.object(pilot, "inspect", side_effect=inspect) as probe, patch.object(pilot, "snapshot", return_value={"tasks": []}), \
                    patch.object(pilot, "attempt", side_effect=attempt) as load:
                with self.assertRaisesRegex(ValueError, "owner handoff"):
                    pilot.run(args, result["order"], workers=4)
                probe.assert_not_called()
                gate = json.loads(release.read_text())
                release.write_text(json.dumps(dict(gate, modes=["read-size"])))
                for i, (path, key, wrong, error) in enumerate((
                    (b, "read_bytes", 262144, "verified 512 KiB"),
                    (a, "read_bytes", 524288, "verified 256 KiB"),
                    (b, "read_bytes", None, "verified 512 KiB"),
                    (a, "read_bytes", 262144.0, "verified 256 KiB"),
                    (b, "callback_events", 24, "128-event"),
                    (b, "relay_workers", 2, "needs 4 relay workers"),
                    (b, "job_controls_sha256", "different QoS", "beyond read size"),
                    (b, "cli_sha256", "different-build", "differ in cli_sha256"),
                )):
                    args.out = root / str(i)
                    with self.subTest(key=key, wrong=wrong), patch.dict(fixtures[path], {key: wrong}), self.assertRaisesRegex(ValueError, error):
                        pilot.run(args, result["order"], workers=4)
                    load.assert_not_called()
                args.out = root / "comparison"
                pilot.run(args, result["order"], workers=4)
                self.assertEqual(load.call_count, 14)
                captured = json.loads((args.out / "fixtures.json").read_text())
                self.assertEqual([captured[arm]["read_bytes"] for arm in "AB"], [262144, 524288])
                self.assertEqual(json.loads((args.out / "complete.json").read_text())["screen"]["verdict"],
                                 "eligible for confirmation")

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
                result = pilot.screening_result(rows, ["AB", "BA", "BA", "AB"])
                self.assertEqual(result["verdict"], "reject")
                self.assertIsNone(result["median_paired_throughput_change_pct"])
                self.assertEqual(len(result["pairs"]), 4)
                self.assertTrue(result["pairs"][1]["B"]["problems"])
        rows = {(n, arm): measured(arm) for n in range(1, 5) for arm in "AB"}
        for n in range(1, 5):
            rows[n, "B"]["mib_s"] = 90
        result = pilot.screening_result(rows, ["AB", "BA", "BA", "AB"])
        self.assertEqual(result["verdict"], "reject")
        self.assertAlmostEqual(result["median_paired_throughput_change_pct"], -10)

    def test_two_pair_worker_screen_requires_a_gain_in_each_run_order(self):
        orders = ["BA", "AB"]
        rows = {(n, arm): measured(arm) for n in (1, 2) for arm in "AB"}
        for slower in (99, 100):
            with self.subTest(slower=slower):
                rows[2, "B"]["mib_s"] = slower
                result = pilot.screening_result(rows, orders)
                self.assertGreater(result["median_paired_throughput_change_pct"], 0)
                self.assertEqual(result["verdict"], "reject")
                self.assertIn("pair 2 AB: four workers did not improve throughput", result["reasons"])
        rows[2, "B"] = dict(measured("B"), clean=False, fresh_failed=1)
        result = pilot.screening_result(rows, orders)
        self.assertEqual([p["order"] for p in result["pairs"]], orders)
        self.assertEqual(result["verdict"], "reject")
        self.assertIsNone(result["median_paired_throughput_change_pct"])
        rows[2, "B"] = measured("B")
        self.assertEqual(pilot.screening_result(rows, orders)["verdict"], "eligible for confirmation")

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
            def fixture(path, cpus, orb, *, worker_count=None, vary_vcpus=False):
                self.assertEqual(vary_vcpus, args.mode == "size")
                self.assertEqual(worker_count, (2 if path == a else 4) if args.mode == "workers" else None)
                return dict(engine=path.name, id=path.name, address="127.0.0.1:9041" if path == a else "127.0.0.1:9042", name=path.name,
                            cpuset="0-3", instance=path.name, worker=path.name, kernel_image_sha256=pilot.STOCK_KERNEL,
                            release="same", engine_version="same", cli_sha256="same", service_env_sha256="same",
                            relay_workers=2 if path == a or args.mode == "size" else 4, callback_events=128, read_bytes=262144, route=pilot.DIRECT_ROUTE,
                            job_controls_sha256="same-controls", relay_nice=0, pids={"vmm": 1 if path == a else 2})
            def measure(tools, fixture, birth, row, window):
                self.assertEqual(window()["reservation"], row["admission"]["reservation"])
                row.update(worker_row(row["arm"]), client_arguments=["http://" + fixture["address"], fixture["name"]])

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
                report = json.loads((args.out / "complete.json").read_text())
                streams = report["worker_streams"]
                self.assertEqual((streams["measured_pairs"], streams["pairs_with_all_four_worker_streams_faster"]), (4, 4))
                pair = streams["pairs"][0]
                self.assertAlmostEqual(pair["two_workers"]["fastest_mib_s"], 100 / 32 + 1 / 6.25)
                self.assertAlmostEqual(pair["four_workers"]["slowest_mib_s"], 120 / 32 - 1 / 6.25)
                self.assertAlmostEqual(pair["four_slowest_over_two_fastest"], (120 / 32 - 1 / 6.25) / (100 / 32 + 1 / 6.25))
                complete = report["screen"]
                self.assertEqual(complete["verdict"], "eligible for confirmation")
                self.assertEqual(len(report["worker_process_work"]), 4)
                self.assertEqual(report["worker_process_work"][0],
                                 {"pair": 1, "A": worker_row("A")["host"], "B": worker_row("B")["host"]})
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
                with self.assertRaisesRegex(ValueError, "workers screen rejected: pair 1 B"):
                    pilot.run(args, orders)
                completion = json.loads((args.out / "complete.json").read_text())
                self.assertIsNone(completion["worker_process_work"][0]["B"])
                failed = completion["screen"]
                self.assertEqual(failed["verdict"], "reject")
                self.assertIsNone(failed["median_paired_throughput_change_pct"])
                self.assertEqual(failed["pairs"][0]["B"]["fresh_failed"], 1)

                def mismatched(tools, fixture, birth, row, window):
                    measure(tools, fixture, birth, row, window)
                    if (row["phase"], row["pair"], row["arm"]) != ("scored", 1, "B"):
                        return
                    raw = json.loads(row["stdout"])
                    if case == "multiport":
                        raw["published_ports"] = 32
                    elif case == "bytes":
                        raw["per_stream_bytes"][0] += 0.5
                        raw["per_stream_bytes"][1] -= 0.5
                    else:
                        row["client_arguments"][1] = "other-service"
                    row["stdout"] = json.dumps(raw)
                    row["clean"] = pilot.clean_client(raw)

                attempt.side_effect = mismatched
                for mode in ("workers", "size"):
                    args.mode = mode
                    release.write_text(json.dumps(dict(data, modes=[mode])))
                    for case, error in (("multiport", "one published port"), ("bytes", "integer stream counts"),
                                        ("marker", "client arguments")):
                        args.out = root / (mode + "-" + case)
                        with self.subTest(mode=mode, case=case), self.assertRaisesRegex(ValueError, error):
                            pilot.run(args, orders)
                        rejected = json.loads((args.out / "scored-1-B.json").read_text())
                        self.assertFalse(rejected["clean"])
                        self.assertIn("stdout", rejected)
                        self.assertFalse((args.out / "complete.json").exists())


if __name__ == "__main__":
    unittest.main()
