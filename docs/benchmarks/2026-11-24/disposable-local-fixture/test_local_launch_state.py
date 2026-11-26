import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import local_terminal

from local_launch_state import launch_fields, worker_exit


def printed(state, runs=1, result="(never exited)", extra=""):
    return (f"gui/501/test.job = {{\n\tstate = {state}\n\truns = {runs}\n"
            f"\tlast exit code = {result}\n{extra}}}\n")


class LaunchStateTests(unittest.TestCase):
    def test_bootstrap_failure_preserves_original_error_and_separate_capability_observation(self):
        job = "gui/501/dev.micropod.benchmark.test"
        error = "Bootstrap failed: 5: Input/output error\nTry re-running the command as root for richer errors."
        for code, output, stderr, restricted in ((1, "", "Operation not permitted", True), (0, "1", "", False)):
            with self.subTest(restricted=restricted), tempfile.TemporaryDirectory() as temp:
                folder = Path(temp)
                results = [subprocess.CompletedProcess([], 5, "", error),
                           subprocess.CompletedProcess([], code, output, stderr)]
                with patch.object(local_terminal, "invoke", side_effect=results), self.assertRaises(RuntimeError) as ex:
                    local_terminal.bootstrap_worker(job, folder/"job.plist", folder)
                receipt = json.loads((folder/"bootstrap.json").read_bytes())
                self.assertEqual(receipt["bootstrap_stderr"], error)
                self.assertEqual(receipt["kern.hv_support"]["exit"], code)
                self.assertEqual("approved host run" in str(ex.exception), restricted)

    def test_pending_and_running_before_readiness(self):
        outputs = [printed("not running", 0), printed("spawn scheduled", 0),
                   printed("spawn scheduled", result="1"), printed("running", extra="\tpid = 423\n")]
        for output in outputs:
            with self.subTest(output=output):
                self.assertIsNone(worker_exit(launch_fields(output)))

    def test_real_exits_before_readiness_include_zero_and_sysexits(self):
        for state, code in (("exited", "1"), ("not running", "0"), ("not running", "78: EX_CONFIG")):
            with self.subTest(state=state, code=code):
                self.assertEqual(worker_exit(launch_fields(printed(state, result=code))),
                                 f"exit code {code} after 1 launchd run(s)")

    def test_terminating_signal_without_exit_code(self):
        for signal in ("Killed: 9", "SIGTERM", "15"):
            with self.subTest(signal=signal):
                output = printed("not running", extra=f"\tlast terminating signal = {signal}\n")
                self.assertEqual(worker_exit(launch_fields(output)), f"signal {signal} after 1 launchd run(s)")

    def test_nested_records_cannot_identify_a_worker_exit_or_hide_one(self):
        nested = ("\tresource coalition = {\n\t\tstate = running\n\t\tpid = 4194\n"
                  "\t\tlast terminating signal = Killed: 9\n\t}\n")
        self.assertIsNone(worker_exit(launch_fields(printed("not running", runs=0, extra=nested))))
        self.assertEqual(worker_exit(launch_fields(printed("not running", result="1", extra=nested))),
                         "exit code 1 after 1 launchd run(s)")

    def test_incomplete_and_contradictory_observations(self):
        for output in ("", printed("not running"), printed("not running", runs="?", result="1"),
                       printed("not running", runs=0, result="1"),
                       printed("not running", result="1", extra="\tpid = 42\n")):
            with self.subTest(output=output):
                self.assertIsNone(worker_exit(launch_fields(output)))


class WorkerReadinessTests(unittest.TestCase):
    job = "gui/501/test.job"

    def setUp(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.home = root / "worker"
        self.home.mkdir()
        self.manifest = root / "evidence"
        self.manifest.mkdir()
        self.clock = self.enterContext(patch.object(local_terminal, "time"))
        self.clock.monotonic.return_value = 20
        self.launchctl = self.enterContext(patch.object(local_terminal, "invoke"))
        self.socket_exists = self.enterContext(patch.object(Path, "is_socket", autospec=True))
        self.socket_exists.return_value = False

    def observe(self, output):
        return subprocess.CompletedProcess(["launchctl", "print", self.job], 0, output, "")

    def history(self):
        path = self.manifest / "launch-state.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()]

    def test_pending_then_running_requires_both_session_and_socket(self):
        nested = "\tenvironment = {\n\t\tTOKEN => confidential-fixture-value\n\t}\n"
        queued = self.observe(printed("not running", 0, extra=nested))
        running = self.observe(printed("running", extra="\tpid = 423\n" + nested))
        self.launchctl.side_effect = [queued, queued, running, running]
        # The socket and started session appear separately before they coexist.
        steps = iter([(False, False), (False, False), (False, True), (True, False), (True, True)])

        def advance():
            started, socket = next(steps)
            self.socket_exists.return_value = socket
            (self.home / "session.json").write_text(json.dumps(dict(started=started)))

        ready = local_terminal.wait_for_worker(self.home, self.manifest, self.job, advance)
        self.assertEqual(ready, {"started": True})
        self.assertEqual(self.launchctl.call_count, 4)
        self.launchctl.assert_called_with("launchctl", "print", self.job, check=False, timeout=8)
        self.socket_exists.assert_called_with(self.home / "docker.sock")
        rows = self.history()
        self.assertEqual([r.get("state", "ready") for r in rows], ["not running", "running", "ready"])
        self.assertIs(rows[-1]["ready"], True)
        self.assertNotIn("confidential-fixture-value", json.dumps(rows))

    def test_genuine_failure_keeps_terminal_state_and_bounded_stderr(self):
        self.launchctl.return_value = self.observe(printed("not running", result="78: EX_CONFIG"))
        (self.manifest / "service.stderr").write_text("first-line" + "x" * 1500 + "\nMissing disk image\n")
        with self.assertRaises(RuntimeError) as caught:
            local_terminal.wait_for_worker(self.home, self.manifest, self.job, Mock())
        self.assertIn("exit code 78: EX_CONFIG", str(caught.exception))
        self.assertIn("Missing disk image", str(caught.exception))
        self.assertNotIn("first-line", str(caught.exception))
        self.assertEqual(self.history()[0]["last exit code"], "78: EX_CONFIG")
        self.clock.sleep.assert_not_called()

    def test_unstarted_worker_reaches_deadline_without_false_exit(self):
        self.launchctl.return_value = self.observe(printed("not running", 0))
        self.clock.monotonic.side_effect = [10, 100, 189.9, 190]
        with self.assertRaisesRegex(RuntimeError, "not ready within 180 seconds"):
            local_terminal.wait_for_worker(self.home, self.manifest, self.job, Mock())
        self.assertEqual(self.launchctl.call_count, 3)
        self.assertEqual(len(self.history()), 1)
        self.assertEqual(self.history()[0]["last exit code"], "(never exited)")


if __name__ == "__main__":
    unittest.main()
