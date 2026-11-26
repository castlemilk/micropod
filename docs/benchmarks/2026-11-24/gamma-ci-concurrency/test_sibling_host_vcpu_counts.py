import unittest

from sibling_compiler_runtime_host import LOOP_INSTRUCTIONS, measure


class CounterCalibrationTests(unittest.TestCase):
    def fixture(self, ratio=1, mask="0", replace=False):
        count = clock = 0

        def capture():
            nonlocal clock
            clock += 1
            return {"header": {"pid": 12}, "birth_ticks": 8, "monotonic_ns": clock,
                    "threads": [{"vcpu_index": i, "id": 10 + i + (1 if replace and clock == 2 else 0),
                                 "level_cpu_ticks": [clock, 1], "level_instructions": [count if i == 0 else 0, 3],
                                 "level_cycles": [clock, 4]} for i in range(4)]}

        def execute(n):
            nonlocal count
            count += int(ratio * LOOP_INSTRUCTIONS * n) + 350_000  # Equal host work cancels in the difference.
            return f"{mask} {n} {16 * n}"

        return capture, execute

    def test_known_guest_work_survives_constant_exec_overhead(self):
        cal = measure(*self.fixture())
        self.assertEqual(cal["observed_over_expected"], 1)
        self.assertTrue(cal["within_ten_percent"])

    def test_host_only_counts_fail_guest_attribution(self):
        cal = measure(*self.fixture(ratio=0))
        self.assertEqual(cal["observed_over_expected"], 0)
        self.assertFalse(cal["within_ten_percent"])

    def test_wrong_guest_mask_and_recycled_host_thread_are_rejected(self):
        for change in ({"mask": "1"}, {"replace": True}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                measure(*self.fixture(**change))


if __name__ == "__main__":
    unittest.main()
