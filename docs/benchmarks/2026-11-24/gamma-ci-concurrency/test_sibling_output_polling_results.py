"""Require the pinned runner build and reject drift in the crossover."""

from pathlib import Path
import unittest

import sibling_output_polling_results as report


class OutputPollingReplayTest(unittest.TestCase):
    def test_only_a_blocker_free_post_work_host_sample_can_be_unpaired(self):
        ids = {f"peer-{slot}" for slot in range(64)}
        stamp = lambda second: f"2026-11-25T06:55:{second:02d}Z"
        moment = lambda second: report.docker_time_ns(stamp(second))
        host = [{"utc": stamp(second), "blockers": [], "observed": []} for second in (10, 22, 24, 26)]
        peer = [{"time": stamp(second), "running": sorted(ids) if second != 25 else []} for second in (11, 23, 25)]
        marks = (moment(12), moment(20), moment(21))
        obtained = report.reconcile_retirement_sample(host, peer, ids, *marks)
        self.assertEqual(obtained["samples"], 3)
        self.assertEqual(obtained["post_work_host_sample"], host[-1])
        self.assertEqual(obtained["last_paired_peer_sample"], peer[-1])
        self.assertEqual(obtained["last_utc"], stamp(26))

        with self.assertRaisesRegex(ValueError, "must precede"):
            report.reconcile_retirement_sample(host, peer, ids, moment(12), moment(24), moment(25))
        with self.assertRaisesRegex(ValueError, "must precede"):
            report.reconcile_retirement_sample(host, [peer[0], {**peer[1], "time": stamp(24)}, peer[-1]], ids, *marks)
        with self.assertRaisesRegex(ValueError, "verified empty peer"):
            report.reconcile_retirement_sample(host, [*peer[:-1], {**peer[-1], "running": ["peer-1"]}], ids, *marks)
        with self.assertRaisesRegex(ValueError, "one blocker-free"):
            report.reconcile_retirement_sample([*host[:-1], {**host[-1], "blockers": ["foreign"]}], peer, ids, *marks)
        with self.assertRaisesRegex(ValueError, "one blocker-free"):
            report.reconcile_retirement_sample([*host, {**host[-1], "utc": stamp(27)}], peer, ids, *marks)

    def test_requires_actual_pass_for_each_exit_repair_subcase(self):
        expected = sorted(report.TEST_ROOTS | report.TEST_SUBCASES)
        raw = "\n".join([*(f"=== RUN   {name}" for name in expected),
                         *(f"    --- PASS: {name} (0.01s)" for name in expected), "PASS"])
        self.assertEqual(report.check_test_log(raw), expected)
        broken = raw.replace("    --- PASS: TestCRIFollowWaitRechecksUncommittedExit/Unavailable (0.01s)\n", "")
        with self.assertRaisesRegex(ValueError, "verified CRI output root or exit-repair subtest"):
            report.check_test_log(broken)

    def test_dependency_changes_are_exact_insertions(self):
        previous = "module guest\n\ngo 1.27\nrequire old v1.0.0\n"
        added = "\tpinned v1.1.1 // indirect\n"
        report.check_inserted_lines(previous, previous + added, [added])
        for changed in (previous + added + added, previous.replace("go 1.27", "go 1.26") + added,
                        previous + added.replace("1.1.1", "1.1.0")):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                report.check_inserted_lines(previous, changed, [added])

    def test_build_command_cannot_add_an_unmatched_tag(self):
        product = report.products
        tool = {"path": "/fixed/go", "environment": product.ENV, "go_flags": "-trimpath"}
        parent = {"base_revision": "sealed"}
        combined = {"previous_product_sha256": "hash", "toolchain": tool}
        identity = {"parent": "hash", "mode": "stock", "changed": {}, "toolchain": tool,
                    "packager": report.terminal.digest(Path(product.__file__))}
        scope = product.BASE / ("ci-published-link-" + product.hashed(product.encode(identity))[:16])
        stage = product.BASE / "output-polling-private" / "product"
        info = [product.GO_VERSION, "build\tGOOS=linux", "build\tGOARCH=arm64", "build\tCGO_ENABLED=0",
                "build\tvcs.revision=sealed", "build\tvcs.modified=true"]
        build = {"cwd": str(stage / "src" / product.RUNNER), "toolchain": tool, "stdout": "", "stderr": "",
                 "argv": [tool["path"], "build", "-trimpath", "-o", str(stage / product.JOB), "."],
                 "binary_build_info": info}
        arm = {"identity": identity, "changed_sources": {}, "product": str(scope / "product.json"),
               "source_dir": str(scope / "src"), "runner_source_dir": str(scope / "src" / product.RUNNER), "build": build}
        self.assertEqual(report.check_build_recipe(arm, "stock", combined, parent), info)
        build["argv"][2:2] = ["-tags", "unexpected"]
        with self.assertRaisesRegex(ValueError, "build invocation"):
            report.check_build_recipe(arm, "stock", combined, parent)


if __name__ == "__main__":
    unittest.main()
