"""Check CPU scopes and the matched compiler-affinity outcomes offline."""

import unittest
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch

import sibling_compiler_affinity_results as study


def affinity(mask, tid=9):
    return {"pid": tid, "threads": [{"tid": tid, "cpus_allowed_list": mask}]}


def task(mask, tid, slice_ns=250_000):
    return {"tid": tid, "cpus_allowed_list": mask, "policy": 0, "nice": 0, "priority": 0, "slice_ns": slice_ns}


class CompilerCPUScopeTest(unittest.TestCase):
    def test_builder_has_real_broad_cgroup_and_home_listener(self):
        job = {"name": "builder", "mask": "0-3", "docker_cpuset": "0-3", "home_cpu": "1", "affinity": affinity("1"),
               "cgroup": {"cpuset.cpus.effective": "0-3", "cpu.max": "100000 100000", "visible_cpus": 4,
                          "gomaxprocs": 1, "memory.max": str(512 << 20), "pids.max": "192"}}
        study.check_container_cpu(job, True, "1")
        for field, value, message in (("mask", "1", "CPU allowance"),
                                      ("cgroup", {**job["cgroup"], "cpu.max": "400000 100000"}, "CPU allowance"),
                                      ("affinity", affinity("0-3"), "did not keep affinity")):
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValueError, message):
                    study.check_container_cpu({**job, field: value}, True, "1")

    def test_http_home_affinity_is_proven_before_reusing_raw_endpoint_replay(self):
        endpoints = [{"name": f"job-{slot}", "ip": f"10.0.0.{slot + 1}"} for slot in range(64)]
        jobs = deepcopy(endpoints)
        jobs[32].update(id="builder-container", mask="0-3", home_cpu="0", affinity=affinity("0"))
        tag = "grouped-0-all-A"
        argv = ["exec", "builder-container", "taskset", "-c", "0", "/mpcheck/quiet-http",
                "-thread-probe", study.sibling_group.PROBE, "-url", "http://10.0.0.1:8080", "-marker", "job-0",
                "-requests", 0, "-duration-ms", 1500, "-offered-rps", 64_000, "-client-slot", 0,
                "-ready-file", f"/gate/{tag}.0", "-start-file", f"/gate/{tag}"]
        rows = [{"index": 0, "exec_argv": argv, "receipt": {"window": affinity("0")}}]
        with patch.object(study.paced, "score_wave", return_value={"verified": True}) as replay:
            self.assertEqual(study.score_http(rows, jobs, "A", 0, tag, None), {"verified": True})
            replay.assert_called_once_with(rows, endpoints, 64_000, 16_384)
            self.assertEqual(jobs[32]["mask"], "0-3")
            rows[0]["receipt"]["window"] = affinity("0-3")
            with self.assertRaisesRegex(ValueError, "did not keep affinity"):
                study.score_http(rows, jobs, "A", 0, tag, None)
            rows[0]["receipt"]["window"] = affinity("0")
            argv[1] = "replacement-container"
            with self.assertRaisesRegex(ValueError, "wrong measured HTTP exec"):
                study.score_http(rows, jobs, "A", 0, tag, None)
            self.assertEqual(replay.call_count, 1)

    def test_dispatcher_child_inherit_the_selected_mask_in_both_engines(self):
        jobs = [None] * 32 + [{"id": f"builder-{slot}", "home_cpu": str(slot % 4), "mask": "0-3"} for slot in range(8)]
        for arm, ns in (("A", 250_000), ("B", 2_100_000)):
            for level in study.LEVELS:
                tag = f"grouped-0-all-{arm}"
                rows = []
                for slot in range(8):
                    mask = str(slot % 4) if level == "home" else "0-3"
                    argv = ["exec", f"builder-{slot}", "nice", "-n", 0, "taskset", "-c", mask, "/bin/sh",
                            "/mpcheck/go-dispatch-affinity.sh", tag, f"sibling-0-{slot}", slot, 0]
                    rows.append({"exec_argv": argv, "compiler_affinity": {
                        "dispatcher": task(mask, 21, ns), "child": task(mask, 32, ns), "child_parent_pid": 21,
                    }})
                with self.subTest(arm=arm, level=level):
                    self.assertEqual(study.check_build_threads(rows, jobs, level, arm, tag, 0), ns)
                    rows[-1]["exec_argv"][1] = "wrong-builder"
                    with self.assertRaisesRegex(ValueError, "wrong compiler exec"):
                        study.check_build_threads(rows, jobs, level, arm, tag, 0)
                    rows[-1]["exec_argv"][1] = "builder-7"
                    rows[-1]["compiler_affinity"]["child"]["cpus_allowed_list"] = "0" if level == "pool" else "0-3"
                    with self.assertRaisesRegex(ValueError, f"engine {arm}, slot 7"):
                        study.check_build_threads(rows, jobs, level, arm, tag, 0)


