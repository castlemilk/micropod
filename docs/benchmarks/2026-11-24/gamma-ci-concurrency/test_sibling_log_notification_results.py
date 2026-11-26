"""Exercise log-watcher qualification and the shared crossover summary."""

import unittest

import sibling_log_notification_results as report


class LogNotificationReplayTest(unittest.TestCase):
    def test_watcher_tests_include_exit_repair_passes(self):
        roots = {"TestCRILogWatcherSharesOneFDAndRetiresWatches", "TestCRIFollowWaitRechecksUncommittedExit"}
        names = sorted(roots | report.polling.TEST_SUBCASES)
        raw = "\n".join([*(f"=== RUN   {name}" for name in names), *(f"--- PASS: {name} (0.00s)" for name in names), "PASS"])
        self.assertEqual(report.check_tests(raw, roots), names)
        damaged = raw.replace("--- PASS: TestCRIFollowWaitRechecksUncommittedExit/NotFound (0.00s)", "")
        with self.assertRaisesRegex(ValueError, "missing a test or exit-repair subcase"):
            report.check_tests(damaged, roots)

    def test_summary_uses_notify_labels_and_counterbalanced_boots(self):
        def wave(value):
            return {**dict.fromkeys(report.trial.shared.METRICS, value), "offered_requests": 96_000, "requests": 96_000,
                    "build": {"products": ["same"], "jobs": 8, "revisions": 16, "test_passes": 128}}

        boots = {}
        for index, (seed, order) in enumerate(report.ORDERS.items()):
            for position, mode in enumerate(order):
                minute = 10 * index + 2 * position
                boots[seed, mode] = {
                    "receipt": {"admission": {"first_utc": f"2026-11-25T07:{minute:02d}:00Z",
                                             "last_utc": f"2026-11-25T07:{minute:02d}:30Z"}},
                    "rows": [{"order": engine_order, "A": wave(1 if mode == "notify" else 3), "B": wave(2)}
                             for engine_order in ("AB", "BA", "AB", "BA")],
                }
        result = report.polling.summarize(boots, modes=report.MODES, orders=report.ORDERS)
        self.assertEqual(result["native_beats_peer_on_both_medians_each_seed"], {"stock": False, "notify": True})
        self.assertEqual(result["within_mode"]["notify"]["joint_wins"]["micropod"], 8)
        self.assertEqual(result["completed_requests"], 3_072_000)
        self.assertEqual(result["by_seed"][1]["boot_order"], ["notify", "stock"])


if __name__ == "__main__":
    unittest.main()
