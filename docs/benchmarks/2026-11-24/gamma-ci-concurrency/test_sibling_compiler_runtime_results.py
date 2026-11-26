"""Test policy proof, peer inheritance and matched compiler runtime reports."""

import unittest
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch

import sibling_compiler_runtime_results as study


def thread(tid, mask, runtime):
    return {"tid": tid, "cpus_allowed_list": mask, "policy": 0, "nice": 0, "priority": 0, "slice_ns": runtime}


class CompilerRuntimeProofTest(unittest.TestCase):
    def setUp(self):
        self.jobs = [None] * 32 + [{"id": f"job-{i}", "home_cpu": str(i % 4), "mask": "0-3"} for i in range(8)]

    def builds(self, arm, mode):
        tag = f"grouped-0-all-{arm}"
        request = study.requested_us(arm, mode)
        inherited = study.ORDINARY_SLICE_NS[arm]
        effective = request * 1000 or inherited
        rows = []
        for i, job in enumerate(self.jobs[32:]):
            mask = job["home_cpu"]
            argv = ["exec", job["id"], "nice", "-n", 0, "taskset", "-c", mask, study.RUNTIME_PROBE, "-policy", "normal",
                    "-build-slice-us", str(request), "/bin/sh", "/mpcheck/go-dispatch-runtime.sh",
                    tag, f"sibling-0-{i}", i, 0]
            proof = {"dispatcher": thread(11, mask, effective), "child": thread(12, mask, effective), "child_parent_pid": 11,
                     "slice": {"requested_us": request, "inherited_ns": inherited, "dispatcher_pid": 11}}
            rows.append({"exec_argv": argv, "compiler_affinity": proof})
        return tag, rows

    def test_peer_requires_inherited_runtime_even_if_an_explicit_request_would_match(self):
        tag, rows = self.builds("B", "long")
        self.assertEqual(study.check_builds(rows, self.jobs, "B", "long", tag, 0), 2_100_000)
        rows[-1]["exec_argv"][12] = "2100"
        with self.assertRaisesRegex(ValueError, "wrong compiler runtime exec"):
            study.check_builds(rows, self.jobs, "B", "long", tag, 0)
        rows[-1]["exec_argv"][12] = "0"
        rows[-1]["compiler_affinity"]["slice"]["requested_us"] = 2100
        with self.assertRaisesRegex(ValueError, "dispatcher slice evidence"):
            study.check_builds(rows, self.jobs, "B", "long", tag, 0)

    def test_native_policy_proof_requires_real_child_runtime_and_unchanged_inheritance(self):
        inherited_tag, inherited = self.builds("A", "inherit")
        self.assertEqual(study.check_builds(inherited, self.jobs, "A", "inherit", inherited_tag, 0), 250_000)
        tag, rows = self.builds("A", "long")
        self.assertEqual(study.check_builds(rows, self.jobs, "A", "long", tag, 0), 2_100_000)
        child = rows[0]["compiler_affinity"]["child"]
        child["slice_ns"] = 250_000
        with self.assertRaisesRegex(ValueError, "dispatcher or child"):
            study.check_builds(rows, self.jobs, "A", "long", tag, 0)
        child["slice_ns"] = 2_100_000
        rows[0]["compiler_affinity"]["slice"]["inherited_ns"] = 350_000
        with self.assertRaisesRegex(ValueError, "unexpected inherited compiler runtime"):
            study.check_builds(rows, self.jobs, "A", "long", tag, 0)

    def test_noncompiler_threads_keep_ordinary_runtime_before_and_after(self):
        inventory = {}
        observed = {}
        for arm, runtime in study.ORDINARY_SLICE_NS.items():
            policy = [thread(11, "0", runtime), thread(12, "0", runtime)]
            inventory[arm] = {"jobs": [{"id": arm, "affinity": {"pid": 11}, "home_cpu": "0", "runtime_threads": policy}]}
            observed[arm] = [{"id": arm, "pid": 11, "threads": deepcopy(policy)}]
        study.check_residents(inventory, observed)
        observed["A"][0]["threads"][1]["slice_ns"] = 2_100_000
        with self.assertRaisesRegex(ValueError, "non-compiler process"):
            study.check_residents(inventory, observed)
        observed["A"][0]["threads"][1]["slice_ns"] = 250_000
        observed["B"][0]["id"] = "replacement"
        with self.assertRaisesRegex(ValueError, "changed container or PID"):
            study.check_residents(inventory, observed)


