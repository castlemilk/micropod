import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import sibling_compiler_runtime as fixture


def proof(arm, requested, inherited=None):
    inherited = inherited if inherited is not None else fixture.INHERITED_NS[arm]
    task = {"cpus_allowed_list": "1", "policy": 0, "nice": 0, "priority": 0,
            "slice_ns": requested * 1000 or inherited}
    return {"dispatcher": {**task, "tid": 30}, "child": {**task, "tid": 31}, "child_parent_pid": 30,
            "slice": {"requested_us": requested, "inherited_ns": inherited, "dispatcher_pid": 30}}


def cohort(root, mode, arm):
    return SimpleNamespace(compiler_affinity="home", compiler_runtime=mode, arm=arm, builders=8, count=32,
                           build_nice=0, work=root, engine=("private-docker",),
                           jobs=[{}] * 32 + [{"id": f"builder-{i}", "mask": "0-3", "home_cpu": "1"} for i in range(8)])


class CompilerRuntimeFixtureTest(unittest.TestCase):
    def test_only_native_long_requests_a_custom_slice(self):
        for mode, arm, value in (("inherit", "A", 0), ("long", "A", 2100), ("inherit", "B", 0), ("long", "B", 0)):
            wave = fixture.RuntimeBuildWave(cohort(Path("."), mode, arm), "tag", 2, Path("."))
            try:
                result = SimpleNamespace(returncode=0, stdout="original output", stderr="")
                with patch.object(fixture.terminal, "invoke", return_value=result) as invoke:
                    row = wave.run(1)
                    self.assertEqual(row["stdout"], "original output")
                    self.assertEqual(row["exec_argv"], list(invoke.call_args.args)[1:])
                    self.assertEqual(row["exec_argv"],
                                     ["exec", "builder-1", "nice", "-n", 0, "taskset", "-c", "1",
                                      fixture.PROBE, "-policy", "normal", "-build-slice-us", str(value),
                                      "/bin/sh", "/mpcheck/go-dispatch-runtime.sh", "tag", "sibling-2-1", 1, 0])
            finally:
                wave.pool.shutdown()

    def test_generated_probe_contains_only_the_scoped_numeric_delta(self):
        original = Path(fixture.__file__).with_name(fixture.affinity.SOURCE).read_text()
        generated = fixture.launcher_source(original)
        self.assertIn("slice.RequestedUS != 2100", generated)
        self.assertIn("*buildSliceUS != 2100", generated)
        self.assertIn("0 or 2100 microseconds", generated)
        self.assertEqual(generated.replace("2100", "250"), original)
        with self.assertRaises(ValueError):
            fixture.launcher_source(original + "\n")
        self.assertEqual(fixture.DISPATCH.replace(fixture.PROBE, fixture.affinity.PROBE), fixture.affinity.DISPATCH)

    def test_default_slice_is_checked_for_both_roles(self):
        job = {"mask": "0-3", "home_cpu": "1"}
        for mode, arm, requested in (("inherit", "A", 0), ("long", "A", 2100), ("long", "B", 0)):
            row = proof(arm, requested)
            fixture.check_dispatch_runtime(row, job, mode, arm, 0)
            fixture.check_normal_runtime([proof(arm, 0)["dispatcher"]], 30, "1", arm)
            with self.assertRaises(ValueError):
                fixture.check_dispatch_runtime(proof(arm, requested, 100000), job, mode, arm, 0)
        with self.assertRaises(ValueError):
            fixture.check_normal_runtime([proof("A", 2100)["dispatcher"]], 30, "1", "A")

    def test_incorrect_inherited_slice_holds_the_gate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            gate = root / "gate"
            gate.mkdir()
            wave = fixture.RuntimeBuildWave(cohort(root, "long", "A"), "tag", 0, root)
            for index in range(8):
                (gate / f"tag.go.{index}.ready").write_text("ready")
                row = proof("A", 2100, inherited=2100000 if index == 7 else None)
                (gate / f"tag.go.{index}.policy").write_text(json.dumps(row))
            try:
                with patch.object(wave, "run", return_value={}):
                    with self.assertRaises(ValueError):
                        wave.start()
                self.assertFalse((gate / "tag.go").exists())
            finally:
                wave.close()
            self.assertTrue((gate / "tag.go.abort").exists())


if __name__ == "__main__":
    unittest.main()
