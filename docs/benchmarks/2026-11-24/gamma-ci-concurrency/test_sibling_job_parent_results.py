"""Test that convincing but invalid CPU parent and timing records cannot qualify."""

import unittest
from hashlib import sha256
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import sibling_job_parent_flat_holdout as holdout
import sibling_job_parent_results as report


class CpuParentReplayTest(unittest.TestCase):
    def test_rejects_pair_parents_derived_from_the_wrong_named_network(self):
        prefix = "private-a-grouped"
        cohort = {"network": prefix, "attached_networks": {}, "jobs": []}
        parents = []
        for slot in range(32):
            network = f"{prefix}-job-{slot:02d}"
            nid = f"{slot + 1:064x}"
            cohort["attached_networks"][network] = {"Id": nid}
            digest = sha256(f"{nid}\0job-{slot:02d}".encode()).hexdigest()
            parents.append(f"/k8s.io/micropod-job-{digest}")
        valid = {}
        for position in range(64):
            slot = position % 32
            cid, runtime = f"{position + 100:064x}", f"{position + 300:064x}"
            cohort["jobs"].append({
                "id": cid, "cpu_group": f"job-{slot:02d}",
                "docker_inspect": {"NetworkSettings": {"Networks": {
                    f"{prefix}-job-{slot:02d}": {"NetworkID": f"{slot + 1:064x}"},
                }}},
            })
            valid[cid] = f"{parents[slot]}/{runtime}"

        self.assertEqual(report.check_parent_paths(cohort, "job", valid), dict.fromkeys(parents, 2))
        flat = {cid: "/k8s.io/" + leaf.rsplit("/", 1)[1] for cid, leaf in valid.items()}
        self.assertEqual(report.check_parent_paths(cohort, "flat", flat), {"/k8s.io": 64})

        # The wrong snapshot still has 32 parents and exactly two children per parent.
        swapped = valid.copy()
        for position in (0, 1, 32, 33):
            cid = cohort["jobs"][position]["id"]
            swapped[cid] = f"{parents[1 - position % 32]}/{valid[cid].rsplit('/', 1)[1]}"
        with self.assertRaisesRegex(ValueError, "pair's named network"):
            report.check_parent_paths(cohort, "job", swapped)

    def test_only_a_labelled_native_request_can_enter_the_job_treatment(self):
        native = {"name": "native", "create_argv": ["run", "--label", report.LABEL_VALUE, "--cpus", "1"],
                  "docker_inspect": {"Config": {"Labels": {report.PARENT_LABEL: "1"}}, "HostConfig": {}}}
        peer = {"name": "peer", "create_argv": ["run", "--cpus", "1"],
                "docker_inspect": {"Config": {"Labels": {}}, "HostConfig": {}}}
        cohorts = {"A": {"jobs": [native]}, "B": {"jobs": [peer]}}
        plan = {"job_parent": "job"}
        with patch.object(report, "check_placement_inventory") as check:
            report.placement_view(cohorts, plan, "grouped")
            projected = check.call_args.args[0]
            self.assertEqual(projected["A"]["jobs"][0]["create_argv"], peer["create_argv"])
            self.assertIn(report.LABEL_VALUE, native["create_argv"])
            self.assertIs(projected["A"]["jobs"][0]["docker_inspect"], native["docker_inspect"])

        peer["create_argv"].extend(("--label", report.LABEL_VALUE))
        with self.assertRaisesRegex(ValueError, "placement|admission"):
            report.placement_view(cohorts, plan, "grouped")

    def test_build_overlap_includes_drain_and_separate_waves(self):
        build = {"jobs": 8, "revisions": 16, "test_passes": 128, "http_covered_ns": 1_500_000_000}
        wave = {"offered_requests": 96_000, "requests": 96_000, "per_client_requests": [3000] * 32,
                "build": build, "completed_after_first_build": 0, "first_build_end_margin_ns": 0}
        rows = [{"order": order, "A": wave.copy(), "B": wave.copy()} for order in ("AB", "BA", "BA", "AB")]
        run = {"rows": {"grouped": rows}}

        def go_rows(_folder, name):
            round_no = int(name.split("-")[1])
            return [{"started_unix_ns": 100 * round_no + 10, "stdout": f"end {100 * round_no + 20} 0"}]

        def single_http(_folder, name):
            start = 100 * int(name.split("-")[1]) + 1
            return [{"receipt": {"window": {"scheduled_unix_ns": start, "started_unix_ns": start,
                                           "finished_unix_ns": start + 1}}}]

        with patch.object(report, "read", side_effect=go_rows), patch.object(report.paced, "read_wire", side_effect=single_http):
            bounds = {"A": (0, 321), "B": (0, 321)}
            self.assertEqual(report.check_waves(Path("."), run, bounds), rows)
            with self.assertRaisesRegex(ValueError, "post-work snapshot arrived before"):
                report.check_waves(Path("."), run, {**bounds, "A": (0, 319)})
            with self.assertRaisesRegex(ValueError, "pre-work checks.*out of order"):
                report.check_waves(Path("."), run, {**bounds, "B": (1, 321)})
            rows[2]["A"]["completed_after_first_build"] = 1
            rows[2]["A"]["first_build_end_margin_ns"] = -1
            with self.assertRaisesRegex(ValueError, "overlap through HTTP drain"):
                report.check_waves(Path("."), run, bounds)

    def test_hidden_ancestor_quota_is_a_separate_treatment(self):
        parent = "/k8s.io/micropod-job-" + "a" * 64
        defaults = {"cgroup.type": "domain", "cgroup.subtree_control": "cpuset cpu memory pids",
                    "cgroup.events": "populated 1\nfrozen 0", "cpu.weight": "100", "cpu.max": "max 100000",
                    "memory.max": "max", "pids.max": "max", "cpuset.cpus.effective": "0-3"}
        job = defaults.copy()
        tree = {"groups": {"/": {"files": {**defaults, "cpu.max": "400000 100000", "memory.max": "4294967296"}},
                           "/k8s.io": {"files": defaults}, parent: {"files": job}},
                "nodes": {"/k8s.io": {"children": [parent.rsplit("/", 1)[1]]}}}

        result = report.check_ancestor_limits(tree, {parent: 2})
        self.assertEqual(result["parent_cpu_max"], "max 100000")
        job["cpu.max"] = "100000 100000"
        with self.assertRaisesRegex(ValueError, "weight or bandwidth changed"):
            report.check_ancestor_limits(tree, {parent: 2})


