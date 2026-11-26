import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import sibling_build
import sibling_compiler_affinity as fixture
import sibling_group


def builder_cohort(directory, mode):
    jobs = [{"id": f"builder-{i}", "mask": "0-3", "home_cpu": str(i % 4)} for i in range(8)]
    return SimpleNamespace(compiler_affinity=mode, builders=len(jobs), jobs=[{}] * 32 + jobs,
                           count=32, work=directory, engine=("private-docker",), build_nice=0)


def proof(mask, slot):
    dispatcher = 100 + slot * 2
    task = {"cpus_allowed_list": mask, "policy": 0, "nice": 0, "priority": 0, "slice_ns": 250000}
    return {"dispatcher": {**task, "tid": dispatcher}, "child": {**task, "tid": dispatcher + 1},
            "child_parent_pid": dispatcher}


class CompilerAffinityFixtureTest(unittest.TestCase):
    def test_real_cgroup_and_process_home_are_distinct(self):
        for broad in (False, True):
            jobs = [{"id": f"{pos}", "cpu_group": f"job-{pos % 32:02d}", "mask": str(pos % 4)} for pos in range(64)]
            if broad:
                for job in jobs:
                    job["home_cpu"] = job["mask"]
                for job in jobs[32:40]:
                    job["mask"] = "0-3"
            mapping = sibling_group.assignment(jobs, 32, 8)
            self.assertEqual(mapping["groups"], {f"job-{i:02d}": str(i % 4) for i in range(32)})
            self.assertEqual(jobs[33]["mask"], "0-3" if broad else "1")
            self.assertEqual(sibling_group.process_mask(jobs[33]), "1")

    def test_dispatch_uses_bundled_taskset_and_records_actual_command(self):
        for mode, expected in (("home", "1"), ("pool", "0-3"), (None, None)):
            wave = sibling_build.BuildWave(builder_cohort(Path("."), mode), "g", 2, Path("."))
            try:
                terminal_result = SimpleNamespace(returncode=0, stdout="original workload output", stderr="")
                with patch.object(sibling_build.terminal, "invoke", return_value=terminal_result) as invoke:
                    row = wave.run(1)
                    argv = list(invoke.call_args.args)[1:]
                    self.assertEqual(row["stdout"], "original workload output")
                    if expected is None:
                        self.assertNotIn("exec_argv", row)
                        self.assertEqual(argv[5:7], ["sh", "/mpcheck/go-dispatch.sh"])
                    else:
                        self.assertEqual(row["exec_argv"], argv)
                        self.assertEqual(argv, ["exec", "builder-1", "nice", "-n", 0, "taskset", "-c", expected,
                                                "/bin/sh", "/mpcheck/go-dispatch-affinity.sh", "g", "sibling-2-1", 1, 0])
            finally:
                wave.pool.shutdown()

    def check_gate(self, mode, broken):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            gate = root / "gate"
            gate.mkdir()
            wave = sibling_build.BuildWave(builder_cohort(root, mode), "wave", 0, root)
            for slot, job in enumerate(wave.cohort.jobs[32:]):
                mask = sibling_build.compiler_mask(job, mode)
                placement = proof("2" if broken and slot == 0 else mask, slot)
                (gate / f"wave.go.{slot}.ready").write_text("ready")
                (gate / f"wave.go.{slot}.policy").write_text(json.dumps(placement))
                (gate / f"wave.go.{slot}.start").write_text(str(1000 + slot))
            try:
                with patch.object(wave, "run", side_effect=lambda i: {"id": f"builder-{i}", "stdout": "intact"}):
                    if broken:
                        with self.assertRaises(ValueError):
                            wave.start()
                        self.assertFalse((gate / "wave.go").exists())
                    else:
                        self.assertEqual(wave.start(), 1007)
                        rows = wave.finish()
                        self.assertTrue(all(r["stdout"] == "intact" and "policy" not in r for r in rows))
                        self.assertEqual([r["compiler_affinity"]["child"]["cpus_allowed_list"] for r in rows],
                                         [sibling_build.compiler_mask(job, mode) for job in wave.cohort.jobs[32:]])
            finally:
                wave.close()
            self.assertEqual((gate / "wave.go.abort").exists(), broken)

    def test_affinity_evidence_must_pass_before_releasing_all_eight_builders(self):
        self.check_gate("home", broken=False)
        self.check_gate("pool", broken=False)
        self.check_gate("pool", broken=True)

    def test_dispatch_keeps_both_real_build_revisions(self):
        self.assertEqual(fixture.DISPATCH_FILE, "go-dispatch-affinity.sh")
        self.assertEqual(fixture.DISPATCH.count('sh /mpcheck/job.sh "$revision-'), 2)
        self.assertLess(fixture.DISPATCH.index("-dispatcher"), fixture.DISPATCH.index("printf ready"))
        self.assertLess(fixture.DISPATCH.index('go.abort" ] || exit 75'), fixture.DISPATCH.index('sh /mpcheck/job.sh'))


if __name__ == "__main__":
    unittest.main()
