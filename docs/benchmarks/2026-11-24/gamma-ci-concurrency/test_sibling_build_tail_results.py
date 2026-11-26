import unittest

import sibling_build_tail_results as tail


def rows(intervals):
    epoch = 1_795_572_412_031_892_090
    return [{"slot": i, "cpu": str(i % 4), "start": epoch + start, "end": epoch + end,
             "elapsed_ns": end - start, "cgroup_cpu_ns": 1000, "revisions": [f"artifact-{i}"]}
            for i, (start, end) in enumerate(intervals)]


class BuildTailTests(unittest.TestCase):
    def test_last_finisher_and_slowest_job_can_differ(self):
        window = tail.pair({"A": rows([(0, 7), (1, 9), (0, 12), (13, 16)]),
                            "B": rows([(0, 8), (0, 8), (0, 8), (0, 9)])})
        native = window["engines"]["A"]
        self.assertEqual(native["median_job_elapsed_ns"], 7.5)
        self.assertEqual(native["slowest_job_elapsed_ns"], 12)
        self.assertEqual(native["last_finisher_slot"], 3)
        self.assertEqual(native["finish_spread_ns"], 9)
        self.assertEqual(window["slots"][3]["start_offset_ns"], {"A": 13, "B": 0})
        additive = tail.summarize([window])["additive_gap_sum_ns"]
        self.assertEqual(additive, {"makespan_ns": 7, "median_job_elapsed_ns": -0.5,
                                    "last_finisher_excess_ns": -5.5, "last_finisher_start_offset_ns": 13})

    def test_different_cpu_or_outputs_rejects_a_pair(self):
        native = rows([(0, 4), (2, 6)])
        for field, replacement in (("slot", 2), ("cpu", "3"), ("revisions", ["another-artifact"])):
            with self.subTest(field=field):
                peer = rows([(0, 4), (2, 6)])
                peer[1][field] = replacement
                with self.assertRaisesRegex(ValueError, "different slots, CPU placements, or outputs"):
                    tail.pair({"A": native, "B": peer})

    def test_two_late_builds_and_finish_spread_use_guest_vcpus(self):
        builds = rows([(0, end) for end in (900, 1001, 902, 903, 908, 1011, 910, 911)])
        window = tail.pair({"A": builds, "B": builds})
        native = window["engines"]["A"]
        self.assertEqual(native["last_finisher_slot"], 5)
        self.assertEqual(native["penultimate_finisher_slot"], 1)
        self.assertEqual(native["last_finisher_vcpu"], "1")
        self.assertTrue(native["last_two_same_vcpu"])
        self.assertEqual(native["last_vs_penultimate_finish_ns"], 10)
        self.assertEqual(native["penultimate_finish_above_median_ns"], 92)
        self.assertEqual(native["median_within_vcpu_finish_spread_ns"], 8)
        self.assertEqual(native["between_vcpu_mean_finish_spread_ns"], 102)
        self.assertEqual(tail.summarize([window])["late_vcpu"]["A"],
                         {"last_finisher_vcpu_counts": {"0": 0, "1": 1, "2": 0, "3": 0},
                          "last_two_same_vcpu_windows": 1})

    def test_broad_builder_cgroup_requires_the_new_study_and_a_home_resident(self):
        def job(arm, pos):
            name = f"{arm}-{pos}"
            group = f"job-{pos % 32:02d}"
            home = str(pos % 4)
            mask = "0-3" if 32 <= pos < 40 else home
            inspect = {"Id": name, "Name": "/" + name, "Config": {"Labels": {"group": group}},
                       "HostConfig": {"CpusetCpus": mask}}
            return {"id": name, "name": name, "cpu_group": group, "home_cpu": home, "mask": mask,
                    "requested_cpuset": mask, "placement_source": "explicit-build-cpuset",
                    "docker_inspect": inspect, "cgroup": {"cpuset.cpus.effective": mask, "cpu.max": "100000 100000"},
                    "affinity": {"pid": 1, "threads": [{"tid": 1, "cpus_allowed_list": home}]}}

        inventory = {arm: {"jobs": [job(arm, pos) for pos in range(64)]} for arm in "AB"}
        with self.assertRaisesRegex(ValueError, "split CPU group"):
            tail.check_placement(inventory, "group")
        clients = tail.check_placement(inventory, "group", compiler_affinity="pool")
        self.assertEqual(clients["A"][1]["home_cpu"], "1")
        self.assertEqual(clients["A"][1]["mask"], "0-3")
        clients["A"][1]["affinity"]["threads"][0]["cpus_allowed_list"] = "0-3"
        with self.assertRaisesRegex(ValueError, "unexpected CPU affinity"):
            tail.check_placement(inventory, "group", compiler_affinity="pool")


if __name__ == "__main__":
    unittest.main()
