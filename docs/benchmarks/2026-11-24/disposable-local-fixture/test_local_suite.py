"""Exercise suite sequencing, evidence, and mutual exclusion without starting a VM."""
import io
import hashlib
import json
import shutil
import sys
from types import SimpleNamespace
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import local_terminal as terminal


class LocalSuiteTests(unittest.TestCase):
    def setUp(self):
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.folder = Path(tmp.name)
        self.opts = terminal.parse_options(["--mode", "suite", "--run"])
        self.calls = []
        self.failed = None
        self.p95 = 75000
        self.retained = False
        self.qualified = True
        self.claimed_reno = None
        self.reported_wait = None
        self.idle_failure = None
        self.started = 0

    def run_mode(self, child, folder, **_kwargs):
        key = (child.mode, child.check_inputs)
        self.calls.append(key)
        self.assertEqual(child.run, not child.check_inputs and self.opts.run)
        if key == self.failed:
            terminal.save(folder / "status.json", {"error": "injected first-attempt failure"})
            return 1
        if child.check_inputs:
            return 0
        (folder / "receiver").mkdir()
        terminal.save(folder / "cleanup.json", {"retained": self.retained, "errors": []})
        if child.mode == self.idle_failure:
            terminal.save(folder / "status.json", {"receiver_exit": 1, "guards_clear": True, "error": "idle admission timeout"})
            terminal.save(folder / "receiver/status.json", {"error_kind": "host_idle_timeout", "started": self.started,
                          "scored": 0, "ambient_diagnostic": False, "completed_schedule": False})
            return 1
        expected_wait = 0 if child.mode == "diagnostic" else self.opts.idle_wait_seconds
        self.assertEqual(child.idle_wait_seconds, expected_wait)
        socket_evidence = {"socket_evidence": child.socket_evidence,
                           "idle_wait_seconds": child.idle_wait_seconds if self.reported_wait is None else self.reported_wait,
                           "accepted_socket_reno_verified": child.socket_evidence == "controller"
                           if self.claimed_reno is None else self.claimed_reno}
        terminal.save(folder / "receiver/status.json", {**socket_evidence, "error": None, "scored_clean": 1,
                      "started": 2, "scored": 1, "ambient_diagnostic": child.mode == "diagnostic",
                      "local_vm_idle_and_delivery_qualified": child.mode != "diagnostic" and self.qualified})
        terminal.save(folder / "receiver/summary.json", {**socket_evidence, "schedule_complete": True,
                      "screen": {"verdict": "reject", "reasons": ["candidate was slower"]}})
        terminal.save(folder / "receiver/scored-1-A.json", {"clean": True, "idle_gate_passed": True,
                      "fresh_failed": 0, "reopened": 0, "fresh_p95_us": self.p95,
                      "fresh_p99_us": 90000, "mib_s": 1999.75})
        return 0

    def exercise(self, expected_code):
        with patch.object(terminal, "run_mode", side_effect=self.run_mode), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(terminal.run_suite(self.opts, self.folder), expected_code)
        return json.loads((self.folder / "status.json").read_bytes())

    def test_all_checks_precede_first_vm_and_negative_result_is_retained(self):
        record = self.exercise(0)
        self.assertEqual(self.calls, [(stage, check) for check in (True, False) for stage in terminal.SUITE_MODES])
        self.assertTrue(record["complete"])
        self.assertEqual(record["idle_wait_seconds"], 60)
        for phase in record["stages"].values():
            self.assertEqual(phase["idle_wait_seconds"], 60)
            self.assertEqual(phase["result"]["idle_wait_seconds"], 60)
        self.assertEqual(record["stages"]["baseline"]["result"]["fresh_p95_us"], 75000)
        self.assertEqual(record["stages"]["host-role"]["result"]["screen"], "reject")
        self.assertEqual(record["stages"]["workers"]["state"], "complete")

    def test_route_suite_labels_baseline_and_both_comparisons(self):
        self.opts.socket_evidence = "route"
        record = self.exercise(0)
        self.assertEqual(record["socket_evidence"], "route")
        for mode in terminal.SUITE_MODES:
            result = record["stages"][mode]["result"]
            self.assertEqual(result["socket_evidence"], "route")
            self.assertIs(result["accepted_socket_reno_verified"], False)
            if mode != "baseline":
                self.assertIn("independent controller confirmation", result["screen"].lower())

    def test_route_suite_rejects_contradictory_receiver_confirmation(self):
        self.opts.socket_evidence = "route"
        self.claimed_reno = True
        record = self.exercise(1)
        self.assertIn("evidence differs", record["error"])
        self.assertNotIn(("host-role", False), self.calls)

    def test_cli_idle_defaults_limits_and_busy_scope(self):
        for mode in ("baseline", "diagnostic", "workers", "host-role"):
            self.assertEqual(terminal.parse_options(["--mode", mode, "--run"]).idle_wait_seconds, 0)
        self.assertEqual(terminal.parse_options(["--mode", "suite", "--run", "--idle-wait-seconds", "0"]).idle_wait_seconds, 0)
        for argv in (["--run", "--idle-wait-seconds", "61"], ["--run", "--idle-wait-seconds", "-1"],
                     ["--run", "--idle-wait-seconds", "1.5"], ["--run", "--busy-diagnostic"],
                     ["--mode", "suite", "--run", "--ambient-diagnostic"],
                     ["--mode", "host-role", "--run", "--ambient-diagnostic", "--idle-wait-seconds", "60"],
                     ["--mode", "suite", "--preflight", "--busy-diagnostic"],
                     ["--mode", "suite", "--check-inputs", "--busy-diagnostic"]):
            with self.subTest(argv=argv), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                terminal.parse_options(argv)

    def test_each_receiver_gets_wait_argument_and_time_for_every_window(self):
        for mode, windows in (("baseline", 2), ("workers", 14), ("host-role", 22), ("diagnostic", 2)):
            for wait in (0, 17, 60):
                with self.subTest(mode=mode, wait=wait):
                    args, seconds = terminal.receiver_schedule(mode, wait)
                    self.assertEqual(args[args.index("--idle-wait-seconds") + 1], str(wait))
                    self.assertEqual(seconds, 1200 + windows * wait)
                    if mode in ("workers", "host-role"):
                        self.assertEqual(args[args.index("--pairs") + 1], "4" if mode == "workers" else "8")

    def test_receiver_must_attest_the_same_idle_window(self):
        self.reported_wait = 0
        self.assertIn("idle wait differs", self.exercise(1)["error"])
        self.assertNotIn(("host-role", False), self.calls)

    def test_ambient_attempt_cannot_supply_a_controlled_verdict(self):
        self.exercise(0)
        for mode in ("host-role", "workers"):
            stage = self.folder / mode
            path = stage / "receiver/status.json"
            status = json.loads(path.read_bytes())
            status["ambient_diagnostic"] = True
            terminal.save(path, status)
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, "used ambient load"):
                terminal.suite_result(mode, stage, self.opts.socket_evidence, self.opts.idle_wait_seconds)

    def test_only_idle_progress_is_mirrored_and_all_stdout_is_saved(self):
        runner = SimpleNamespace(folder=self.folder, admission=None, guard=lambda: None)
        output = io.StringIO()
        with redirect_stdout(output):
            terminal.Run.waited(runner, [sys.executable, "-c", "print('internal'); print('[idle] ready')"], "receiver", 5)
        self.assertEqual(output.getvalue(), "[idle] ready\n")
        self.assertEqual((self.folder / "receiver.stdout").read_bytes(), b"internal\n[idle] ready\n")

    def test_busy_diagnostic_preserves_unstarted_baseline_and_reports_ambient_separately(self):
        self.opts.busy_diagnostic = True
        self.opts.socket_evidence = "route"
        self.idle_failure = "baseline"
        self.p95 = 82000  # An ambient diagnostic can report a clean but slow row.
        record = self.exercise(1)
        self.assertFalse(record["complete"])
        self.assertEqual(record["stages"]["baseline"]["state"], "failed")
        self.assertEqual(record["stages"]["host-role"]["state"], "inputs verified")
        self.assertIn("idle admission timeout", record["error"])
        ambient = record["ambient_diagnostic"]
        self.assertEqual(ambient["state"], "complete")
        self.assertEqual(ambient["result"], {"socket_evidence": "route", "accepted_socket_reno_verified": False,
                         "idle_wait_seconds": 0, "evidence": "ambient delivery only", "mib_s": 1999.75,
                         "fresh_p95_us": 82000, "fresh_p99_us": 90000})
        self.assertEqual([mode for mode, check in self.calls if not check], ["baseline", "diagnostic"])

    def test_failed_ambient_diagnostic_preserves_both_failures(self):
        self.opts.busy_diagnostic = True
        self.idle_failure = "baseline"
        self.failed = ("diagnostic", False)
        record = self.exercise(1)
        self.assertIn("idle admission timeout", record["error"])
        self.assertIn("injected first-attempt failure", record["ambient_diagnostic"]["error"])
        self.assertEqual([mode for mode, check in self.calls if not check], ["baseline", "diagnostic"])

    def test_partial_cleanup_or_any_started_client_suppresses_fallback(self):
        self.opts.busy_diagnostic = True
        self.idle_failure = "baseline"
        self.retained = True
        self.assertNotIn("ambient_diagnostic", self.exercise(1))
        self.folder = self.folder / "second-suite"
        self.folder.mkdir()
        self.retained, self.started = False, 1
        self.assertNotIn("ambient_diagnostic", self.exercise(1))
        self.assertNotIn(("diagnostic", False), self.calls)

    def test_fallback_requires_explicit_flag_and_typed_uncontended_receiver_exit(self):
        self.idle_failure = "baseline"
        self.assertNotIn("ambient_diagnostic", self.exercise(1))
        baseline = self.folder / "baseline"
        attempt = {"receiver_exit": 1, "guards_clear": True}
        self.assertTrue(terminal.idle_timeout_before_client(baseline, attempt))
        for change in ({"guards_clear": False}, {"receiver_exit": 0}, {"receiver_exit": -2}):
            self.assertFalse(terminal.idle_timeout_before_client(baseline, attempt | change))
        status_file = baseline / "receiver/status.json"
        status = json.loads(status_file.read_bytes())
        terminal.save(status_file, status | {"error_kind": "other"})
        self.assertFalse(terminal.idle_timeout_before_client(baseline, attempt))
        status_file.unlink()
        self.assertFalse(terminal.idle_timeout_before_client(baseline, attempt))

    def test_route_requires_exact_config_and_unique_disabled_marker(self):
        config = self.folder / "config"
        for flags, valid in (("# CONFIG_INET_DIAG is not set", True), ("CONFIG_INET_DIAG=y", False),
                             ("# CONFIG_INET_DIAG is not set\nCONFIG_INET_DIAG=m", False), ("", False)):
            with self.subTest(flags=flags):
                config.write_text(flags + "\n")
                sha = hashlib.sha256(config.read_bytes()).hexdigest()
                with patch.object(terminal, "STOCK_CONFIG_SHA256", sha):
                    if valid:
                        self.assertTrue(terminal.check_socket_evidence(config, "route", check_inputs=False))
                        self.assertTrue(terminal.check_socket_evidence(config, "controller", check_inputs=True))
                        with self.assertRaisesRegex(ValueError, "--socket-evidence route"):
                            terminal.check_socket_evidence(config, "controller", check_inputs=False)
                    else:
                        with self.assertRaisesRegex(ValueError, "pinned stock kernel"):
                            terminal.check_socket_evidence(config, "route", check_inputs=True)
        config.write_text("# CONFIG_INET_DIAG is not set\n")
        with self.assertRaisesRegex(ValueError, "pinned stock kernel"):
            terminal.check_socket_evidence(config, "route", check_inputs=False)

    def test_missing_last_input_starts_zero_vms(self):
        self.failed = ("workers", True)
        record = self.exercise(1)
        self.assertEqual(self.calls, [(stage, True) for stage in terminal.SUITE_MODES])
        self.assertIn("injected first-attempt failure", record["error"])
        self.assertFalse(record["complete"])

    def test_explicit_input_check_never_boots(self):
        self.opts.check_inputs, self.opts.run = True, False
        self.assertTrue(self.exercise(0)["complete"])
        self.assertTrue(all(check for _, check in self.calls))

    def test_resume_validates_after_all_current_checks_and_runs_remaining_studies(self):
        source = self.folder / "earlier-suite"
        self.opts = terminal.parse_options(["--mode", "suite", "--run", "--resume-from", str(source)])
        result = {"mib_s": 6000, "fresh_p95_us": 5600, "fresh_p99_us": 8300,
                  "socket_evidence": "route", "accepted_socket_reno_verified": False, "idle_wait_seconds": 60}
        self.opts.socket_evidence = "route"

        def replay(opts, folder, previous):
            self.assertEqual((opts, folder, previous), (self.opts, self.folder, source))
            self.assertEqual(self.calls, [(stage, True) for stage in terminal.SUITE_MODES])
            return {"result": result, "evidence": str(folder / "preserved/baseline")}

        with (patch.object(terminal, "resume_source", return_value=source),
              patch.object(terminal, "resume_baseline", side_effect=replay)):
            record = self.exercise(0)
        self.assertEqual([mode for mode, check in self.calls if not check], ["host-role", "workers"])
        self.assertEqual(record["stages"]["baseline"]["result"], result)
        self.assertTrue(record["complete"])

    def test_check_inputs_validates_resume_receipt_without_booting(self):
        source = self.folder / "earlier-suite"
        self.opts = terminal.parse_options(["--mode", "suite", "--check-inputs", "--resume-from", str(source)])
        receipt = {"result": {"mib_s": 6000, "fresh_p95_us": 5600}, "evidence": str(source / "baseline")}
        with (patch.object(terminal, "resume_source", return_value=source),
              patch.object(terminal, "resume_baseline", return_value=receipt) as replay):
            self.assertTrue(self.exercise(0)["complete"])
        replay.assert_called_once_with(self.opts, self.folder, source)
        self.assertEqual(self.calls, [(stage, True) for stage in terminal.SUITE_MODES])

    def test_resume_validation_failure_prevents_all_timed_and_diagnostic_stages(self):
        source = self.folder / "earlier-suite"
        self.opts = terminal.parse_options(["--mode", "suite", "--run", "--busy-diagnostic", "--resume-from", str(source)])
        with (patch.object(terminal, "resume_source", return_value=source),
              patch.object(terminal, "resume_baseline", side_effect=ValueError("baseline receipt changed"))):
            record = self.exercise(1)
        self.assertFalse(record["complete"])
        self.assertIn("baseline receipt changed", record["error"])
        self.assertEqual(self.calls, [(stage, True) for stage in terminal.SUITE_MODES])

    def test_cli_rejects_resume_for_preflight_or_a_single_mode(self):
        for mode, action in (("suite", "--preflight"), ("baseline", "--check-inputs"), ("host-role", "--run"),
                             ("workers", "--run"), ("diagnostic", "--run")):
            with self.subTest(mode=mode, action=action), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                terminal.parse_options(["--mode", mode, action, "--resume-from", "prior-suite"])

    def test_previous_continuation_allows_preboot_retry_and_guarded_completed_reuse(self):
        source = self.folder / "20261124T090510Z-local-d0y_1j57"
        self.folder = self.folder / "20261124T091006Z-local-ezan7mkc"
        previous = self.folder.parent / "20261124T090644Z-local-earlier0"
        for path in (self.folder, previous):
            (path / "preserved").mkdir(parents=True)
            terminal.save(path / "preserved/manifest.json", {"source": str(source), "sha256": {"file": "digest"}})
        state = {"resume_from": str(source), "action": "run", "complete": False}
        terminal.save(previous / "status.json", state)
        self.assertIsNone(terminal.completed_continuation(self.opts, self.folder, source))
        host = previous / "host-role"
        (host / "receiver").mkdir(parents=True)
        terminal.save(host / "scope.json", {"scope": "trial"})
        with self.assertRaisesRegex(ValueError, "confirm previous host-role cleanup"):
            terminal.completed_continuation(self.opts, self.folder, source)
        terminal.save(host / "cleanup.json", {"retained": False, "errors": []})
        self.assertIsNone(terminal.completed_continuation(self.opts, self.folder, source))
        terminal.save(host / "receiver/warmup-1-A.json", {"started": True})
        with self.assertRaisesRegex(ValueError, "already timed host-role"):
            terminal.completed_continuation(self.opts, self.folder, source)
        state.update(complete=True, stages={m: {"result": {"screen": "reject"}} for m in ("host-role", "workers")})
        terminal.save(previous / "status.json", state)
        with patch.object(terminal, "suite_result", return_value={"screen": "reject"}) as verify:
            self.assertEqual(terminal.completed_continuation(self.opts, self.folder, source), (previous, state["stages"]))
        self.assertEqual(verify.call_count, 2)

    def test_resume_requires_original_failed_suite_and_explicit_policies_must_match(self):
        source = self.folder.resolve() / "20261124T090510Z-local-d0y_1j57"
        source.mkdir()
        suite = {"mode": "suite", "action": "run", "complete": False, "error": "failed preflight", "end": "now",
                 "plan": list(terminal.SUITE_MODES), "socket_evidence": "route", "idle_wait_seconds": 17}
        args = ["--mode", "suite", "--resume-from", source.name, "--check-inputs"]
        with patch.object(terminal, "HERE", source.parent):
            terminal.save(source / "status.json", suite)
            opts = terminal.parse_options(args)
            self.assertEqual(terminal.resume_source(opts), source)
            self.assertEqual((opts.socket_evidence, opts.idle_wait_seconds), ("route", 17))
            for explicit in (["--socket-evidence", "controller"], ["--idle-wait-seconds", "60"]):
                with self.assertRaisesRegex(ValueError, "conflicts with"):
                    terminal.resume_source(terminal.parse_options(args + explicit))
            for change in ({"complete": True}, {"action": "check-inputs"}, {"resume_from": "another-suite"}):
                terminal.save(source / "status.json", suite | change)
                with self.assertRaisesRegex(ValueError, "original failed timed"):
                    terminal.resume_source(opts)

    def test_resume_replays_actual_baseline_and_rejects_modified_measurement_or_inputs(self):
        recorded = terminal.HERE / "20261124T090510Z-local-d0y_1j57"
        if not recorded.is_dir():
            self.skipTest("recorded local suite is unavailable")
        source = self.folder.resolve() / recorded.name
        shutil.copytree(recorded, source)
        suite = json.loads((source / "status.json").read_bytes())
        for mode, stage in suite["stages"].items():
            stage["inputs"] = str(source / "inputs" / mode)
            if "evidence" in stage:
                stage["evidence"] = str(source / mode)
        terminal.save(source / "status.json", suite)
        expected = suite["stages"]["baseline"]["result"]
        self.opts.socket_evidence = suite["socket_evidence"]
        self.opts.idle_wait_seconds = suite["idle_wait_seconds"]
        scored = source / "baseline/receiver/scored-1-A.json"
        original = scored.read_bytes()
        for test in ("valid", "changed row", "changed current kernel"):
            with self.subTest(test=test):
                fresh = self.folder / test
                shutil.copytree(source / "inputs", fresh / "inputs")
                if test == "changed row":
                    terminal.save(scored, json.loads(original) | {"mib_s": expected["mib_s"] + 1})
                else:
                    scored.write_bytes(original)
                if test == "changed current kernel":
                    path = fresh / "inputs/baseline/status.json"
                    inputs = json.loads(path.read_bytes())
                    inputs["inputs_verified"]["kernel"]["sha256"] = "0" * 64
                    terminal.save(path, inputs)
                if test == "valid":
                    receipt = terminal.resume_baseline(self.opts, fresh, source)
                    self.assertEqual(receipt["result"], expected)
                    self.assertTrue((fresh / "preserved").is_dir())
                    self.assertEqual(scored.read_bytes(), original)
                else:
                    with self.assertRaises(ValueError):
                        terminal.resume_baseline(self.opts, fresh, source)

    def test_baseline_without_qualified_delivery_stops(self):
        self.qualified = False
        record = self.exercise(1)
        self.assertEqual([mode for mode, check in self.calls if not check], ["baseline"])
        self.assertEqual(record["stages"]["baseline"]["state"], "failed")

    def test_slow_baseline_preserves_measurement_and_stops(self):
        self.p95 = 75001
        record = self.exercise(1)
        self.assertEqual([mode for mode, check in self.calls if not check], ["baseline"])
        self.assertIn("75001", record["error"])
        self.assertTrue((self.folder / "baseline/receiver/scored-1-A.json").is_file())

    def test_unconfirmed_cleanup_blocks_next_study(self):
        self.retained = True
        self.assertIn("cleanup incomplete", self.exercise(1)["error"])
        self.assertNotIn(("host-role", False), self.calls)

    def test_failed_pair_is_not_retried(self):
        self.opts.busy_diagnostic = True
        self.failed = ("host-role", False)
        record = self.exercise(1)
        self.assertEqual([mode for mode, check in self.calls if not check], ["baseline", "host-role"])
        self.assertEqual(record["stages"]["baseline"]["state"], "complete")
        self.assertEqual(record["stages"]["workers"]["state"], "inputs verified")

    def test_shared_fixture_lock_rejects_overlap_and_releases(self):
        with patch.object(terminal, "HERE", self.folder):
            with terminal.terminal_lock():
                with self.assertRaisesRegex(RuntimeError, "already active"), terminal.terminal_lock():
                    self.fail("two active fixtures")
            with terminal.terminal_lock():
                pass


if __name__ == "__main__":
    unittest.main()