class FlatHoldoutTest(unittest.TestCase):
    def test_report_requires_fresh_matched_boots_and_counts_seed_medians(self):
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            paths = [root / f"flat-{seed}" for seed in report.SEED_ORDER["holdout"]]
            native = {path: f"native-{seed}" for seed, path in zip(report.SEED_ORDER["holdout"], paths, strict=True)}
            identity = lambda index, name: {"scope": root / f"scope-{index}", "native": name, "peer": "peer",
                                            "ids": set(range(128 * index, 128 * (index + 1))), "products": "same",
                                            "first": 1000 * index, "last": 1000 * index + 1}
            initial = [(root / f"initial-{i}", identity(i, f"initial-native-{i}")) for i in range(4)]
            hold = {p: identity(i, native[p]) for i, p in enumerate(paths, 4)}
            inputs = {key: key for key in holdout.MATCHED}
            common = {**dict.fromkeys(report.METRICS, 10), "offered_requests": 96_000, "requests": 96_000,
                      "jobs": 8, "revisions": 16, "test_passes": 128}
            discovery_better = {"metrics": {key: {"micropod": 9, "orbstack": 10} for key in report.WIN_METRICS}}
            initial_score = {**inputs, "by_seed": [{"seed": 250221, "within_mode": {"flat": discovery_better}}]}

            def replay(path, *, batch):
                self.assertEqual(batch, "holdout")
                seed = int(path.name.split("-")[1])
                a = {**common, "p95_us": 9, "build_makespan_s": 9 if seed == 250227 else 11}
                outcome = report.outcomes([common] * 4, [a] * 4, ("orbstack", "micropod"))
                return {**inputs, "seed": seed, "mode": "flat", "native_boot": native[path], "peer_boot": "peer",
                        "admission": {}, "within_boot": outcome,
                        "windows": [{"micropod": a, "orbstack": common} for _ in range(4)]}

            with patch.object(holdout, "initial_archives", return_value=initial), \
                    patch.object(holdout, "read", side_effect=lambda path, _: {"seed": int(path.name.split("-")[1])}), \
                    patch.object(holdout, "archive_identity", side_effect=lambda path, *_: hold[path]), \
                    patch.object(report, "replay", side_effect=replay) as raw:
                outcome = holdout.compare_flat_holdout(paths[::-1], initial_score)
                self.assertFalse(outcome["both_boot_medians_faster_on_each_holdout"])
                self.assertEqual(outcome["fresh_native_boots"], 2)
                self.assertEqual(outcome["build_jobs"], 128)
                self.assertEqual(outcome["pooled_windows"]["joint_wins"]["micropod"], 4)
                self.assertEqual(raw.call_count, 2)

                with self.assertRaisesRegex(ValueError, "changed protocol"):
                    holdout.compare_flat_holdout(paths, {**initial_score, "protocol_sha256": "other probe"})
                hold[paths[0]]["native"] = initial[0][1]["native"]
                raw.reset_mock()
                with self.assertRaisesRegex(ValueError, "reused a scope, native boot or container"):
                    holdout.compare_flat_holdout(paths, initial_score)
                raw.assert_not_called()


if __name__ == "__main__":
    unittest.main()
