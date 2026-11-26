"""Verify paced completion overlap and matched comparisons offline."""

import unittest
from copy import deepcopy
from pathlib import Path
from unittest.mock import patch

import sibling_paced_results as paced
from sibling_paced_results import BUILDERS, OFFER_NS, build_overlap


class BuildOverlapTest(unittest.TestCase):
    def test_completion_at_build_exit_is_covered(self):
        gate = 1_795_562_000_000_000_000
        http = [{"receipt": {"pace": {"arrivals": [
            {"completion_offset_ns": OFFER_NS + offset} for offset in offsets
        ]}}} for offsets in ((10, 25, 40), (20, 30, 35))]
        wave = {"scheduled_unix_ns": gate, "offered_requests": 6, "last_completion_offset_ns": OFFER_NS + 40}

        for first_exit, expected_count, margin in ((25, 3, -15), (39, 1, -1), (40, 0, 0), (41, 0, 1)):
            with self.subTest(first_exit=first_exit):
                # The earliest build exit comes from a different slot than the first receipt.
                exits = [100] * BUILDERS
                exits[3] = first_exit
                builds = [{"stdout": f"revision-a\nrevision-b\nend {gate + OFFER_NS + offset} 0\n"} for offset in exits]
                self.assertEqual(build_overlap(http, builds, wave), {
                    "completed_after_first_build": expected_count,
                    "completed_after_first_build_fraction": expected_count / 6,
                    "first_build_end_margin_ns": margin,
                })


def trial_plan(path, seed, nice):
    return {"scope": f"/test/{path.name}", "seed": seed, "build_nice": nice, "offered_rps": 64_000,
            "layouts": ["grouped"], "rounds": 1, "pages": {}, "worker_scheduler": "hrtick-125us",
            "builders": BUILDERS, "healthy_pairs": paced.PAIRS, "dense_ms": 1500}


class BuildPriorityTest(unittest.TestCase):
    def test_mismatched_comparison_inputs_fail_before_replay(self):
        control, candidate = map(Path, ("nice-5", "nice-0"))
        baseline = trial_plan(control, 250081, 5)
        treatment = trial_plan(candidate, 250081, 0)
        mutations = (({"offered_rps": 128_000}, "rates or seeds"),
                     ({"seed": 250083}, "rates or seeds"),
                     ({"layouts": ["same"]}, "comparison inputs"),
                     ({"worker_scheduler": "hrtick"}, "comparison inputs"),
                     ({"build_nice": False}, "requires nice"),
                     ({"scope": baseline["scope"]}, "duplicate paced boot scope"))
        for changes, message in mutations:
            with self.subTest(changes=changes):
                plans = {control.name: baseline, candidate.name: {**treatment, **changes}}
                with (patch.object(paced, "read", side_effect=lambda path, _: plans[path.name]),
                      patch.object(paced, "replay") as replay):
                    with self.assertRaisesRegex(ValueError, message):
                        paced.compare([control], [candidate])
                    replay.assert_not_called()

    def test_pairs_by_seed_and_replays_each_boot_once(self):
        controls = [Path("plus5-81"), Path("plus5-83")]
        candidates = [Path("zero-83"), Path("zero-81")]
        runs = {}
        measurements = ((controls[0], 250081, 5, 10, 20, 0, 10),
                        (controls[1], 250083, 5, 100, 10, 100, 20),
                        (candidates[0], 250083, 0, 50, 20, 50, 10),
                        (candidates[1], 250081, 0, 20, 20, 10, -10))
        for path, seed, nice, a, b, drain, margin in measurements:
            wave = {arm: {**dict.fromkeys(paced.PAIRED_METRICS, p95), "drain_after_window_ns": drain,
                          "first_build_end_margin_ns": margin, "max_clock_calibration_ns": 12, "timer_slack_ns": [50_000]}
                    for arm, p95 in (("A", a), ("B", b))}
            runs[path.name] = {"plan": trial_plan(path, seed, nice), "boot": path.name, "worker": {}, "images": {},
                               "placements": {}, "rows": {"grouped": [wave]}, "totals": {"offered_requests": 192_000}}

        with (patch.object(paced, "read", side_effect=lambda path, _: runs[path.name]["plan"]),
              patch.object(paced, "replay", side_effect=lambda path: runs[path.name]) as replay):
            result = paced.compare(controls, candidates)
            self.assertCountEqual([call.args[0].name for call in replay.call_args_list], runs.keys())
            runs[candidates[0].name]["boot"] = runs[controls[0].name]["boot"]
            with self.assertRaisesRegex(ValueError, "duplicate Micropod boot ID"):
                paced.compare(controls, candidates)

        self.assertEqual((result["control"]["build_nice"], result["candidate"]["build_nice"]), (5, 0))
        rate = result["contrast"]["rates"]["64000"]
        self.assertEqual((rate["boot_pairs"], rate["seeds"], rate["windows_per_layout_per_boot"]), (2, [250081, 250083], 1))
        self.assertEqual(rate["layouts"]["grouped"]["orbstack"]["p95_us"]["paired_ratio"], 1.5)
        micropod = rate["layouts"]["grouped"]["micropod"]
        self.assertEqual(micropod["p95_us"]["paired_ratio"], 1.25)
        self.assertEqual(micropod["p95_us"]["paired_difference"], -20)
        self.assertIsNone(micropod["drain_after_window_ns"]["paired_ratio"])
        self.assertIsNone(micropod["first_build_end_margin_ns"]["paired_ratio"])
        self.assertEqual(micropod["first_build_end_margin_ns"]["paired_difference"], -15)


