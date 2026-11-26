"""Test the snapshot harness without starting a VM or attaching an APFS image."""

from pathlib import Path
import socket
import signal
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import Thread
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import bench_snapshot_fork as bench


class SnapshotForkTest(unittest.TestCase):
    def test_ping_requires_a_parsed_200_and_exact_body(self):
        replies = [
            (b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK", True),
            (b"HTTP/1.0 503 Busy\r\nX-Example: 200 OK\r\nContent-Length: 2\r\n\r\nOK", False),
            (b"HTTP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nOKAY", False),
        ]
        for response, expected in replies:
            with self.subTest(response=response), TemporaryDirectory(dir="/private/tmp") as directory, \
                    socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                path = Path(directory) / "docker.sock"
                server.bind(str(path))
                server.listen()
                server.settimeout(2)

                def send():
                    peer, _ = server.accept()
                    with peer:
                        peer.recv(4096)
                        peer.sendall(response[:13])
                        peer.sendall(response[13:])

                worker = Thread(target=send)
                worker.start()
                try:
                    self.assertEqual(bench.ping(path, 2), expected)
                finally:
                    worker.join(3)
                self.assertFalse(worker.is_alive())

    def test_registered_processes_are_reaped_after_a_partial_parallel_failure(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            run = bench.SnapshotRun(SimpleNamespace(parallel_forks=2), {})
            run.processes = bench.OwnedProcesses(root)
            run.parallel = [SimpleNamespace(name=name) for name in ("200", "201")]

            def launch(instance):
                process = run.processes.launch(instance.name, [sys.executable, "-c", "import time; time.sleep(15)"])
                if instance.name == "200":
                    raise RuntimeError("docker startup failed after launch")
                return process, {"fork": int(instance.name)}

            try:
                with patch.object(run, "fork_timer", side_effect=launch), patch.object(run, "assess_fork"), \
                        self.assertRaisesRegex(RuntimeError, "1 parallel fork"):
                    run.parallel_forks()
            finally:
                run.finish()
            self.assertEqual(run.report["parallel_fanout"]["samples"], [{"fork": 201}])
            self.assertEqual(run.report["parallel_fanout"]["failure"],
                             [{"fork": "200", "error": "docker startup failed after launch"}])
            self.assertEqual({result["name"] for result in run.report["teardown"]["processes"]}, {"200", "201"})
            self.assertFalse(run.report["teardown"]["errors"])
            self.assertTrue(all(record.proc.poll() is not None for record in run.processes.items.values()))

    def test_failed_shutdown_signals_fail_the_receipt_and_allow_proven_disk_release(self):
        for code, escalate in ((0, False), (-signal.SIGSEGV, False), (-signal.SIGKILL, True), (0, True), (7, False)):
            with self.subTest(code=code, escalate=escalate), TemporaryDirectory() as directory:
                root = Path(directory)
                run = bench.SnapshotRun(None, {})
                run.drive = SimpleNamespace(directory=root, close=Mock())
                run.processes = bench.OwnedProcesses(root)
                proc = Mock(pid=23, returncode=None)
                proc.poll.return_value = None
                log = root / "201.log"
                log.write_text("process output")
                run.processes.items["201"] = bench.Process("201", proc, log, 0.0)
                sent = []

                def killpg(_pid, sig):
                    if sig == 0:
                        raise ProcessLookupError()
                    sent.append(sig)

                def wait(timeout):
                    if timeout == 10 and escalate:
                        raise subprocess.TimeoutExpired("vmm", timeout)
                    proc.returncode = code

                proc.wait.side_effect = wait
                with patch.object(bench.os, "getpgid", return_value=proc.pid), patch.object(bench.os, "killpg", killpg):
                    run.finish()
                run.drive.close.assert_called_once_with()
                teardown = run.report["teardown"]
                self.assertFalse(teardown["errors"])
                self.assertEqual(sent, [signal.SIGTERM, signal.SIGKILL] if escalate else [signal.SIGTERM])
                self.assertEqual(bool(teardown["unexpected_process_exits"]), code != 0 or escalate)
                self.assertEqual("failure" in run.report, code != 0 or escalate)
                self.assertEqual(teardown["processes"][0]["exit_signal"], signal.Signals(-code).name if code < 0 else None)

    def test_proof_writes_every_private_volume_before_reading_any_back(self):
        for shared in (False, True):
            with self.subTest(shared=shared), TemporaryDirectory() as directory:
                root = Path(directory)
                run = bench.SnapshotRun(None, {})
                run.base_marker = "original"

                def instance(name):
                    share = root / name
                    share.mkdir()
                    marker = f"host-{name}"
                    (share / bench.SHARE_FILE).write_text(marker + "\n")
                    return bench.Instance(name, root / f"{name}-state", root / f"{name}.ext4", share, marker)

                run.source = instance("source")
                run.parallel = [instance("200"), instance("201")]
                volumes = {node.name: run.base_marker for node in run.parallel}
                commands = []

                def guest(node, *args, mounts):
                    self.assertIn(f"type=volume,src={run.volume},dst=/state", mounts)
                    self.assertIn(f"type=bind,src={run.source.share},dst=/workspace", mounts)
                    self.assertTrue(bench.VOLUME_PATH in args or bench.VOLUME_PATH in args[2])
                    key = "200" if shared else node.name
                    if args[0] == "sh":
                        marker = args[-1]
                        commands.append(("write", node.name))
                        volumes[key] = marker
                        (node.share / bench.GUEST_FILE).write_text(marker + "\n")
                        return ""
                    commands.append(("read", node.name))
                    result = volumes[key] + "\n" + node.host_marker + "\n"
                    if len(args) == 4:
                        result += (node.share / bench.GUEST_FILE).read_text()
                    return result

                with patch.object(run, "probe", side_effect=guest):
                    if shared:
                        with self.assertRaisesRegex(RuntimeError, "write isolation mismatch"):
                            run.verify_isolation()
                    else:
                        run.verify_isolation()
                        self.assertEqual(len(run.report["isolation"]["forks"]), 2)
                self.assertEqual(commands[:5], [
                    ("read", "200"), ("read", "201"), ("write", "200"), ("write", "201"), ("read", "200"),
                ])

    def test_disk_snapshot_and_socket_paths_are_outside_all_guest_exports(self):
        with TemporaryDirectory(dir="/private/tmp") as directory:
            root = Path(directory)
            image = root / "images.tar"
            image.write_bytes(b"fake local image archive")

            class FakeDrive:
                def __init__(self, scope):
                    self.directory = scope
                    self.home = scope / "home"
                    self.home.mkdir()
                    self.disk = self.home / "worker.ext4"
                    self.receipts = {}

                def attach(self):
                    self.receipts["created"] = {"volume": {"dev": self.home.stat().st_dev}}

                def verify_live(self, _minimum):
                    self.receipts["raw_disk"] = {"inode": self.disk.stat().st_ino}

            def seed(_source, target, _dev):
                target.write_bytes(b"seed")
                return {"bytes": 4}

            args = SimpleNamespace(image_tar=image, seed_disk=Path("unused"), serial_rounds=1, parallel_forks=2)
            run = bench.SnapshotRun(args, {"artifacts": {}})
            with patch.object(bench.bet, "BenchmarkWorkerDrive", FakeDrive), patch.object(bench.bet, "copy_hvf_seed", seed), \
                    patch.object(bench.tempfile, "mkdtemp", return_value=directory):
                run.prepare()
            instances = [run.source, *run.serial, *run.parallel, run.delayed]
            exports = {instance.share for instance in instances}
            self.assertEqual(len(exports), len(instances))
            private = [run.snapshot, run.trigger, *(instance.disk for instance in instances),
                       *(instance.sock for instance in instances)]
            for path in private:
                self.assertTrue(path.is_relative_to(run.drive.home))
                self.assertFalse(any(path.is_relative_to(export) for export in exports))

    def test_clock_receipt_handles_guest_second_resolution_and_stale_snapshot(self):
        actual = bench.clock_evidence(10_900_000_000, 11_300_000_000, 10, 5_000_000_000, 3)
        self.assertTrue(actual["within_1_5_s"])
        self.assertEqual(actual["outside_host_interval_s"], 0)
        stale = bench.clock_evidence(10_900_000_000, 11_300_000_000, 5, 5_000_000_000, 3)
        self.assertFalse(stale["within_1_5_s"])
        self.assertAlmostEqual(stale["outside_host_interval_s"], 4.9)

    def test_cli_preserves_existing_receipts_and_saves_failure_after_cleanup(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            existing = root / "baseline.json"
            existing.write_text("baseline")
            argv = ["bench", "--image-tar", str(root / "fixture"), "--out"]
            with patch.object(sys, "argv", [*argv, str(existing)]), patch.object(bench, "measure") as measure:
                with self.assertRaises(FileExistsError):
                    bench.main()
                measure.assert_not_called()
            self.assertEqual(existing.read_text(), "baseline")

            output = root / "new.json"
            failed = {"complete": False, "failure": {"detail": "startup failed"}, "teardown": {"processes": []}}
            with patch.object(sys, "argv", [*argv, str(output)]), patch.object(bench, "measure", return_value=failed):
                self.assertEqual(bench.main(), 1)
            self.assertIn('"failure"', output.read_text())
            self.assertIn('"teardown"', output.read_text())


if __name__ == "__main__":
    unittest.main()
