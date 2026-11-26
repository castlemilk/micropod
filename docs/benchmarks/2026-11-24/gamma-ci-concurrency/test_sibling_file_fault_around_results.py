"""Reject plausible but unqualified fault-around and build resource records."""

import json
from pathlib import Path
import plistlib
from tempfile import TemporaryDirectory
import unittest

import sibling_file_fault_around_results as report


class FileFaultAroundReplayTest(unittest.TestCase):
    def test_selector_requires_one_numeric_write_between_readbacks(self):
        before, after = 'before=$(cat "$knob")', 'effective=$(cat "$knob")'
        write = report.NUMERIC_WRITE
        report.check_numeric_write(f"{before}\n{write}\n{after}")
        newline_format = write.replace("%s", r"%s\n")
        for fragment in (f"{before}\n{newline_format}\n{after}", f"{before}\n{after}\n{write}",
                         f"{before}\n{write}\n{write}\n{after}"):
            with self.subTest(fragment=fragment), self.assertRaisesRegex(ValueError, "one numeric write"):
                report.check_numeric_write(fragment)

    def test_launch_and_post_work_readback_must_agree_on_one_private_switch(self):
        def plist(args):
            return plistlib.dumps({"EnvironmentVariables": {report.KERNEL_ARGS: args, "OTHER": "same"}})

        value = report.VALUES[1]
        wanted = report.TOKEN + str(value)
        args = f"{report.signed.BOOT_ARGS} {wanted}"
        self.assertEqual(report.checked_job_plist(plist(args), value)["EnvironmentVariables"],
                         {report.KERNEL_ARGS: report.signed.BOOT_ARGS, "OTHER": "same"})
        for unexpected in (report.signed.BOOT_ARGS, f"{args} {wanted}", args.replace(str(value), "65536")):
            with self.subTest(unexpected=unexpected), self.assertRaisesRegex(ValueError, "wrong or duplicate"):
                report.checked_job_plist(plist(unexpected), value)

        boot = "00000000-0000-0000-0000-000000000001"
        initial = (f"schema={report.READBACK_SCHEMA}\nboot_id={boot}\npage_size_bytes=16384\n"
                   f"before_bytes=65536\neffective_bytes={value}\n")
        final = initial.replace("before_bytes=65536\n", "")
        self.assertEqual(report.kernel_readback(initial, boot, value, initial=True)["before_bytes"], "65536")
        self.assertEqual(report.kernel_readback(final, boot, value, initial=False)["effective_bytes"], str(value))
        for unexpected in (final.replace(str(value), "65536"), final.replace(boot, "other"), final + f"effective_bytes={value}\n"):
            with self.subTest(unexpected=unexpected), self.assertRaisesRegex(ValueError, "wrong effective"):
                report.kernel_readback(unexpected, boot, value, initial=False)

    def test_build_child_must_span_drain_and_wait_for_other_processes_before_reporting(self):
        with TemporaryDirectory() as directory:
            folder = Path(directory)
            tag, boot = "grouped-0-all-A", "native-boot"
            gate, last = 100_000_000, 1_680_000_000
            jobs, timed, children = [], [], []
            for slot in range(report.paced.BUILDERS):
                cid, name, revision = f"{slot:064x}", f"native-client-{slot}", f"sibling-0-{slot}"
                start, end = 65_000_000 - slot, last + 1_000_000 + slot
                jobs.append({"id": cid, "name": name, "affinity": {"pid": 11}})
                timed.append({"id": cid, "started_unix_ns": start, "revision": revision, "stdout": f"end {end} 0"})
                usage = {key: slot + 1 for key in report.USAGE_COUNTERS}
                usage.update({"tag": tag, "slot": slot, "revision": revision, "boot": boot, "container": name,
                              "argv": ["/bin/sh", "/mpcheck/file-fault-around-build-pair.sh", revision, "0"],
                              "cgroup": "0::/", "child_pid": 20, "wait_status": 0, "exit_code": 0,
                              "started_unix_ns": start + 1, "child_started_unix_ns": start + 10,
                              "finished_unix_ns": end + 10, "elapsed_ns": end + 9 - start,
                              "publish_started_unix_ns": 6_000_000_000})
                children.append({"id": cid, "argv": report.evidence.build_argv(tag, slot, cid), "usage": usage})
            context = {"inventory": {"A": {"jobs": [{}] * report.paced.PAIRS + jobs}}, "boots": {"A": boot}}
            wave = {"scheduled_unix_ns": gate, "last_completion_offset_ns": last - gate}
            (folder / f"{tag}-go.json").write_text(json.dumps(timed))
            sidecar = folder / f"file-fault-around-{tag}-builds.json"
            sidecar.write_text(json.dumps(children))
            scored = report.child_resources(folder, 0, "A", wave, context)
            self.assertEqual(scored["totals"]["minor_faults"], 36)
            self.assertEqual(scored["totals"]["max_rss_kib"], 8)

            first = children[0]["usage"]
            first["publish_started_unix_ns"] = first["finished_unix_ns"]
            sidecar.write_text(json.dumps(children))
            with self.assertRaisesRegex(ValueError, "sidecar could perturb"):
                report.child_resources(folder, 0, "A", wave, context)
            first["publish_started_unix_ns"] = 6_000_000_000
            first["child_started_unix_ns"] = gate
            sidecar.write_text(json.dumps(children))
            with self.assertRaisesRegex(ValueError, "did not span"):
                report.child_resources(folder, 0, "A", wave, context)
            first["child_started_unix_ns"] = first["started_unix_ns"] + 9
            first["boot"] = "peer-boot"
            sidecar.write_text(json.dumps(children))
            with self.assertRaisesRegex(ValueError, "build identity"):
                report.child_resources(folder, 0, "A", wave, context)


if __name__ == "__main__":
    unittest.main()
