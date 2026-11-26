"""Replay anonymous THP memory counters without a guest."""

import unittest

from sibling_mthp import memory_summary, parse_snapshot


def sample(resident, collapse, faults, birth_ticks=91):
    row = parse_snapshot(f"mthp64 nr_anon {resident}\nmthp64 collapse_alloc {collapse}\n"
                         f"fault 64:anon_fault_alloc {faults}\n"
                         "fault 64:anon_fault_fallback 0\nfault 64:anon_fault_fallback_charge 0\n")
    row["host_vm"] = {"pid": 11, "birth_ticks": birth_ticks, "rss_kib": 1024}
    return row


class MemorySummaryTest(unittest.TestCase):
    def test_folio_gauge_can_fall_while_allocations_increase(self):
        before, after = sample(42, 12, 50), sample(36, 19, 56)
        summary = memory_summary(before, after, "always", (11, 91))
        self.assertEqual(summary["nr_anon_64k_before_folios"], 42)
        self.assertEqual(summary["nr_anon_64k_after_folios"], 36)
        self.assertEqual(summary["collapse_alloc_64k"], 7)
        self.assertEqual(summary["anon_fault_alloc_64k"], 6)

    def test_cumulative_collapse_counter_cannot_reset(self):
        with self.assertRaisesRegex(ValueError, "collapse counter reset"):
            memory_summary(sample(42, 12, 50), sample(36, 1, 56), "always")

    def test_both_rss_snapshots_must_match_expected_worker(self):
        for before_birth, after_birth in ((92, 91), (91, 92), (92, 92)):
            with self.subTest(before_birth=before_birth, after_birth=after_birth):
                before = sample(42, 12, 50, before_birth)
                after = sample(36, 19, 56, after_birth)
                with self.assertRaisesRegex(ValueError, "does not match the benchmark worker"):
                    memory_summary(before, after, "always", (11, 91))


if __name__ == "__main__":
    unittest.main()
