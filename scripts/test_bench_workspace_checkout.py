"""Check the checkout fixture and matched receipts without starting Docker."""

from argparse import ArgumentTypeError
from contextlib import ExitStack
import csv
from decimal import Decimal
import json
from pathlib import Path
from types import SimpleNamespace
from tempfile import TemporaryDirectory
from threading import Barrier, Event, Lock
import unittest
from unittest.mock import patch

import bench_workspace_checkout as bench


HVF_BOOT = "11111111-2222-3333-4444-555555555555"
ORB_BOOT = "99999999-8888-7777-6666-555555555555"


class CheckoutBenchmarkTest(unittest.TestCase):
    def test_real_git_fixture_has_deterministic_head_and_only_one_dirty_source(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            stages = [root / name for name in ("copy 1", 'copy "2"')]
            for stage in stages:
                stage.mkdir()
            (source, head), (second, second_head) = (bench.stage_checkout(stage) for stage in stages)
            self.assertEqual(head, second_head)
            self.assertEqual(bench.source_hashes(source), bench.source_hashes(second))
            self.assertEqual(bench.git(["status", "--porcelain=v1"], source, bench.git_env()), b"")
            original = (source / "main.go").read_bytes()
            bench.replace_main(source, bench.edit_main(original, "0001"))
            self.assertEqual(bench.git(["status", "--porcelain=v1"], source, bench.git_env()), b" M main.go\n")
            self.assertEqual(bench.git(["rev-parse", "HEAD"], source, bench.git_env()).decode().strip(), head)
            self.assertNotEqual(bench.edit_main(original, "0001"), bench.edit_main(original, "0002"))
            bench.replace_main(source, original)
            self.assertEqual(bench.git(["status", "--porcelain=v1"], source, bench.git_env()), b"")

    def test_image_binding_accepts_config_and_manifest_only_for_same_oci_object(self):
        config = "sha256:" + "c" * 64
        encoded = json.dumps({"schemaVersion": 2, "config": {"digest": config}, "layers": [{"digest": "d"}]}).encode()
        manifest = "sha256:" + bench.sha(encoded)
        with TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_bytes(encoded)
            self.assertEqual(bench.image_identity(path, [config, manifest]),
                             {"config_digest": config, "manifest_digest": manifest})
            with self.assertRaisesRegex(RuntimeError, "different image IDs"):
                bench.image_identity(None, [config, manifest])
            with self.assertRaisesRegex(RuntimeError, "same per-platform OCI manifest"):
                bench.image_identity(path, [config, "sha256:" + "e" * 64])

    def test_mount_argument_retains_a_quoted_multiword_source_as_one_csv_field(self):
        source = Path('/private/tmp/CI, two "words"')
        self.assertEqual(next(csv.reader([bench.bind_mount(source)])),
                         ["type=bind", f"source={source}", "target=/checkout-ci", "readonly"])

    def test_exact_test_passes_reject_cached_missing_or_duplicate_work(self):
        events = [{"Action": phase, "Test": name} for name in bench.TEST_NAMES for phase in ("run", "pass")]
        events.append({"Action": "pass", "Package": bench.PACKAGE})

        def output(rows):
            return "\n".join(map(json.dumps, rows)).encode()

        self.assertEqual(bench.verify_tests(output(events)), list(bench.TEST_NAMES))
        for rows in (events[1:], [*events, events[0]], [*events, {"Action": "output", "Output": "(cached)"}]):
            with self.assertRaisesRegex(RuntimeError, "unexpected Go test results"):
                bench.verify_tests(output(rows))

    def test_pair_orders_isolate_priming_and_use_one_new_edit_per_pair(self):
        with TemporaryDirectory() as directory:
            stage = Path(directory)
            image_id = "sha256:" + "c" * 64
            commands = []
            checked = []

            class FakeArm:
                def __init__(self, name, socket, image):
                    self.name = name
                    self.engine = {}
                    self.image_id = image_id
                    self.id = ("1" if name == "hvf" else "2") * 64

                def start(self, stack, name, work, args, accepted_ids):
                    self.source = work / "source"
                    self.assert_image_ok = self.image_id in accepted_ids

                def guest(self, command, *args, timeout=120):
                    if command == "prepare":
                        return {"driver_sha256": bench.file_sha(stage / "driver.py"),
                                "boot_id": self.name, "versions": {"go": "go version go1.26.11 linux/arm64"},
                                "tools_sha256": {}, "go_env": {}, "limits": {}}
                    _, revision, phase = args
                    commands.append((self.name, phase, revision))
                    source = bench.source_hashes(self.source)
                    elapsed = 100 if self.name == "hvf" else 200
                    return {
                        "phase_timings": {
                            name: {"start_ns": 1 + i * elapsed, "end_ns": 1 + (i + 1) * elapsed, "elapsed_ns": elapsed}
                            for i, name in enumerate(bench.PHASES)
                        },
                        "scored_ns": elapsed * len(bench.PHASES),
                        "git_head": bench.git(["rev-parse", "HEAD"], self.source, bench.git_env()).decode().strip(),
                        "git_status": bench.git(["status", "--porcelain=v1"], self.source, bench.git_env()).decode(),
                        "source_sha256": source, "artifact_sha256": bench.sha(source["main.go"].encode()),
                        "cli_readback_sha256": source["go.mod"],
                        "cli_usage_sha256": bench.sha(bench.expected_usage(revision)), "tests": list(bench.TEST_NAMES),
                    }

                def check_generation(self):
                    checked.append(self.name)

            args = SimpleNamespace(image="fixture", image_manifest=None, hvf_socket=Path("/unused/hvf"),
                                   orbstack_socket=Path("/unused/orb"), cpus=2, memory_mib=1024,
                                   go_version="1.26.11", pairs=2)
            with patch.object(bench, "Arm", FakeArm):
                report = bench.run(args, stage)
            self.assertEqual(commands, [
                ("orbstack", "prime", ""), ("hvf", "prime", ""),
                ("orbstack", "timed", ""), ("hvf", "timed", ""),
                ("hvf", "timed", "0001"), ("orbstack", "timed", "0001"),
                ("hvf", "timed", ""), ("orbstack", "timed", ""),
                ("orbstack", "timed", "0002"), ("hvf", "timed", "0002"),
            ])
            self.assertEqual(checked, ["orbstack", "hvf"])
            self.assertEqual(report["summary"]["incremental"]["paired_hvf_over_orbstack"], [0.5, 0.5])
            self.assertNotEqual(report["pairs"][0]["incremental"]["hvf"]["artifact_sha256"],
                                report["pairs"][1]["incremental"]["hvf"]["artifact_sha256"])

            stale = report["pairs"][0]["warm"]["hvf"]
            expected = report["pairs"][0]["incremental"]["hvf"]["source_sha256"]
            with self.assertRaisesRegex(RuntimeError, "does not match the host fixture"):
                bench.attest_run(stale, report["fixture_git_commit"], expected, "0001")


class ConcurrentCheckoutTest(unittest.TestCase):
    def test_job_quota_and_guest_barrier_verify_actual_limits(self):
        quota = bench.job_cpu_limit("0.50000")
        self.assertEqual(quota, Decimal("0.5"))
        for invalid in ("0", "NaN", "0.009", "0.250001", "9", "text"):
            with self.subTest(invalid=invalid), self.assertRaises(ArgumentTypeError):
                bench.job_cpu_limit(invalid)

        clock = {"boot_id": HVF_BOOT, "offset_ns": 0, "now_ns": 10}
        limits = {"cpu_quota_us": 50_000, "cpu_period_us": 100_000, "memory_bytes": 384 << 20}
        with patch.object(bench, "guest_clock", return_value=clock), \
                patch.object(bench, "guest_limits", return_value=limits) as check, \
                patch.object(bench.time, "sleep"), patch.object(bench.time, "monotonic_ns", return_value=30), \
                patch.object(bench, "guest_build", return_value={"marker": "did work"}) as build:
            outcome = bench.guest_batch(1, "0002", False, quota, 384, 20, HVF_BOOT, 0)
            self.assertEqual(outcome["barrier"], {"boot_id": HVF_BOOT, "offset_ns": 0,
                                                 "ready_ns": 10, "start_ns": 30, "gate_ns": 20})
            self.assertEqual(outcome["limits"], limits)
            self.assertEqual(outcome["marker"], "did work")
            self.assertEqual([request.args for request in check.call_args_list], [(quota, 384)] * 2)
            build.assert_called_once_with(1, "0002", False, account_cpu=True)
            with self.assertRaisesRegex(RuntimeError, "did not reach .* barrier"):
                bench.guest_batch(1, "", False, quota, 384, 9, HVF_BOOT, 0)
            build.assert_called_once()

    def test_envelope_overlap_alone_does_not_score_a_batch(self):
        def job(start):
            return {"phase_timings": {phase: {"start_ns": t, "end_ns": t + 1}
                                      for phase, t in zip(bench.PHASES, start)}}

        with self.assertRaisesRegex(RuntimeError, "did not overlap all jobs"):
            bench.batch_timing([job([1, 10, 20]), job([3, 12, 22])])

    def test_paired_batches_overlap_use_distinct_workers_and_clean_the_scope(self):
        args = SimpleNamespace(image="fixture", image_manifest=None, hvf_socket=Path("/unused/hvf"),
                               orbstack_socket=Path("/unused/orb"), cpus=2, memory_mib=1024,
                               go_version="1.26.11", pairs=2, jobs=2, job_cpus=Decimal("0.5"), job_memory_mib=384)
        trace, retired = [], []
        scopes, active, gatekeepers = set(), {}, {}
        locked = Lock()
        limits = {"cpu_quota_us": 50_000, "cpu_period_us": 100_000, "memory_bytes": 384 << 20}
        image_id = "sha256:" + "c" * 64

        class FakeArm:
            def __init__(self, name, socket, image):
                self.name = name
                self.image_id = image_id
                self.engine = {}
                self.boot = HVF_BOOT if name == "hvf" else ORB_BOOT

            def start(self, stack, name, stage, policy, accepted_ids):
                self.index = int(name.rsplit("-", 1)[1])
                self.id = f"{self.index + (100 if self.name == 'hvf' else 0):064x}"
                self.source = stage / "source"
                self.asserted_quota = policy.cpus
                self.asserted_memory = policy.memory_mib
                scopes.add(name)
                stack.callback(scopes.remove, name)

            def guest(self, command, parallelism, *rest, timeout=120):
                assert parallelism == 1
                assert (self.asserted_quota, self.asserted_memory) == (Decimal("0.5"), 384)
                if command == "prepare":
                    assert rest == (384, Decimal("0.5"))
                    return {"driver_sha256": bench.file_sha(self.source.parent / "driver.py"),
                            "boot_id": self.boot, "versions": {"go": "go version go1.26.11 linux/arm64"},
                            "go_env": {"GOFLAGS": "-trimpath -p=1"}, "tools_sha256": {}, "limits": limits,
                            "cache_initial_entries": {"build": 0, "module": 0}}
                if command == "clock":
                    assert not active
                    trace.append(self.name)
                    gatekeepers[self.name] = Barrier(args.jobs, timeout=2)
                    return {"boot_id": self.boot, "offset_ns": 0, "now_ns": 100}

                assert command == "batch"
                revision, _, limit, memory, gate, boot, offset = rest
                assert (limit, memory, boot, offset) == (Decimal("0.5"), 384, self.boot, 0)
                with locked:
                    assert set(active.values()) <= {self.name}
                    active[self.id] = self.name
                try:
                    gatekeepers[self.name].wait()
                    source = bench.source_hashes(self.source)
                    start = gate + self.index
                    elapsed = 100 if self.name == "hvf" else 200
                    return {"phase_timings": {phase: {"start_ns": start + i * elapsed,
                                                       "end_ns": start + (i + 1) * elapsed, "elapsed_ns": elapsed}
                                              for i, phase in enumerate(bench.PHASES)},
                            "scored_ns": 3 * elapsed, "git_head": (self.source / ".git/refs/heads/main").read_text().strip(),
                            "git_status": " M main.go\n" if revision else "", "source_sha256": source,
                            "artifact_sha256": bench.sha(source["main.go"].encode()),
                            "cli_readback_sha256": source["go.mod"], "cli_usage_sha256": bench.sha(bench.expected_usage(revision)),
                            "tests": list(bench.TEST_NAMES), "limits": limits,
                            "barrier": {"boot_id": boot, "offset_ns": offset, "ready_ns": gate - 2,
                                        "start_ns": start, "gate_ns": gate}}
                finally:
                    with locked:
                        del active[self.id]

            def check_generation(self):
                retired.append(self.id)

        with TemporaryDirectory() as directory, patch.object(bench, "Arm", FakeArm):
            report = bench.run(args, Path(directory))
        self.assertEqual(trace, ["orbstack", "hvf", "orbstack", "hvf", "hvf", "orbstack",
                                 "hvf", "orbstack", "orbstack", "hvf"])
        self.assertEqual(scopes, set())
        self.assertEqual(len(set(retired)), 4)
        self.assertEqual((report["jobs_per_engine"], report["cpus"], report["memory_mib"], report["go_parallelism"]),
                         (2, "0.5", 384, 1))
        for pair in report["pairs"]:
            for phase in ("warm", "incremental"):
                hvf = pair[phase]["hvf"]
                self.assertEqual(hvf["makespan_ns"], 301)
                self.assertEqual(hvf["peak_scored_parallelism"], 2)
                self.assertGreater(hvf["all_jobs_overlap_ns"], 0)
                self.assertEqual([job["job"] for job in hvf["jobs"]], [1, 2])
        self.assertEqual(report["summary"]["incremental"]["paired_hvf_over_orbstack"], [301 / 601] * 2)

    def test_failed_batch_cleans_owned_guests_before_joining_other_workers(self):
        tasks_started = Barrier(2, timeout=2)
        scope_stopped = Event()
        workers_finished = []

        class Worker:
            def __init__(self, fails):
                self.fails = fails

            def guest(self, command, *rest, timeout=120):
                if command == "clock":
                    return {"now_ns": 10, "boot_id": HVF_BOOT, "offset_ns": 0}
                tasks_started.wait()
                if self.fails:
                    raise RuntimeError("second worker failed")
                if not scope_stopped.wait(timeout=2):
                    raise RuntimeError("other worker was not stopped before thread join")
                workers_finished.append(True)
                raise RuntimeError("stopped by scoped cleanup")

        policy = SimpleNamespace(cpus=Decimal("0.5"), memory_mib=384, go_parallelism=1)
        with ExitStack() as stack:
            stack.callback(scope_stopped.set)
            with self.assertRaisesRegex(RuntimeError, "second worker failed"):
                bench.measure_batch([Worker(False), Worker(True)], [{"boot_id": HVF_BOOT}] * 2, stack, policy, "", {}, "")
        self.assertEqual(workers_finished, [True])

    def test_startup_failure_cleans_both_engine_scopes(self):
        attempted, removed = [], []

        class Worker:
            def __init__(self, name, boot):
                self.name = name
                self.boot = boot
                self.image_id = "sha256:" + "c" * 64
                self.engine = {}

            def start(self, stack, name, stage, args, accepted_ids):
                self.id = f"{len(attempted) + 1:064x}"
                attempted.append(name)
                stack.callback(removed.append, name)
                if self.name == "hvf" and name.endswith("-02"):
                    raise RuntimeError("ambiguous second HVF startup")

            def guest(self, command, *rest):
                if command != "prepare":
                    raise AssertionError("scoring began after partial startup")
                return {"driver_sha256": "fixture", "boot_id": self.boot,
                        "cache_initial_entries": {"build": 0, "module": 0}}

        args = SimpleNamespace(jobs=2, cpus=2, memory_mib=1024, job_cpus=Decimal("0.5"),
                               job_memory_mib=384, go_version=None)
        arms = {name: Worker(name, boot) for name, boot in (("orbstack", ORB_BOOT), ("hvf", HVF_BOOT))}
        evidence = {"driver_sha256": "fixture", "arms": {}}
        with self.assertRaisesRegex(RuntimeError, "ambiguous second HVF startup"):
            bench.run_batches(args, None, None, None, arms, {}, evidence)
        self.assertEqual(len(attempted), 4)
        self.assertEqual(removed, attempted[::-1])


if __name__ == "__main__":
    unittest.main()
