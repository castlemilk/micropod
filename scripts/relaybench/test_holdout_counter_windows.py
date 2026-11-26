import unittest

from gamma_contrasts import VM, read_receipt
from holdout_counter_windows import HASHES, observation, replay


class HoldoutCounterWindowTests(unittest.TestCase):
    def test_both_arms_count_all_attempts_and_only_common_clean_pairs_in_order_groups(self):
        result = replay()
        self.assertEqual(len(result["attempts"]), 19)
        self.assertEqual([p["phase"] for p in result["attempts"][:3]], ["grace-warmup"] * 3)
        self.assertEqual(result["common_clean_pairs"], [n for n in range(1, 17) if n != 12])
        self.assertEqual(result["clean_scored_by_arm"]["micropod"]["attempts"], 16)
        self.assertEqual(result["clean_scored_by_arm"]["orbstack"]["attempts"], 15)
        dirty = result["attempts"][14]["orbstack"]
        self.assertFalse(dirty["clean"])
        self.assertEqual(dirty["fresh_failed"], 1)
        self.assertAlmostEqual(dirty["outside_ms"], 11880.367 - 6000.098125)
        for arm in ("micropod", "orbstack"):
            self.assertEqual(result["common_clean_by_first"]["micropod"][arm]["attempts"], 8)
            self.assertEqual(result["common_clean_by_first"]["orbstack"][arm]["attempts"], 7)
        # Fraction of host counter wall time, not a fraction of CPU or the bulk window.
        first = result["attempts"][3]["orbstack"]
        self.assertAlmostEqual(first["outside_pct_of_host"], 100 * (7207.453 - 6000.002958) / 7207.453)

    def test_reversed_coverage_and_missing_process_cannot_make_a_shorter_observation(self):
        archive = read_receipt(VM, HASHES[VM])
        row = archive["phases"]["grace-holdout"]["runs"]["confirm-micropod"]["1"]
        scope = archive["scopes"]["confirm-micropod"]
        pids = [int(scope["relay"]), int(scope["vmm"])]
        with self.assertRaisesRegex(ValueError, "unexpected host process"):
            observation(row, pids[:1])
        row["after"]["epoch_ns"] = row["before"]["epoch_ns"] + round(row["client"]["window_s"] * 1e9) - 1
        with self.assertRaisesRegex(ValueError, "shorter than its client"):
            observation(row, pids)
