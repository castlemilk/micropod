import contextlib
import io
import math
import unittest
from unittest.mock import Mock

from local_idle import IdleTimeout, await_idle


class IdleWindowTests(unittest.TestCase):
    def setUp(self):
        self.seconds = 100
        self.row = {"started": False}
        self.published = []
        self.guard = Mock()
        self.samples = 0

    def advance(self, seconds):
        self.seconds += seconds

    def measure(self, values, wait, *, previous=None, diagnostic=False, duration=1):
        data = iter(values)

        def sample():
            value = next(data)
            self.advance(duration)
            self.samples += 1
            return value

        def publish():
            self.published.append((len(self.row["idle_observations"]), self.row.get("idle_gate_passed")))

        return await_idle(self.row, previous, diagnostic, wait, sample, self.guard, publish,
                          clock=lambda: self.seconds, sleep=self.advance)

    def test_two_consecutive_eligible_intervals_after_a_spike(self):
        result = self.measure([89.99, 90, 76, 90, 94.5], 12)
        self.assertEqual(result, 94.5)
        self.assertFalse(self.row["started"])
        self.assertEqual(self.row["idle_pct"], 94.5)
        self.assertTrue(self.row["idle_gate_passed"])
        obs = self.row["idle_observations"]
        self.assertEqual([s["elapsed_seconds"] for s in obs], [1, 3, 5, 7, 9])
        self.assertEqual([s["eligible"] for s in obs], [False, True, False, True, True])
        self.assertTrue(all(s["paired_idle_gap_pp"] is None for s in obs))
        self.assertEqual(self.guard.call_count, 5)
        self.assertEqual(self.published, [(1, False), (2, False), (3, False), (4, False), (5, True)])

    def test_paired_threshold_and_floor_both_apply_to_each_interval(self):
        self.measure([90, 90.99, 91, 96], 9, previous=96)
        obs = self.row["idle_observations"]
        self.assertEqual([s["eligible"] for s in obs], [False, False, True, True])
        self.assertEqual([s["paired_idle_gap_pp"] for s in obs[2:]], [5, 0])
        self.assertEqual(self.row["paired_idle_gap_pp"], 0)

    def test_wait_timeout_reports_values_and_keeps_observations(self):
        with self.assertRaisesRegex(IdleTimeout, r"4.00s.*2 observations.*last 89.00%.*floor 90%.*6.00 pp.*5 pp"):
            self.measure([91, 89, 91], 4, previous=95)
        self.assertEqual(self.published, [(1, False), (2, False)])
        self.assertEqual(self.samples, 2)
        self.assertFalse(self.row["started"])

    def test_eligible_sample_after_deadline_cannot_admit(self):
        with self.assertRaises(IdleTimeout):
            self.measure([97, 97], 4, duration=2)
        self.assertEqual([s["elapsed_seconds"] for s in self.row["idle_observations"]], [2, 5])
        self.assertFalse(self.row["idle_gate_passed"])

    def test_zero_wait_keeps_single_observation_error_and_boundaries(self):
        with self.assertRaisesRegex(ValueError, "host idle below 90") as failure:
            self.measure([89.99], 0)
        self.assertNotIsInstance(failure.exception, IdleTimeout)
        self.assertEqual(self.published, [(1, False)])
        with self.assertRaisesRegex(ValueError, "five percentage points"):
            self.measure([90], 0, previous=96)
        self.assertEqual(self.measure([90], 0, previous=95), 90)

    def test_diagnostic_observes_ambient_idle_once(self):
        self.assertEqual(self.measure([35.5], 180, diagnostic=True), 35.5)
        self.assertEqual(self.published, [(1, False)])
        self.assertFalse(self.row["idle_gate_passed"])
        self.assertEqual(self.seconds, 101)

    def test_progress_reports_start_wait_and_readiness_and_stays_quiet_in_single_mode(self):
        self.row.update(phase="warmup", arm="A")
        log = io.StringIO()
        with contextlib.redirect_stdout(log):
            self.measure([85] * 9 + [95, 95], 30)
        lines = log.getvalue().splitlines()
        self.assertEqual(len(lines), 3)
        self.assertIn("[idle] warmup A waiting at 1.0s", lines[0])
        self.assertIn("waiting at 17.0s", lines[1])
        self.assertIn("ready at 21.0s", lines[2])
        single = io.StringIO()
        with contextlib.redirect_stdout(single):
            self.measure([95], 0)
            self.measure([10], 45, diagnostic=True)
        self.assertEqual(single.getvalue(), "")

    def test_malformed_samples_and_guard_failures_are_not_timeouts(self):
        with self.assertRaisesRegex(ValueError, "invalid host idle observation") as failure:
            self.measure([math.nan], 100)
        self.assertNotIsInstance(failure.exception, IdleTimeout)
        self.assertIsNone(self.row["idle_observations"][0]["idle_pct"])
        self.assertEqual(self.samples, 1)
        self.guard.side_effect = RuntimeError("disk unavailable")
        with self.assertRaisesRegex(RuntimeError, "disk unavailable"):
            self.measure([95], 100)
        self.assertEqual(self.samples, 1)


if __name__ == "__main__":
    unittest.main()
