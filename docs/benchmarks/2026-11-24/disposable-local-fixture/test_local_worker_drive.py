"""Exercise the standalone command's native volume wiring without booting a VM."""

from contextlib import ExitStack, redirect_stdout
import io
import json
import os
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import local_qos
import local_terminal as terminal
import local_worker_drive


REAL_ARM = terminal.Run.arm


class LaunchReached(Exception):
    pass


class LocalWorkerDriveTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.files = {name: self.root / name for name in ("kernel_config", "kernel", "cli", "build",
                                                         "netbench_image_tar", "role_probe")}
        self.files["role_probe"].write_bytes(b"test role probe")
        self.mocks = ExitStack()
        self.addCleanup(self.mocks.close)
        for name, ret in (("fixture_files", self.files), ("check_socket_evidence", False),
                          ("verify_service", {}), ("verify_cache", {}), ("check_archives", None),
                          ("receiver_schedule", ([], 10))):
            self.mocks.enter_context(patch.object(terminal, name, return_value=ret))
        self.mocks.enter_context(patch.object(terminal.shutil, "which", return_value="available"))
        self.mocks.enter_context(patch.dict(os.environ, clear=True))
        self.mocks.enter_context(redirect_stdout(io.StringIO()))

    def test_fresh_modes_pass_one_provider_to_each_real_arm(self):
        admitted = Mock()
        with (patch.object(terminal, "Admission", return_value=admitted),
              patch.object(local_qos, "signed_worker"),
              patch.object(local_qos.role, "GUEST_PROBE_SHA256", terminal.digest(self.files["role_probe"]))):
            cases = {"baseline": ("--run", [("a", 2, "Interactive")]),
                     "workers": ("--preflight", [("a", 2, "Interactive"), ("b", 4, "Interactive")]),
                     "host-role": ("--run", [("a", 2, "Standard"), ("b", 2, "Interactive")])}
            for mode, (action, expected) in cases.items():
                with self.subTest(mode=mode):
                    self.check_fresh_mode(mode, action, expected, admitted)

    def test_direct_native_run_requires_the_same_drive_provider(self):
        opts = terminal.parse_options(["--mode", "workers", "--preflight"])
        opts.min_free_gib = 0
        scope = self.root / "private-run"
        scope.mkdir()
        with patch.object(terminal.tempfile, "mkdtemp", return_value=str(scope)):
            run = terminal.Run(opts, self.root)
        try:
            self.assertIsInstance(run.worker_drive, local_worker_drive.WorkerDrive)
            policy = json.loads((self.root / "host-volume-policy.json").read_bytes())
            self.assertEqual(policy, run.volume_policy)
            self.assertEqual(policy["host_worker_volume"], "apfs-no-index")
            self.assertEqual(policy["host_volume_sources"], {name: terminal.digest(self.root / name)
                             for name in ("local_worker_drive.py", "worker_apfs_drive.py")})
        finally:
            run.cleanup()
        self.assertFalse(run.root.exists())

    def check_fresh_mode(self, mode, action, expected, admitted):
        folder = self.root / mode
        folder.mkdir()
        scope = self.root / (mode + "-native")
        scope.mkdir()
        work = scope / "workspace"
        (work / "probe").mkdir(parents=True)
        opts = terminal.parse_options(["--mode", mode, action])
        drive, policy = terminal.prepare_worker_drive(folder)
        self.assertIsInstance(drive, local_worker_drive.WorkerDrive)
        calls = []
        runner = SimpleNamespace(root=scope, folder=folder, arms=[], errors=[], worker_drive=drive, volume_policy=policy,
                                 stop=threading.Event(), waited=Mock(), cleanup=Mock())

        def arm(letter, workers, files, workspace, oci, **kwargs):
            role = kwargs.get("process_type", "Interactive")
            calls.append((letter, workers, role))
            # Stop at the first native CLI operation. Real Run.arm must have
            # reached its mounted-drive provider before rendering launchd.
            with self.assertRaises(LaunchReached):
                REAL_ARM(runner, letter, workers, files, workspace, oci, **kwargs)
            drive.attach.assert_called_with(scope, scope / letter, folder / letter)
            facts = folder / letter / "guest-facts.txt"
            facts.write_text(role + "\n")
            return scope / "data" / letter, facts

        def launch(*argv, env):
            self.assertEqual(argv, (self.files["cli"], "ci", "launch-agent"))
            self.assertEqual(env["MICROPOD_CI_DISK_GIB"], "6")
            self.assertEqual(env["MICROPOD_CI_HOME"], str(scope / calls[-1][0]))
            raise LaunchReached

        runner.arm = arm
        with (patch.object(drive, "attach"),
              patch.object(terminal, "Run", return_value=runner) as make,
              patch.object(terminal, "invoke", side_effect=launch),
              patch.object(terminal, "stage", return_value=(work, scope / "oci", scope / "clients"))):
            self.assertEqual(terminal.run_mode(opts, folder), 0)
            self.assertEqual(drive.attach.call_count, len(expected))
        make.assert_called_once_with(opts, folder, admitted)
        self.assertEqual(calls, expected)
        record = json.loads((folder / "status.json").read_text())
        self.assertEqual(record["host_worker_volume"], "apfs-no-index")
        self.assertEqual(record["host_worker_volume_gib"], 16)
        self.assertTrue(record["host_worker_volume_final_history"])
        self.assertEqual(record["host_volume_sources"], {p: terminal.digest(folder / p) for p in
                         ("local_worker_drive.py", "worker_apfs_drive.py")})

    def test_completed_suite_resume_does_not_prepare_any_drive(self):
        source = self.root / "original-suite"
        source.mkdir()
        sealed = source / "status.json"
        sealed.write_bytes(b"retained original evidence")
        folder = self.root / "suite-resume"
        folder.mkdir()
        opts = terminal.parse_options(["--mode", "suite", "--run", "--resume-from", str(source)])
        previous = self.root / "prior-completion"
        completed = {m: {"result": {"screen": "reject"}} for m in ("host-role", "workers")}
        with (patch.object(terminal, "resume_source", return_value=source),
              patch.object(terminal, "resume_baseline", return_value={"state": "preserved", "result": {"mib_s": 5000}}),
              patch.object(terminal, "completed_continuation", return_value=(previous, completed)),
              patch.object(terminal, "prepare_worker_drive") as provision,
              patch.object(terminal, "Run") as run):
            self.assertEqual(terminal.run_suite(opts, folder), 0)
            provision.assert_not_called()
            run.assert_not_called()
        self.assertEqual(sealed.read_bytes(), b"retained original evidence")
        record = json.loads((folder / "status.json").read_text())
        self.assertEqual(record["completed_by"], str(previous))
        for mode in terminal.SUITE_MODES:
            inputs = json.loads((folder / "inputs" / mode / "status.json").read_text())
            self.assertEqual(inputs["action"], "check-inputs")
            self.assertNotIn("host_worker_volume", inputs)


if __name__ == "__main__":
    unittest.main()
