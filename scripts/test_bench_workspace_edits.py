"""Exercise edit handshakes and independent scan validation with a fake Docker client."""

import hashlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import bench_workspace_edits as bench


class ProbeChild:
    def __init__(self, code, stdout=b"", stderr=b""):
        self.returncode = code
        self.output = stdout, stderr
        self.stdout = io.BytesIO()
        self.stderr = io.BytesIO()

    def poll(self):
        return self.returncode

    def communicate(self, timeout):
        return self.output


class WorkspaceEditsTest(unittest.TestCase):
    def run_fixture(self, directory, *, edit_fails, cleanup_fails=False, corrupt_scan=False):
        args = SimpleNamespace(rounds=1, host="unix://fixture.sock", probe=directory.parent / "binary")
        args.probe.write_bytes(b"fixture")
        events = []

        def popen(command, **_kwargs):
            name = command[command.index("--name") + 1]
            if command[-2:] != ["scan", "/bench/tree"]:
                events.append("start edit")
                cases = ("size", "held", "replace") if edit_fails else bench.CASES
                for case in cases:
                    target = directory / f"{case}-0"
                    self.assertEqual(target.read_bytes(), b"previous")
                    target.with_suffix(".ready").write_text("1")
                    if not edit_fails or case != "replace":
                        target.with_suffix(".done").write_text("observed")
                if edit_fails:
                    return ProbeChild(1, stderr=b"replace-0: open /bench/replace-0: no such file or directory\n")
                return ProbeChild(0)

            self.assertTrue(name.endswith("-scan"))
            self.assertEqual(events[-1], "clean edit")
            events.append("start scan")
            tree = directory / "tree"
            files = sorted(tree.glob("*/*.go"))
            content = b"".join(path.read_bytes() for path in files)
            paths = b"".join(path.relative_to(tree).as_posix().encode() + b"\0" for path in files)
            digest = hashlib.sha256(content).hexdigest()
            rows = [{"pass": i, "scheduled_pause_ms": pause, "files": len(files), "bytes": len(content),
                     "read_bytes": len(content), "sha256": "different" if corrupt_scan else digest,
                     "path_sha256": hashlib.sha256(paths).hexdigest()}
                    for i, pause in enumerate((0, 0, 50), 1)]
            return ProbeChild(0, stdout=json.dumps(rows).encode())

        def cleanup(_docker, name, settle):
            edit = not name.endswith("-scan")
            events.append("clean edit" if edit else "clean scan")
            self.assertEqual(settle, int(edit_fails if edit else corrupt_scan))
            if cleanup_fails:
                raise RuntimeError("fixture container remained")

        with patch.object(bench.subprocess, "Popen", side_effect=popen) as probe, \
                patch.object(bench, "remove_probe", side_effect=cleanup):
            if cleanup_fails:
                with self.assertRaisesRegex(RuntimeError, "Cleanup failed.*fixture container remained") as failed:
                    bench.run(args, directory)
                self.assertIn("no such file or directory", str(failed.exception.__context__))
                probe.assert_called_once()
                return None
            if corrupt_scan:
                with self.assertRaisesRegex(RuntimeError, "different lexical paths, sizes or source bytes"):
                    bench.run(args, directory)
                self.assertEqual(events, ["start edit", "clean edit", "start scan", "clean scan"])
                return None
            result = bench.run(args, directory)
        self.assertEqual(events, ["start edit", "clean edit", "start scan", "clean scan"])
        return result

    def test_observation_failure_reports_progress_and_preserves_scan(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp) / "workspace"
            directory.mkdir()
            result = self.run_fixture(directory, edit_fails=True)
        self.assertFalse(result["complete"])
        self.assertEqual([len(result["samples"][case]) for case in bench.CASES], [1, 1, 0, 0])
        self.assertEqual(len(result["scans"]), 3)
        failure = result["edit_failure"]
        self.assertEqual((failure["completed_checks"], failure["expected_checks"]), (2, 4))
        self.assertEqual((failure["case"], failure["round"], failure["phase"], failure["marker"]),
                         ("replace", 0, "wait_done", "replace-0.done"))
        self.assertEqual(failure["docker_exit_code"], 1)
        self.assertIn("open /bench/replace-0: no such file or directory", failure["stderr"])
        self.assertTrue(failure["host_edit_returned"])
        self.assertTrue(failure["host_path"]["matches_expected"])

    def test_success_shape_and_failure_gates(self):
        for options in ({"edit_fails": False}, {"edit_fails": True, "cleanup_fails": True},
                        {"edit_fails": True, "corrupt_scan": True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as temp:
                directory = Path(temp) / "workspace"
                directory.mkdir()
                result = self.run_fixture(directory, **options)
                if not options["edit_fails"]:
                    self.assertTrue(result["complete"])
                    self.assertEqual(set(result), {"samples", "median_observed_ms", "scans", "timing_scope", "complete"})


if __name__ == "__main__":
    unittest.main()
