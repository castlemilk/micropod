"""Reject plausible TTWU receipts with an extra knob, startup step or boot order."""

from copy import deepcopy
from pathlib import Path
import plistlib
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import sibling_ttwu_queue as fixture
import sibling_ttwu_queue_results as report


class TTWUQueueReplayTest(unittest.TestCase):
    def test_legacy_projection_requires_the_exact_private_arguments_first(self):
        mode = "off"
        expected = report.expected_kernel_args(mode)
        kernel_args = report.trial.KERNEL_ARGS
        env = {kernel_args: " ".join(expected), "SCOPE": "/tmp/disposable"}
        plist = {"EnvironmentVariables": env, "ProcessType": "Standard"}
        raw = plistlib.dumps(plist)
        projected = report.projected_plist(raw, mode)
        self.assertEqual(projected["EnvironmentVariables"], {**env, kernel_args: report.trial.signed.BOOT_ARGS})
        self.assertEqual(plistlib.loads(raw), plist)
        cmdline = f"console=hvc0 {' '.join(expected)} root=/dev/vda"
        self.assertEqual(report.checked_guest_cmdline(cmdline, mode),
                         f"console=hvc0 {report.trial.signed.BOOT_ARGS} root=/dev/vda")
        for args in (expected[:-1], [*expected, expected[-1]], [*expected[:-1], report.QUEUE_ARG + "on"],
                     [*expected, "micropod.bench_extra=on"]):
            with self.subTest(args=args), self.assertRaisesRegex(ValueError, "wrong TTWU queue token"):
                report.projected_plist(plistlib.dumps({"EnvironmentVariables": {kernel_args: " ".join(args)}}), mode)
        with self.assertRaisesRegex(ValueError, "wrong TTWU queue token"):
            report.checked_guest_cmdline(cmdline + " micropod.bench_extra=on", mode)

    def test_live_features_and_after_workload_readback_allow_one_changed_bit(self):
        initial = ["TTWU_QUEUE", "HRTICK", "NEXT_BUDDY", "PICK_BUDDY", "RUN_TO_PARITY"]
        on, off = sorted(initial), sorted(["NO_TTWU_QUEUE", *initial[1:]])

        def ordinary(features):
            return {"before": features, "after": features, "setting": "inherit", "base_slice_ns": 250_000,
                    "clocksource": "arch_sys_counter"}

        self.assertEqual(report.scheduler_invariants("on", initial, on, on, ordinary(on)),
                         report.scheduler_invariants("off", initial, off, off, ordinary(off)))
        extra = sorted(set(off) - {"HRTICK"} | {"NO_HRTICK"})
        with self.assertRaisesRegex(ValueError, "sole effective scheduler"):
            report.scheduler_invariants("off", initial, extra, extra, ordinary(extra))
        with self.assertRaisesRegex(ValueError, "sole effective scheduler"):
            report.scheduler_invariants("off", initial, off, on, ordinary(off))
        with self.assertRaisesRegex(ValueError, "ordinary scheduler receipt"):
            report.scheduler_invariants("off", initial, off, off, ordinary(on))
        with self.assertRaisesRegex(ValueError, "contradictory"):
            report.scheduler_invariants("off", initial, [*off, "TTWU_QUEUE"], off, ordinary(off))

    def test_extra_commands_in_staged_startup_are_rejected_even_between_known_sections(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "archive"
            archive.mkdir()
            for name, data in ((fixture.START, b"containerd\nfixture-facts\nrecover\n"),
                               (fixture.FACTS, b"read stock readiness\n"), (fixture.MANIFEST, b"{}\n")):
                (archive / name).write_bytes(data)
            (root / fixture.MANIFEST).write_bytes((archive / fixture.MANIFEST).read_bytes())
            plan = {report.QUEUE: "on", report.trial.TREATMENT: report.WINDOW}
            with patch.object(fixture, "HERE", root), patch.object(fixture, "check_launch"), \
                    patch.object(report, "STAGED_START_SHA256", report.terminal.digest(archive / fixture.START)), \
                    patch.object(report, "STAGED_FACTS_SHA256", report.terminal.digest(archive / fixture.FACTS)), \
                    patch.object(report.stock, "validated_archive", return_value=((250263, report.WINDOW), {}, plan)):
                self.assertEqual(report.validated_archive(archive, plan, {}, {})[0], (250263, "on"))
                (archive / fixture.START).write_bytes(b"containerd\nfixture-facts\nunexpected-command\nrecover\n")
                with self.assertRaisesRegex(ValueError, "exact staged startup"):
                    report.validated_archive(archive, plan, {}, {})

    def test_balanced_boot_order_and_joint_wins_use_matched_actual_windows(self):
        def wave(score):
            return {**dict.fromkeys(report.SHARED.METRICS, score), "offered_requests": 96_000, "requests": 96_000,
                    "build": {"products": ["same"], "jobs": 8, "revisions": 16, "test_passes": 128}}

        verified = {}
        for seed_index, (seed, order) in enumerate(report.SEED_ORDER.items()):
            for arm_index, mode in enumerate(order):
                minute = 10 * seed_index + 2 * arm_index
                receipt = {"admission": {"first_utc": f"2026-11-25T06:{minute:02d}:00Z",
                                         "last_utc": f"2026-11-25T06:{minute:02d}:30Z"}}
                rows = [{"order": schedule, "A": wave(2 if mode == "on" else 1), "B": wave(1.5)}
                        for schedule in ("AB", "BA", "AB", "BA")]
                verified[seed, mode] = {"rows": rows, "receipt": receipt}
        result = report.summarize(verified)
        self.assertEqual(result["native_boots"], 4)
        self.assertEqual(result["completed_requests"], 3_072_000)
        self.assertEqual(result["within_mode"]["off"]["joint_wins"]["micropod"], 8)
        self.assertEqual(result["native_beats_peer_on_both_medians_each_seed"], {"on": False, "off": True})
        self.assertEqual(result["seeds_with_lower_off_median"]["micropod"]["p95_us"], 2)
        wrong = deepcopy(verified)
        first, second = wrong[250267, "on"], wrong[250267, "off"]
        first["receipt"], second["receipt"] = second["receipt"], first["receipt"]
        with self.assertRaisesRegex(ValueError, "preselected boot order"):
            report.summarize(wrong)


if __name__ == "__main__":
    unittest.main()