class GroupedContrastTest(unittest.TestCase):
    def setUp(self):
        self.controls = [Path("fine-91"), Path("fine-93")]
        self.candidates = [Path("coarse-91"), Path("coarse-93")]
        self.runs = {}
        for paths, profile, gates, p95 in ((self.controls, "hrtick-125us", (10, 40), 200),
                                         (self.candidates, "hrtick", (20, 30), 100)):
            for path, seed, gate in zip(paths, (250091, 250093), gates, strict=True):
                plan = {**trial_plan(path, seed, 0), "rounds": 4, "worker_scheduler": profile, "worker_next_buddy": True,
                        "cpu_groups": True, "network_topology": "single", "quiet_sha256": "frozen HTTP binary"}
                features = ["HRTICK", "NEXT_BUDDY", "PICK_BUDDY"]
                scheduler = {"setting": "inherit", "before": features, "after": features, "clocksource": "arch_sys_counter",
                             "base_slice_ns": 125_000 if profile == "hrtick-125us" else 2_100_000}
                wave = {arm: {**dict.fromkeys(paced.PAIRED_METRICS, latency), "scheduled_unix_ns": gate,
                              "build": {"products": ["same product"]}, "max_clock_calibration_ns": 12, "timer_slack_ns": [50_000]}
                        for arm, latency in (("A", p95), ("B", 150))}
                self.runs[path.name] = {"plan": plan, "boot": path.name, "peer_boot": "shared peer boot", "images": {},
                                        "worker": {"worker": "same worker", "scheduler": scheduler}, "placements": {},
                                        "rows": {"grouped": [deepcopy({**wave, "order": order}) for order in ("AB", "BA", "BA", "AB")]},
                                        "totals": {"offered_requests": 4 * 192_000}}

    def compare_scheduler(self):
        return paced.compare(self.controls, self.candidates, change="worker_scheduler")

    def test_packaged_holdout_allows_only_the_two_selected_changes(self):
        for paths, profile, scratch in ((self.controls, "hrtick-125us", "overlay"),
                                        (self.candidates, "hrtick-250us", "tmpfs")):
            for path in paths:
                run = self.runs[path.name]
                run["plan"].update(worker_scheduler=profile, build_scratch=scratch,
                                   network_topology="per-job", network_driver="ipvlan")
                run["worker"]["scheduler"]["base_slice_ns"] = paced.sibling_sched.WORKER[profile]
        with (patch.object(paced, "read", side_effect=lambda path, _: self.runs[path.name]["plan"]),
              patch.object(paced, "replay", side_effect=lambda path: self.runs[path.name])):
            report = paced.compare(self.controls, self.candidates, change="scheduler_and_scratch")["contrast"]
            self.assertEqual(report["change"], {"worker_scheduler": ["hrtick-125us", "hrtick-250us"],
                                                "build_scratch": ["overlay", "tmpfs"]})
            orders = [r["treatment_order"] for r in report["rates"]["64000"]["by_seed"]]
            self.assertEqual(orders, [["125us/overlay", "250us/tmpfs"], ["250us/tmpfs", "125us/overlay"]])
            for path in self.candidates:
                self.runs[path.name]["plan"]["build_scratch"] = "overlay"
            with self.assertRaisesRegex(ValueError, "overlay to tmpfs"):
                paced.compare(self.controls, self.candidates, change="scheduler_and_scratch")

    def test_actual_slice_is_the_only_readback_change_and_seed_order_is_reported(self):
        with (patch.object(paced, "read", side_effect=lambda path, _: self.runs[path.name]["plan"]),
              patch.object(paced, "replay", side_effect=lambda path: self.runs[path.name]) as replay):
            report = self.compare_scheduler()["contrast"]
        self.assertEqual(replay.call_count, 4)
        self.assertEqual(report["base_slice_ns"], [125_000, 2_100_000])
        rate = report["rates"]["64000"]
        self.assertEqual(rate["boot_pairs"], 2)
        self.assertEqual(rate["layouts"]["grouped"]["micropod"]["service_p95_us"]["paired_ratio"], 0.5)
        first, second = rate["by_seed"]
        self.assertEqual(first["profile_order"], ["hrtick-125us", "hrtick"])
        self.assertEqual(second["profile_order"], ["hrtick", "hrtick-125us"])
        self.assertEqual(first["engine_order_counts"], {"AB": 2, "BA": 2})
        self.assertEqual(first["engines"]["micropod"]["p99_us"]["paired_difference"], -100)
        self.assertEqual(second["engines"]["orbstack"]["build_makespan_s"]["paired_difference"], 0)

    def test_scheduler_contrast_rejects_another_planned_knob_before_replay(self):
        plan = self.runs[self.candidates[0].name]["plan"]
        plan["network_topology"] = "pair"
        # A change on both candidate manifests is still a second treatment variable.
        self.runs[self.candidates[1].name]["plan"]["network_topology"] = "pair"
        with (patch.object(paced, "read", side_effect=lambda path, _: self.runs[path.name]["plan"]),
              patch.object(paced, "replay") as replay):
            with self.assertRaisesRegex(ValueError, "unmatched paced comparison inputs"):
                self.compare_scheduler()
            replay.assert_not_called()

    def test_scheduler_contrast_rejects_wrong_readback_output_or_order(self):
        path = self.candidates[0].name
        original = self.runs[path]
        with (patch.object(paced, "read", side_effect=lambda folder, _: self.runs[folder.name]["plan"]),
              patch.object(paced, "replay", side_effect=lambda folder: self.runs[folder.name])):
            for change, message in (("base slice", "unexpected paced scheduler readback"),
                                    ("feature", "unmatched paced worker"),
                                    ("artifact", "build outputs changed"), ("order", "unbalanced paced engine order"),
                                    ("peer boot", "changed the OrbStack boot")):
                with self.subTest(change=change):
                    run = self.runs[path] = deepcopy(original)
                    scheduler = run["worker"]["scheduler"]
                    wave = run["rows"]["grouped"][0]
                    if change == "base slice":
                        scheduler["base_slice_ns"] = 125_000
                    elif change == "feature":
                        scheduler["after"].append("NO_RUN_TO_PARITY")
                    elif change == "artifact":
                        wave["A"]["build"]["products"] = ["different product"]
                    elif change == "order":
                        wave["order"] = "BA"
                    else:
                        run["peer_boot"] = "restarted peer"
                    with self.assertRaisesRegex(ValueError, message):
                        self.compare_scheduler()

    def test_native_client_contrast_pairs_only_the_requested_slice(self):
        for slices in ((0, 250), (500, 750)):
            with self.subTest(slices=slices):
                for paths, us in zip((self.controls, self.candidates), slices, strict=True):
                    for path in paths:
                        run = self.runs[path.name]
                        run["plan"].update(worker_scheduler="hrtick", build_policy="normal", client_slice_driver_sha256="matched",
                                           slice_target="native-clients", fair_slice_us=us)
                        run["worker"]["scheduler"]["base_slice_ns"] = 2_100_000

                levels = None if slices == (0, 250) else slices
                check = paced.sibling_client_slice.check_plan
                with (patch.object(paced.sibling_client_slice, "check_plan", wraps=check) as helper,
                      patch.object(paced, "read", side_effect=lambda path, _: self.runs[path.name]["plan"]),
                      patch.object(paced, "replay", side_effect=lambda path: self.runs[path.name]) as replay):
                    report = paced.compare(self.controls, self.candidates, change="fair_slice_us", client_slices=levels)["contrast"]
                    self.assertEqual(replay.call_count, 4)
                    self.assertCountEqual([call.args[0]["fair_slice_us"] for call in helper.call_args_list], [*slices, *slices])
                    for path in self.candidates:
                        self.runs[path.name]["plan"]["client_slice_driver_sha256"] = "different"
                    replay.reset_mock()
                    with self.assertRaisesRegex(ValueError, "unmatched paced comparison inputs"):
                        paced.compare(self.controls, self.candidates, change="fair_slice_us", client_slices=levels)
                    replay.assert_not_called()

                self.assertEqual(report["change"], {"fair_slice_us": list(slices)})
                self.assertEqual(report["slice_target"], "native-clients")
                first, second = report["rates"]["64000"]["by_seed"]
                self.assertEqual(first["client_slice_order_us"], list(slices))
                self.assertEqual(second["client_slice_order_us"], list(reversed(slices)))

    def test_scratch_contrast_pairs_overlay_and_tmpfs(self):
        for paths, mode in ((self.controls, "overlay"), (self.candidates, "tmpfs")):
            for path in paths:
                run = self.runs[path.name]
                run["plan"].update(worker_scheduler="hrtick-125us", build_scratch=mode)
                run["worker"]["scheduler"]["base_slice_ns"] = 125_000

        with (patch.object(paced, "read", side_effect=lambda path, _: self.runs[path.name]["plan"]),
              patch.object(paced, "replay", side_effect=lambda path: self.runs[path.name]) as replay):
            result = paced.compare(self.controls, self.candidates, change="build_scratch")
        self.assertEqual(replay.call_count, 4)
        self.assertEqual(result["control"]["build_scratch"], "overlay")
        self.assertEqual(result["candidate"]["build_scratch"], "tmpfs")
        self.assertEqual(result["contrast"]["change"], {"build_scratch": ["overlay", "tmpfs"]})
        first, second = result["contrast"]["rates"]["64000"]["by_seed"]
        self.assertEqual(first["build_scratch_order"], ["overlay", "tmpfs"])
        self.assertEqual(second["build_scratch_order"], ["tmpfs", "overlay"])

    def test_network_contrast_pairs_explicit_shared_and_per_job_ipvlan(self):
        for paths, mode in ((self.controls, "shared"), (self.candidates, "per-job")):
            for path in paths:
                run = self.runs[path.name]
                run["plan"].update(worker_scheduler="hrtick-125us", network_driver="ipvlan", network_topology=mode)
                run["worker"]["scheduler"]["base_slice_ns"] = 125_000

        with (patch.object(paced, "read", side_effect=lambda path, _: self.runs[path.name]["plan"]),
              patch.object(paced, "replay", side_effect=lambda path: self.runs[path.name]) as replay):
            result = paced.compare(self.controls, self.candidates, change="network_topology")
        self.assertEqual(replay.call_count, 4)
        self.assertEqual(result["control"]["network_topology"], "shared")
        self.assertEqual(result["candidate"]["network_topology"], "per-job")
        first, second = result["contrast"]["rates"]["64000"]["by_seed"]
        self.assertEqual(first["topology_order"], ["shared", "per-job"])
        self.assertEqual(second["topology_order"], ["per-job", "shared"])

    def test_two_explicit_profile_pairs_support_three_matched_seeds(self):
        for paths in (self.controls, self.candidates):
            extra = Path(f"{paths[0].name}-extra")
            run = self.runs[extra.name] = deepcopy(self.runs[paths[0].name])
            for wave in run["rows"]["grouped"]:
                wave["A"]["scheduled_unix_ns"] += 50
            run.update(boot=extra.name)
            run["plan"].update(seed=250095, scope=f"/test/{extra.name}")
            paths.append(extra)

        for profiles, slices in ((("hrtick-500us", "hrtick-1ms"), [500_000, 1_000_000]),
                                 (("hrtick-125us", "hrtick-250us"), [125_000, 250_000])):
            with self.subTest(profiles=profiles):
                for paths, profile, slice_ns in zip((self.controls, self.candidates), profiles, slices, strict=True):
                    for path in paths:
                        run = self.runs[path.name]
                        run["plan"]["worker_scheduler"] = profile
                        run["worker"]["scheduler"]["base_slice_ns"] = slice_ns
                with (patch.object(paced, "read", side_effect=lambda path, _: self.runs[path.name]["plan"]),
                      patch.object(paced, "replay", side_effect=lambda path: self.runs[path.name]) as replay):
                    contrast = paced.compare(self.controls, self.candidates, change="worker_scheduler",
                                              scheduler_profiles=profiles)["contrast"]
                self.assertEqual(replay.call_count, 6)
                self.assertEqual(contrast["base_slice_ns"], slices)
                self.assertEqual(contrast["rates"]["64000"]["boot_pairs"], 3)
                self.assertEqual(contrast["rates"]["64000"]["seeds"], [250091, 250093, 250095])

    def test_explicit_scheduler_profiles_must_be_distinct_hrtick_settings(self):
        for profiles in (("hrtick", "hrtick"), ("inherit", "hrtick"), ("hrtick-93us", "hrtick"), ("hrtick",)):
            with self.subTest(profiles=profiles):
                with self.assertRaisesRegex(ValueError, "two distinct HRTICK worker profiles"):
                    paced.compare(self.controls, self.candidates, change="worker_scheduler", scheduler_profiles=profiles)