def wave(arm_order, block, gate, latency, build):
    result = {**dict.fromkeys(study.affinity.METRICS, 3), "scheduled_unix_ns": gate, "timer_slack_ns": [50_000],
              "offered_requests": 96_000, "requests": 96_000, "warm_connections": 32, "completed_after_first_build": 0,
              "first_build_end_margin_ns": 1_234, "build": {"jobs": 8, "revisions": 16, "test_passes": 128,
                                                           "products": [f"output {block}"]}}
    return {"order": arm_order, "block": block, "B": result, "A": {**result, "p95_us": latency, "build_makespan_s": build}}


class CompilerRuntimeContrastTest(unittest.TestCase):
    def setUp(self):
        self.plans, self.runs = {}, {}
        for seed, order in study.SEED_ORDER.items():
            for pos, mode in enumerate(order):
                path = Path(f"{seed}-{mode}").resolve()
                self.plans[path] = {"seed": seed, "compiler_runtime": mode, "scope": str(path),
                                    "pages": {}, "compiler_runtime_probe_sha256": "same"}
                latencies, builds = ((4, 4, 4, 4), (4, 4, 4, 4))
                if mode == "long":
                    latencies = (1, 1, 4, 4) if seed == 250211 else (2, 2, 2, 2)
                    builds = (4, 4, 1, 1) if seed == 250211 else (2, 2, 2, 2)
                rows = [wave(order, i, seed * 100 + pos * 10 + i, p95, build)
                        for i, (order, p95, build) in enumerate(zip(("BA", "AB", "BA", "AB"), latencies, builds, strict=True))]
                self.runs[path] = {"archive": path.name, "boot": path.name, "peer_boot": "one peer",
                                   "worker": {}, "images": {}, "tool_identity": {}, "windows": rows}

    def compare(self):
        with (patch.object(study, "read", side_effect=lambda path, name: self.plans[path] if name == "plan.json" else {}),
              patch.object(study, "check_plan", side_effect=lambda _, p: (p["seed"], p["compiler_runtime"])),
              patch.object(study.signed, "signed_settings", return_value={}),
              patch.object(study, "replay", side_effect=lambda path, _: self.runs[path]) as replay):
            result = study.compare(list(reversed(self.plans)))
            self.assertCountEqual([call.args[0] for call in replay.call_args_list], self.plans)
            return result

    def test_distinguishes_boot_medians_from_same_window_wins(self):
        result = self.compare()
        self.assertTrue(result["micropod_lower_both_long_medians_in_each_seed"])
        first, second = result["by_seed"]
        self.assertEqual(first["within_mode"]["long"]["same_window_win_positions"]["micropod"], [])
        self.assertEqual(second["within_mode"]["long"]["same_window_wins"]["micropod"], 4)
        self.assertEqual(second["treatment_order"], ["long", "inherit"])
        self.assertEqual(result["totals"]["warm_connections"], 1024)
        self.assertEqual(result["totals"]["requests"], 3_072_000)

    def test_rejects_other_input_changes_before_replay(self):
        self.plans[next(reversed(self.plans))]["compiler_runtime_probe_sha256"] = "different"
        with (patch.object(study, "read", side_effect=lambda path, name: self.plans[path] if name == "plan.json" else {}),
              patch.object(study, "check_plan", side_effect=lambda _, p: (p["seed"], p["compiler_runtime"])),
              patch.object(study.signed, "signed_settings", return_value={}), patch.object(study, "replay") as replay):
            with self.assertRaisesRegex(ValueError, "unmatched compiler runtime signed worker or workload"):
                study.compare(list(self.plans))
            replay.assert_not_called()


if __name__ == "__main__":
    unittest.main()
