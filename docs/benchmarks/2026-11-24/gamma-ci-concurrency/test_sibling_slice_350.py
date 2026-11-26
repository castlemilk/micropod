import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import sibling_sched
import sibling_slice_350 as fixture


BOOT = "639003cb-daf8-4022-8738-e34d1f42810b"
FEATURES = "HRTICK NEXT_BUDDY PICK_BUDDY"


class SliceFixtureTest(unittest.TestCase):
    def test_profile_scope_and_workload(self):
        original = sibling_sched.FEATURES.copy()
        with fixture.scheduler_profiles():
            self.assertEqual(sibling_sched.FEATURES["base-350us"], (None, 350000))
            self.assertEqual(sibling_sched.FEATURES["base-250us"], (None, 250000))
        self.assertEqual(sibling_sched.FEATURES, original)
        for target in fixture.TARGETS:
            p = Path(".")
            args = SimpleNamespace(product=p, page_kernel_pair=p, ipvlan_kernel=p, quiet_source=p, image_archive=None,
                                   seed=250191, target_us=target)
            plan = fixture.workload(args)
            self.assertEqual((plan.worker_scheduler, plan.guest_fair, plan.rounds),
                             ("hrtick-250us", f"base-{target}us", 4))
            self.assertEqual((plan.pairs, plan.builders, plan.build_scratch, plan.slice_us), (32, 8, "tmpfs", None))

    def test_guard_fails_before_work_on_wrong_live_slice(self):
        for target in fixture.TARGETS:
            with tempfile.TemporaryDirectory() as path:
                work = Path(path)
                scheduler = work / "fair-scheduler"
                scheduler.mkdir()
                fake_debugfs = work / "debugfs"
                fake_debugfs.mkdir()
                (work / "boot").write_text(BOOT + "\n")
                (scheduler / "base-before").write_text("250000\n")
                (scheduler / "base-slice").write_text(f"{target * 1000}\n")
                for name in ("before", "after"):
                    (scheduler / name).write_text(FEATURES + "\n")
                (fake_debugfs / "features").write_text(FEATURES + "\n")
                guard = fixture.before_work_hook(target).replace("/sys/kernel/debug/sched", '"$MOCK_SCHED"').replace(
                    "/proc/sys/kernel/random/boot_id", '"$MOCK_BOOT"')
                script = """id() { printf '0\\n'; }
mount() { printf '%s\\n' "$*" >> "$MICROPOD_ENGINE_WORKSPACE/mounts"; }
""" + guard
                env = {**os.environ, "MICROPOD_ENGINE_WORKSPACE": path, "MOCK_SCHED": str(fake_debugfs),
                       "MOCK_BOOT": str(work / "boot")}
                mount_log = work / "mounts"
                (fake_debugfs / "base_slice_ns").write_text("2100000\n")
                rejected = subprocess.run(["/bin/sh", "-eu", "-c", script], capture_output=True, env=env)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertFalse(mount_log.exists())
                (fake_debugfs / "base_slice_ns").write_text(f"{target * 1000}\n")
                subprocess.run(["/bin/sh", "-eu", "-c", script], capture_output=True, env=env, check=True)
                self.assertEqual(len(mount_log.read_text().splitlines()), 4)
                self.assertEqual(mount_log.read_text().count("-o remount,bind,ro "), 2)
                self.assertEqual((scheduler / fixture.BEFORE).read_text(),
                                 f"boot={BOOT}\ninitial_ns=250000\neffective_ns={target * 1000}\n")

    def test_bootstrap_hook_precedes_private_recovery_and_services(self):
        lines = ('if sh "$tools/runner/fixture-facts.sh" > "$target"; then',
                 '"$tools/runner/bin/job" recover', '"$tools/runner/bin/job" engine &', '"$tools/service" serve &')
        fixture.check_start_order("\n".join(lines))
        with self.assertRaises(ValueError):
            fixture.check_start_order("\n".join((lines[1], lines[0], *lines[2:])))
        with self.assertRaises(ValueError):
            fixture.check_start_order("\n".join(lines[:3]))

    def test_post_work_uses_real_read_only_scheduler_mounts(self):
        raw = f"""boot={BOOT}
effective_ns=350000
features={FEATURES}
mount 12 2 0:81 /sched/base_slice_ns /slice-350-base ro,relatime - debugfs none rw
mount 13 2 0:81 /sched/features /slice-350-features ro,relatime - debugfs none rw
"""
        self.assertEqual(fixture.post_readback(raw),
                         {"boot": BOOT, "effective_ns": 350000, "features": sorted(FEATURES.split())})
        for bad in (raw.replace("ro,relatime", "rw,relatime"), raw.replace("debugfs", "ext4"),
                    raw.replace("/sched/features /slice-350-features", "/features /slice-350-features")):
            with self.assertRaises(ValueError):
                fixture.post_readback(bad)

    def test_fixed_mapping_requires_every_group(self):
        groups = {f"job-{slot:02d}": str(slot % 4) for slot in range(32)}
        fixture.check_group_mapping({"placement": {"groups": groups}})
        groups["job-00"], groups["job-04"] = "1", "2"
        with self.assertRaises(ValueError):
            fixture.check_group_mapping({"placement": {"groups": groups}})

    def test_boot_probe_runs_in_scratch_image_without_shell_or_cat(self):
        job = {"id": "client-a"}

        def scratch_exec(*args):
            self.assertEqual(args, ("exec", "client-a", "/mpcheck/netbench", "-net-info"))
            return json.dumps({fixture.BOOT_ID_PATH: BOOT, "/proc/net/netstat": "unneeded"})

        self.assertEqual(fixture.client_boot(SimpleNamespace(cmd=scratch_exec), job), {"id": "client-a", "boot": BOOT})
        with self.assertRaises(ValueError):
            fixture.client_boot(SimpleNamespace(cmd=lambda *args: "{}"), job)


if __name__ == "__main__":
    unittest.main()
