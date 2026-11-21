import io
import json
import unittest

from summarize_vm_scheduler import summarize


class SchedulerSummaryTests(unittest.TestCase):
    @staticmethod
    def trace():
        header = {"pid": 99, "level_names": ["Super", "Performance"], "levels": 2, "tick_numer": 1, "tick_denom": 1}
        records = [header]
        for sec in range(4):
            used = sec * 500_000_000
            records.append({
                "epoch_ns": sec * 1_000_000_000, "monotonic_ns": sec * 1_000_000_000, "birth_ticks": 7,
                "cpu_ticks": used, "runnable_ticks": sec * 1_000_000_000, "legacy_ticks": used,
                "background_ticks": 0, "utility_ticks": 0, "default_ticks": 0, "initiated_ticks": 0,
                "interactive_ticks": 0, "skipped_threads": 0,
                "threads": [{"id": 123, "group": "vcpu", "state": 1, "level_cpu_ticks": [used // 4, used * 3 // 4]}],
            })
        return records

    @staticmethod
    def lines(records):
        return io.StringIO("\n".join(map(json.dumps, records)))

    def test_only_complete_intervals_and_off_cpu_wait(self):
        result = summarize(self.lines(self.trace()), 1, 2_999_999_999)
        self.assertEqual(result["intervals"], 1)
        self.assertEqual(result["seconds"], 1)
        self.assertEqual(result["cpu_s_per_s"], 0.5)
        self.assertEqual(result["runnable_wait_s_per_s"], 0.5)
        self.assertEqual(result["threads"]["vcpu"]["estimated_wait_s_per_s"], 0.5)
        self.assertEqual(result["threads"]["vcpu"]["cpu_fraction_by_level"], [0.25, 0.75])
        self.assertEqual(result["matched_thread_cpu_fraction"], 1)

    def test_reused_pid_and_empty_window(self):
        records = self.trace()
        with self.assertRaisesRegex(ValueError, "no complete sample"):
            summarize(self.lines(records), 1, 10)
        records[-1]["birth_ticks"] += 1
        with self.assertRaisesRegex(ValueError, "VM process changed"):
            summarize(self.lines(records))


if __name__ == "__main__":
    unittest.main()
