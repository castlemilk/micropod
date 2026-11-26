import plistlib
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

import sibling_ttwu_queue as queue


BOOT = "b522e071-a21e-4312-8ebe-b442df68ab52"
INITIAL = ["HRTICK", "NEXT_BUDDY", "PICK_BUDDY", "PREEMPT_SHORT", "TTWU_QUEUE"]


class TTWUQueueTest(unittest.TestCase):
    def stage(self, folder, mode):
        fair = folder / "fair-scheduler"
        fair.mkdir()
        (folder / "a").mkdir()
        effective = [queue.MODES[mode] if name == "TTWU_QUEUE" else name for name in INITIAL]
        args = " ".join(queue.launch_args(mode))
        cmdline = args + " root=/dev/vda"
        (folder / "a/job.plist").write_bytes(plistlib.dumps({"EnvironmentVariables": {queue.fault.KERNEL_ENV: args}}))
        (folder / "a/guest-facts.txt").write_text(f"boot={BOOT}\ncmdline={cmdline}\n")
        for name, value in {"before": " ".join(effective), "after": " ".join(effective), "base-before": "250000",
                            "base-slice": "250000", "cmdline": cmdline, "clocksource": "arch_sys_counter"}.items():
            (fair / name).write_text(value + "\n")
        queue.terminal.save(folder / "fair-scheduler.json", queue.sibling_sched.read(fair, "inherit", "hrtick-250us", True))
        common = f"schema={queue.SCHEMA}\nboot_id={BOOT}\neffective_base_slice_ns=250000\nfile_fault_around_bytes=65536\n"
        common += f"effective_features={' '.join(effective)}\n"
        (folder / queue.BOOT).write_text(common + f"selection={mode}\ninitial_base_slice_ns=250000\n"
                                            f"initial_features={' '.join(INITIAL)}\n")
        (folder / queue.FINAL).write_text(common)

    def test_stock_and_off_prove_the_single_feature_transition(self):
        for mode in queue.MODES:
            with self.subTest(mode=mode), TemporaryDirectory() as tmp:
                folder = Path(tmp)
                self.stage(folder, mode)
                queue.check_launch(folder, 65536, mode)
                record = queue.check_features(folder, mode, BOOT, finished=True)
                self.assertIn("TTWU_QUEUE", record["initial"])
                self.assertIn(queue.MODES[mode], record["features"])
                final = folder / queue.FINAL
                final.write_text(final.read_text().replace("PREEMPT_SHORT", "NO_PREEMPT_SHORT"))
                with self.assertRaisesRegex(ValueError, "changed during the workload"):
                    queue.check_features(folder, mode, BOOT, finished=True)

    def test_reject_preselected_off_and_wrong_window(self):
        with TemporaryDirectory() as tmp:
            folder = Path(tmp)
            self.stage(folder, "off")
            boot = folder / queue.BOOT
            original = boot.read_text()
            boot.write_text(original.replace("PREEMPT_SHORT TTWU_QUEUE", "PREEMPT_SHORT NO_TTWU_QUEUE"))
            with self.assertRaisesRegex(ValueError, "boot transition"):
                queue.check_features(folder, "off", BOOT, finished=False)
            boot.write_text(original.replace("65536", "1048576"))
            with self.assertRaisesRegex(ValueError, "file-fault window"):
                queue.check_features(folder, "off", BOOT, finished=False)

    def test_guest_hooks_parse_and_publish_post_work_before_completion(self):
        observer = queue.post_hook()
        for script in (queue.BOOT_SOURCE, queue.FINAL_SOURCE, observer):
            subprocess.run(["/bin/sh", "-n"], input=script, text=True, check=True)
        self.assertIn('printf \'%s\' "$selected" > "$sched/features"', queue.BOOT_SOURCE)
        self.assertLess(observer.index("file-fault-around-read.sh"), observer.index(queue.FINAL_SCRIPT))
        self.assertLess(observer.index(queue.FINAL_SCRIPT), observer.index("output-status.tmp"))


if __name__ == "__main__":
    unittest.main()
