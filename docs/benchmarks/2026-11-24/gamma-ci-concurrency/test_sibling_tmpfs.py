"""Validate compiler scratch receipts without mounting or starting a guest."""

from pathlib import Path
import subprocess
import unittest

import sibling_tmpfs as scratch


BOOT = "ebb45986-cc6d-4556-972d-06dec54b00dc"
WORK = Path("/private/tmp/mp-t-fixture/workspace")


def mount(id_, device, root, target, fs, source, options="rw", super_options="rw"):
    return f"mount {id_} 1 {device} {root} {target} {options} - {fs} {source} {super_options}\n"


def boot_readback(mode):
    rows = f"boot={BOOT}\nmode={mode}\n" + mount(1, "254:0", "/", "/", "ext4", "/dev/vda")
    return rows


def build_readback(mode, arm):
    rows, jobs = [], []
    for slot in scratch.SLOTS:
        cid = f"{slot:064x}"
        tmpfs = {"/tmp": scratch.TMP_OPTIONS} if mode == "tmpfs" and arm == "A" else {}
        jobs.append({"id": cid, "create_argv": scratch.flags(arm, mode, slot), "docker_inspect": {"HostConfig": {"Tmpfs": tmpfs}}})
        raw = (f"boot={BOOT}\npage_bytes={16384 if arm == 'A' else 4096}\nuid=0\ngid=0\nexec_owner=0:0\nexec={cid}\n"
               "goenv=off\ntmp=/tmp\ngo_tmp=/tmp\ngocache=/cache/build\ngomodcache=/cache/mod\ncache_inode=10:99\n"
               "tmp_mode=1777\ntmp_capacity_kib=131072\nmemory_peak_bytes=4096\noom=0\noom_kill=0\n")
        raw += mount(81, f"0:{slot + 31}", "/", "/", "overlay", "overlay")
        raw += mount(91, "254:0", "/volumes/my-go", "/cache", "ext4" if arm == "A" else "btrfs", "/dev/vda")
        if mode == "tmpfs" and arm == "A":
            raw += mount(101, f"0:{slot + 100}", "/", "/tmp", "tmpfs", "tmpfs", "rw,nosuid,nodev,relatime", "rw,size=131072k")
        rows.append({"id": cid, "readback": raw})
    return rows, {"jobs": [{} for _ in scratch.SLOTS] + jobs}


class BuildScratchTest(unittest.TestCase):
    def test_linux_receipt_requires_each_selected_test(self):
        output = "\n".join(f"--- PASS: {name} (0.00s)" for name in scratch.TMPFS_TESTS) + "\nPASS\n"
        scratch.check_linux_tests(output, scratch.TMPFS_TESTS)
        with self.assertRaisesRegex(ValueError, "TestDockerStopKeepsOriginalGeneration"):
            scratch.check_linux_tests(output, scratch.RUNNER_TESTS)
        with self.assertRaisesRegex(ValueError, "did not pass"):
            scratch.check_linux_tests(output.replace("\nPASS\n", "\nFAIL\n"), scratch.TMPFS_TESTS)

    def test_boot_and_probe_shell_syntax(self):
        for script in (scratch.BOOT_HOOK, scratch.PROBE, scratch.RESTART_PROBE):
            subprocess.run(["/bin/sh", "-n"], input=script, text=True, check=True)

    def test_both_policies_keep_one_cache_per_engine(self):
        for mode in scratch.MODES:
            boot, mounts = scratch.check_boot(boot_readback(mode), WORK, mode, f"boot={BOOT}\n")
            for arm in "AB":
                with self.subTest(mode=mode, arm=arm):
                    rows, inventory = build_readback(mode, arm)
                    proofs = scratch.check_jobs(rows, inventory, WORK, arm, mode, boot, mounts)
                    self.assertEqual(len(proofs), 8)
                    self.assertEqual({row["cache_inode"] for row in proofs}, {"10:99"})
                    self.assertEqual(proofs[0]["scratch_mount"], 101 if (mode, arm) == ("tmpfs", "A") else 81)

    def test_tmpfs_cannot_alias_another_build_or_remove_exec(self):
        boot, mounts = scratch.check_boot(boot_readback("tmpfs"), WORK, "tmpfs", f"boot={BOOT}\n")
        for source, dest, message in (("0:100", "0:101", "share a scratch"),
                                      ("rw,nosuid,nodev,relatime", "rw,nosuid,nodev,noexec", "executable scratch"),
                                      ("tmp_capacity_kib=131072", "tmp_capacity_kib=32768", "scratch capacity"),
                                      ("exec_owner=0:0", "exec_owner=99:0", "execution, ownership")):
            with self.subTest(message=message):
                rows, inventory = build_readback("tmpfs", "A")
                rows[0]["readback"] = rows[0]["readback"].replace(source, dest)
                with self.assertRaisesRegex(ValueError, message):
                    scratch.check_jobs(rows, inventory, WORK, "A", "tmpfs", boot, mounts)

    def test_inspect_and_cli_must_agree_with_mountinfo(self):
        boot, mounts = scratch.check_boot(boot_readback("tmpfs"), WORK, "tmpfs", f"boot={BOOT}\n")
        rows, inv = build_readback("tmpfs", "A")
        inv["jobs"][8]["docker_inspect"]["HostConfig"].clear()
        with self.assertRaisesRegex(ValueError, "inspect lost"):
            scratch.check_jobs(rows, inv, WORK, "A", "tmpfs", boot, mounts)


if __name__ == "__main__":
    unittest.main()
