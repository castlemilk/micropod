"""Check job-local checkout transfer and scoring without starting Docker."""

from pathlib import Path
import shutil
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import bench_workspace_runner as runner


class JobLocalRunnerTest(unittest.TestCase):
    def test_bundle_clone_and_edit_delivery_are_counted_in_alternating_order(self):
        with TemporaryDirectory(prefix="runner job ") as directory:
            root = Path(directory)
            source = root / "original"
            stage = root / "stage"
            (source / "vendor").mkdir(parents=True)
            (source / "vendor/modules.txt").touch()
            (source / "main_linux.go").write_text(runner.MESSAGE)
            stage.mkdir()
            self.measure_local(root, source, stage)

    def measure_local(self, root, source, stage):
        bench = runner.bench
        events, removed = [], []
        original_call = bench.call
        image_id = "sha256:" + "b" * 64
        active = {}
        test = self

        class LocalArm:
            def __init__(self, name, socket, image):
                self.name = self.id = name
                self.docker = bench.docker_cli(socket)
                self.image_id = image_id
                self.container = {"HostConfig": {}, "Mounts": []}
                self.files = root / name
                active[name] = self

            def start(self, stack, name, mounted, args, accepted_ids):
                test.assertIsNone(mounted)
                stack.callback(removed.append, name)

            def guest(self, action, cpus, argument, *, timeout=120):
                test.assertEqual(cpus, 2)
                tree = self.files / "source"
                if action == "prepare-local":
                    test.assertEqual(argument, 1536)
                    bundle = self.files / runner.BUNDLE_NAME
                    bench.git(["clone", "--quiet", "--branch", "main", "--", bundle, tree], self.files, bench.git_env())
                    self.head = bench.git(["rev-parse", "HEAD"], tree, bench.git_env()).decode().strip()
                    return {"bundle_sha256": bench.file_sha(bundle), "bundle_bytes": bundle.stat().st_size,
                            "tree": runner.inventory(tree), "head": self.head, "boot_id": self.name,
                            "driver_sha256": bench.file_sha(self.files / "bench_workspace_checkout.py"),
                            "runner_driver_sha256": bench.file_sha(self.files / "driver.py"),
                            "cache_initial_entries": {}, "limits": {}, "versions": {}, "tools_sha256": {}, "go_env": {}}
                test.assertEqual(action, "build-local")
                expected = runner.MESSAGE + (" " + argument if argument else "")
                actual = (tree / "main_linux.go").read_bytes()
                test.assertEqual(actual.decode(), expected)
                events.append(("build", self.name, argument))
                return {"git_head": self.head, "main_sha256": bench.sha(actual),
                        "binary_sha256": bench.sha(b"binary" + actual), "sum_ns": 3000}

            def check_generation(self):
                pass

        def call(argv, **options):
            if argv[0] != "docker":
                return original_call(argv, **options)
            _, _, _, action, requested, dest = argv
            name, path = dest.split(":", 1)
            arm = active[name]
            self.assertEqual(argv[:3], arm.docker)
            self.assertEqual(action, "cp")
            if path == str(bench.GUEST_ROOT):
                self.assertTrue(requested.endswith("/."))
                shutil.copytree(requested, arm.files)
                events.append(("bundle", name, ""))
            else:
                self.assertEqual(path, str(bench.GUEST_SOURCE / "main_linux.go"))
                shutil.copyfile(requested, arm.files / "source/main_linux.go")
                revision = Path(requested).read_text().removeprefix(runner.MESSAGE).strip()
                events.append(("update", name, revision))

        args = SimpleNamespace(job_local=True, source=source, image="fixture", image_manifest=None,
                               hvf_socket=Path("/unused/hvf"), orbstack_socket=Path("/unused/orb"),
                               cpus=2, memory_mib=1536, pairs=2)
        with patch.object(bench, "Arm", LocalArm), patch.object(bench, "call", side_effect=call):
            receipt = runner.measure(args, stage)
        self.assertEqual([entry for entry in events if entry[0] == "bundle"],
                         [("bundle", "orbstack", ""), ("bundle", "hvf", "")])
        self.assertEqual(events[4:], [
            ("build", "orbstack", ""), ("build", "hvf", ""),
            ("update", "hvf", "0001"), ("build", "hvf", "0001"),
            ("update", "orbstack", "0001"), ("build", "orbstack", "0001"),
            ("update", "hvf", ""), ("build", "hvf", ""),
            ("update", "orbstack", ""), ("build", "orbstack", ""),
            ("update", "orbstack", "0002"), ("build", "orbstack", "0002"),
            ("update", "hvf", "0002"), ("build", "hvf", "0002"),
        ])
        first, reset = [pair["warm"]["hvf"] for pair in receipt["pairs"]]
        self.assertEqual(first["update_transfer_ns"], 0)
        self.assertGreater(reset["update_transfer_ns"], 0)
        self.assertEqual(reset["work_with_transfer_ns"], 3000 + reset["update_transfer_ns"])
        self.assertEqual(set(removed), set(receipt["cleanup"]["removed_containers"].values()))


if __name__ == "__main__":
    unittest.main()
