"""Exercise the dedicated slice diagnostic's qualification and matched outcomes."""

import json
import plistlib
import unittest
from copy import deepcopy
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import sibling_slice_350_results as report


def save(folder, name, value):
    (folder / name).write_text(json.dumps(value))


class SliceDiagnosticTest(unittest.TestCase):
    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name).resolve()
        self.product = {
            "host_sha256": "a" * 64, "new_guest_sha256": "b" * 64, "new_bootstrap_sha256": "c" * 64,
            "base_revision": "revision", "entitlements": {"com.apple.security.virtualization": True},
            "current_product": str(root / "signed/product.json"),
        }
        self.package = {
            "worker_executable_sha256": self.product["host_sha256"],
            "guest_runner_sha256": self.product["new_guest_sha256"],
            "guest_start_sha256": self.product["new_bootstrap_sha256"],
            "base_revision": self.product["base_revision"], "entitlements": self.product["entitlements"],
            "arena": str(root / "signed"),
        }
        self.runs = {}
        with report.fixture.scheduler_profiles():
            hooks = report.fair_hooks()
        for seed, order in report.SEED_ORDER.items():
            for position, us in enumerate(order):
                folder = root / f"{seed}-{us}"
                scope = root / f"work-{seed}-{us}"
                (folder / "a").mkdir(parents=True)
                (folder / "slice-350-driver.py").write_text("# Test archive\n")
                (folder / "fair-scheduler.sh").write_bytes(hooks[us])
                plan = {
                    **report.WORKLOAD, "scope": str(scope), "seed": seed, "slice_350_target_us": us,
                    "guest_fair": f"base-{us}us", "pages": {"kernel_page_kib": 16, "kernel_ipvlan": True},
                    "slice_350_driver_sha256": report.terminal.digest(folder / "slice-350-driver.py"),
                }
                save(folder, "plan.json", plan)
                save(folder, "worker-build.json", self.package)
                save(folder, "a/worker.json", {"workspace": str(scope / "workspace"), "worker": folder.name, "cpus": 4})
                save(folder, "grouped-inventory.json", {"A": {"test": "measured clients"}, "B": {}})
                env = {key: str(scope / path) for key, path in report.BOOT_PATHS.items()}
                env["MICROPOD_SANDBOX_KERNEL_ARGS"] = report.BOOT_ARGS
                (folder / "a/job.plist").write_bytes(plistlib.dumps({"EnvironmentVariables": env, "ProcessType": "Standard"}))
                boot = f"00000000-0000-0000-0000-{seed * 1000 + us:012x}"
                (folder / "a/guest-facts.txt").write_text(
                    f"boot={boot}\nrelease=test\nmachine=aarch64\ncmdline=console=hvc0 {report.BOOT_ARGS}\n"
                    "config_sha256=test\n/sys/fs/cgroup/cgroup.controllers\ncpuset cpu io memory hugetlb pids\n"
                    "/proc/self/cgroup\n0::/init\n"
                    "ethtool -k eth0\ngeneric-receive-offload: on\nethtool -S eth0\n     tx_kicks: 2\n"
                    "eth0/rx_bytes 86\n/proc/interrupts\n 11: 1 2 3 4 arch_timer\n")
                (folder / "go-scratch-boot.txt").write_text(f"boot={boot}\nmode=tmpfs\n"
                                                           "mount 51 38 254:16 / / rw,relatime - ext4 /dev/vdb rw\n")

                features = ["HRTICK", "NEXT_BUDDY", "PICK_BUDDY"]
                worker = {"worker": self.product["host_sha256"], "scheduler": {
                    "setting": f"base-{us}us", "base_slice_ns": us * 1000, "before": features, "after": features,
                    "clocksource": "arch_sys_counter",
                }}
                rows = []
                for i, engine_order in enumerate(("AB", "BA", "BA", "AB")):
                    wave = {
                        "scheduled_unix_ns": (seed + position) * 10 + i,
                        "offered_requests": 96_000, "requests": 96_000, "completed_after_first_build": 0,
                        "first_build_end_margin_ns": 1_200_000_000, "timer_slack_ns": [50_000],
                        "build": {"products": [f"verified output {i}"]}, **dict.fromkeys(report.METRICS, 3),
                    }
                    if us == 250:
                        a = {"p95_us": 2, "build_makespan_s": 4}
                    elif seed == 250191:
                        # The medians both win. The wins come from disjoint windows.
                        a = {"p95_us": 1 if i < 2 else 4, "build_makespan_s": 4 if i < 2 else 1}
                    else:
                        a = {"p95_us": 2, "build_makespan_s": 2}
                    rows.append({"order": engine_order, "A": {**wave, **a}, "B": wave})
                self.runs[folder] = {
                    "plan": plan, "boot": boot, "peer_boot": "warm peer", "worker": worker,
                    "images": {"build": "pinned"}, "placements": deepcopy(report.PLACEMENT), "rows": {"grouped": rows},
                }

        source_read = report.read
        self.enterContext(patch.object(report, "read", side_effect=lambda path, filename:
                                      self.product if filename == report.PRODUCT_RECEIPT else source_read(path, filename)))
        def workload_readback(folder, plan, inventory):
            # This evidence is independent of the mocked raw scheduler result.
            boot = (folder / "a/guest-facts.txt").read_text().splitlines()[0].removeprefix("boot=")
            return {"boot": boot, "effective_ns": plan["slice_350_target_us"] * 1000,
                    "features": ["HRTICK", "NEXT_BUDDY", "PICK_BUDDY"]}

        self.after = self.enterContext(patch.object(report.fixture, "verify_after_work", side_effect=workload_readback))
        self.replay = self.enterContext(patch.object(report.paced, "replay", side_effect=self.runs.__getitem__))
        self.paths = list(self.runs)

    def test_same_window_wins_are_distinct_from_the_boot_median_gate(self):
        result = report.compare(self.paths[::-1])
        self.assertTrue(result["promotion_gate_met"])
        self.assertEqual(result["offered_requests"], 3_072_000)
        self.assertEqual(result["minimum_first_build_end_margin_ns"], 1_200_000_000)
        self.assertEqual(result["within_level"]["350"]["same_window_wins"],
                         {"orbstack": 0, "micropod": 4, "split_or_tied": 4})
        first, second = result["by_seed"]
        self.assertEqual(first["within_level"]["350"]["same_window_wins"]["micropod"], 0)
        self.assertTrue(first["micropod_won_both_350us_boot_medians"])
        self.assertEqual(second["treatment_order_us"], [350, 250])
        self.assertCountEqual([call.args[0] for call in self.replay.call_args_list], self.paths)
        self.assertEqual(self.after.call_count, 4)

        change = self.runs[self.paths[-2]]["rows"]["grouped"]
        for wave in change:
            wave["A"]["build_makespan_s"] = 3
        self.assertFalse(report.compare(self.paths)["promotion_gate_met"])

    def test_rejects_another_launch_setting_or_changed_bootstrap_before_replay(self):
        path = self.paths[1]
        plist = path / "a/job.plist"
        original = plist.read_bytes()
        job = plistlib.loads(original)
        job["EnvironmentVariables"]["MICROPOD_CI_PUBLISHED_RPS"] = "none"
        plist.write_bytes(plistlib.dumps(job))
        with self.assertRaisesRegex(ValueError, "unmatched diagnostic worker"):
            report.compare(self.paths)
        plist.write_bytes(original)
        save(path, "worker-build.json", {**self.package, "guest_start_sha256": "other"})
        with self.assertRaisesRegex(ValueError, "signed holdout product"):
            report.compare(self.paths)
        self.replay.assert_not_called()

    def test_expected_nic_and_interrupt_counters_vary_but_a_static_option_cannot(self):
        facts = self.paths[1] / "a/guest-facts.txt"
        counters = (facts.read_text().replace("tx_kicks: 2", "tx_kicks: 3").replace("rx_bytes 86", "rx_bytes 176")
                    .replace("11: 1 2 3 4 arch_timer", "11: 1 7 3 4 arch_timer"))
        facts.write_text(counters)
        self.assertTrue(report.compare(self.paths)["promotion_gate_met"])
        self.replay.reset_mock()
        facts.write_text(counters.replace("generic-receive-offload: on", "generic-receive-offload: off"))
        with self.assertRaisesRegex(ValueError, "unmatched diagnostic worker"):
            report.compare(self.paths)
        self.replay.assert_not_called()

    def test_rejects_wrong_effective_slice_placement_or_partial_build_overlap(self):
        path = self.paths[1]
        original = self.runs[path]
        for field, message in (("slice", "effective diagnostic scheduler"),
                               ("placement", "fixed CPU placement"),
                               ("overlap", "build overlap"),
                               ("timer slack", "timer slack changed")):
            with self.subTest(field=field):
                run = self.runs[path] = deepcopy(original)
                if field == "slice":
                    run["worker"]["scheduler"]["base_slice_ns"] = 250_000
                elif field == "placement":
                    run["placements"]["grouped"]["groups"]["job-01"] = "2"
                elif field == "overlap":
                    run["rows"]["grouped"][0]["A"]["completed_after_first_build"] = 1
                else:
                    run["rows"]["grouped"][0]["A"]["timer_slack_ns"] = [50_001]
                with self.assertRaisesRegex(ValueError, message):
                    report.compare(self.paths)

    def test_rejects_boot_order_and_requires_post_work_validation(self):
        path = self.paths[1]
        self.runs[path]["rows"]["grouped"][0]["A"]["scheduled_unix_ns"] -= 11
        with self.assertRaisesRegex(ValueError, "treatment order"):
            report.compare(self.paths)

        self.after.side_effect = ValueError("post-work slice changed")
        self.replay.reset_mock()
        with self.assertRaisesRegex(ValueError, "post-work slice changed"):
            report.compare(self.paths)
        self.replay.assert_not_called()


if __name__ == "__main__":
    unittest.main()