class BuildReceiptTest(unittest.TestCase):
    def test_verified_builds_must_stay_in_the_primed_boot(self):
        gate = 1_795_562_000_000_000_000
        boot = "12345678-1234-1234-1234-123456789012"
        records, clients = [], []
        for slot in range(BUILDERS):
            revision, name = f"sibling-0-{slot}", f"client-{slot}"
            products = [f"{slot * 2 + index + 1:064x}" for index in range(2)]
            lines = [f"{revision}-{suffix} {name} 8 100 200 1 1 1 {digest} 1:2 1:3 {boot} 123 action"
                     for suffix, digest in zip("ab", products, strict=True)]
            clients.append({"id": name, "name": name})
            records.append({"id": name, "revision": revision, "code": 0, "stderr": "",
                            "started_unix_ns": gate - 35_000_000,
                            "stdout": "\n".join([*lines, f"end {gate + OFFER_NS} 0"])})
        jobs = [{}] * paced.PAIRS + clients
        score = paced.score_builds(records, jobs, 0, 0, gate, expected_boot=boot)
        self.assertEqual(score["jobs"], BUILDERS)
        self.assertEqual(len(score["products"]), 2 * BUILDERS)

        records[-1]["stdout"] = records[-1]["stdout"].replace(boot, "12345678-1234-1234-1234-123456789000", 1)
        with self.assertRaisesRegex(ValueError, "different guest boot"):
            paced.score_builds(records, jobs, 0, 0, gate, expected_boot=boot)


if __name__ == "__main__":
    unittest.main()