def window(block, order, gate, latency, makespan, late=0):
    reference = {**dict.fromkeys(study.METRICS, 3), "scheduled_unix_ns": gate, "timer_slack_ns": [50_000],
                 "offered_requests": 96_000, "requests": 96_000, "warm_connections": 32, "completed_after_first_build": 0,
                 "first_build_end_margin_ns": 100, "compiler_slice_ns": 2_100_000,
                 "build": {"jobs": 8, "revisions": 16, "test_passes": 128, "products": [f"output {block}"]}}
    native = {**reference, "p95_us": latency, "build_makespan_s": makespan, "compiler_slice_ns": 250_000,
              "completed_after_first_build": late, "first_build_end_margin_ns": -5 if late else 100}
    return {"block": block, "order": order, "A": native, "B": reference}


class CompilerAffinityContrastTest(unittest.TestCase):
    def setUp(self):
        self.runs, self.plans = {}, {}
        for seed, order in study.SEED_ORDER.items():
            for i, level in enumerate(order):
                path = Path(f"{seed}-{level}").resolve()
                latencies = [2, 4, 2, 4] if level == "pool" else [4, 4, 4, 4]
                builds = [2, 2, 4, 2] if level == "pool" else [4, 4, 4, 4]
                windows = [window(block, arm_order, seed * 100 + i * 10 + block, latency, build,
                                  late=2 if level == "pool" and block == 3 else 0)
                           for block, (arm_order, latency, build) in enumerate(
                               zip(("AB", "BA", "BA", "AB"), latencies, builds, strict=True))]
                self.plans[path] = {"seed": seed, "compiler_affinity": level, "scope": str(path), "pages": {},
                                    "compiler_affinity_probe_sha256": "same launcher"}
                self.runs[path] = {"archive": path.name, "boot": path.name, "peer_boot": "same peer",
                                   "worker": {}, "images": {}, "tool_identity": {}, "windows": windows}

    def test_reads_each_boot_once_and_retains_same_window_overlap(self):
        with (patch.object(study, "read", side_effect=lambda path, name: self.plans[path] if name == "plan.json" else {}),
              patch.object(study, "check_plan", side_effect=lambda _, p: (p["seed"], p["compiler_affinity"])),
              patch.object(study.signed, "signed_settings", return_value={}),
              patch.object(study, "replay", side_effect=lambda path, _: self.runs[path]) as replay):
            result = study.compare(list(reversed(self.plans)))
            self.assertCountEqual([call.args[0] for call in replay.call_args_list], self.plans.keys())
        self.assertEqual((result["boot_pairs"], result["engine_windows"]), (2, 32))
        self.assertEqual(result["totals"], {"offered_requests": 3_072_000, "requests": 3_072_000,
                                            "warm_connections": 1024, "completed_after_first_build": 4, "jobs": 256,
                                            "revisions": 512, "test_passes": 4096})
        self.assertEqual(result["minimum_first_build_end_margin_ns"], -5)
        self.assertEqual(result["within_level"]["pool"]["same_window_wins"]["micropod"], 2)
        self.assertEqual(result["within_engine"]["micropod"]["same_window_wins"]["pool"], 2)
        self.assertEqual(result["within_engine"]["orbstack"]["same_window_wins"]["pool"], 0)
        self.assertEqual(result["by_seed"][1]["treatment_order"], ["pool", "home"])

    def test_rejects_changed_input_without_replaying(self):
        self.plans[next(reversed(self.plans))]["compiler_affinity_probe_sha256"] = "different launcher"
        with (patch.object(study, "read", side_effect=lambda path, name: self.plans[path] if name == "plan.json" else {}),
              patch.object(study, "check_plan", side_effect=lambda _, p: (p["seed"], p["compiler_affinity"])),
              patch.object(study.signed, "signed_settings", return_value={}), patch.object(study, "replay") as replay):
            with self.assertRaisesRegex(ValueError, "unmatched compiler affinity workload"):
                study.compare(list(self.plans))
            replay.assert_not_called()


if __name__ == "__main__":
    unittest.main()
