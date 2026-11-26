import json
import subprocess
import unittest

import receiver


class ReceiverWindowTests(unittest.TestCase):
    def setUp(self):
        self.start = 1_800_000_000_000_000_000
        self.end = self.start + 6_500_000_000
        self.row = {"client_start_ns": self.start, "client_end_ns": self.end,
                    "before": {"epoch_ns": self.start}, "after": {"epoch_ns": self.end}}
        self.client = {"bytes": 32 << 20, "per_stream_bytes": [1 << 20] * 32,
                       "window_s": 6.0, "mib_s": 32 / 6, "arrivals": 240,
                       "streams": 32, "period_us": 25000, "fresh_p95_us": 2000,
                       "fresh_p99_us": 5000, "dispatch_p95_us": 100, "dispatch_max_us": 500,
                       "errors": None, "reopened": 0}

    def score(self, **kwargs):
        result = subprocess.CompletedProcess([], 0, json.dumps(self.client), "")
        receiver.score(result, self.row, **kwargs)

    def test_host_counter_bounds_may_coincide_with_client_bounds(self):
        self.score()
        self.assertTrue(self.row["clean"])

    def test_shifted_equal_length_host_window_does_not_cover_the_client(self):
        for shift in (-1, 1):
            with self.subTest(shift=shift):
                self.row["before"]["epoch_ns"] = self.start + shift
                self.row["after"]["epoch_ns"] = self.end + shift
                with self.assertRaisesRegex(ValueError, "host counter"):
                    self.score()

    def test_missing_counter_snapshot_fails_full_scope(self):
        del self.row["before"]
        with self.assertRaisesRegex(ValueError, "host counter"):
            self.score()

    def test_endpoint_only_does_not_require_host_counters(self):
        del self.row["before"], self.row["after"]
        self.score(host_counters=False)
        self.assertTrue(self.row["clean"])

    def test_one_nanosecond_of_bulk_outside_invocation_is_rejected(self):
        self.row["client_end_ns"] = self.start + 5_999_999_999
        with self.assertRaisesRegex(ValueError, "measured time"):
            self.score()

    def test_fresh_completion_can_drain_after_bulk_window(self):
        self.client["fresh_p99_us"] = 6_400_000
        self.score()
        self.assertTrue(self.row["clean"])


if __name__ == "__main__":
    unittest.main()
