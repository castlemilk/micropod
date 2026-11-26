"""Check the migration-cost replay's raw state and peer-adjusted timing gates."""

import unittest

import sibling_migration_cost_results as score


class MigrationCostReplayTest(unittest.TestCase):
    def setUp(self):
        self.boot = "181c545f-39c8-4aba-be59-886398d72ce5"
        features = "HRTICK NEXT_BUDDY PICK_BUDDY TTWU_QUEUE"
        self.fair = {"before": features.split(), "after": features.split(), "base_slice_ns": 250000,
                     "setting": "inherit", "clocksource": "arch_sys_counter"}
        self.raw = {phase: f"boot_id={self.boot}\ninitial_ns={500000 if phase == 'boot' else 62500}\n"
                           f"effective_ns=62500\nbase_slice_ns=250000\nfeatures={features}\n"
                    for phase in score.PHASES}

    def test_apply_and_read_only_states_agree(self):
        rows = score.scheduler_readbacks(self.raw, self.boot, score.CANDIDATE, self.fair)
        self.assertEqual(rows["boot"]["initial_ns"], "500000")
        self.assertEqual(rows["before"], rows["after"])
        self.assertEqual(rows["after"]["effective_ns"], "62500")

    def test_changed_knob_boot_slice_and_features_are_rejected(self):
        after = self.raw["after"]
        for corrupt in (after.replace("effective_ns=62500", "effective_ns=500000"),
                        after.replace("initial_ns=62500", "initial_ns=500000"),
                        after.replace("base_slice_ns=250000", "base_slice_ns=500000"),
                        after.replace("TTWU_QUEUE", "NO_TTWU_QUEUE"),
                        after.replace(self.boot, "aecefc40-c5f2-4820-9c95-ffb79f91047d"),
                        after.replace("initial_ns=62500", "effective_ns=62500")):
            with self.subTest(corrupt=corrupt), self.assertRaisesRegex(ValueError, "after receipt"):
                score.scheduler_readbacks({**self.raw, "after": corrupt}, self.boot, score.CANDIDATE, self.fair)

    def test_peer_movement_and_ties_in_paired_changes(self):
        def wave(native, peer):
            return {"A": dict.fromkeys(score.METRICS, native), "B": dict.fromkeys(score.METRICS, peer)}

        rows = {score.CONTROL: [wave(20, 15), wave(20, 15), wave(0.05, 0.04)],
                score.CANDIDATE: [wave(18, 10), wave(15, 17), wave(0.04, 0.03)]}
        pair_changes = score.peer_adjusted_rows(rows)
        self.assertEqual(pair_changes["p95_us"], {"median_paired_delta": 0, "candidate_lower": 1,
                                                 "candidate_higher": 1, "tied": 1})

    def test_one_post_work_host_row_may_follow_a_full_owned_peer_sample(self):
        def stamp(second):
            return f"2026-11-25T08:01:{second}+00:00"

        def ns(second):
            return score.docker_time_ns(stamp(second))

        ids = sorted(str(index) for index in range(64))
        host = [{"utc": stamp(second), "blockers": []} for second in ("01", "02", "04", "06")]
        peer = [{"time": stamp(second), "running": ids} for second in ("01.1", "02.1", "04.1")]
        receipt = score.reconcile_post_work_sample(host, peer, set(ids), ns("01.2"), ns("04.0"), ns("05"))
        self.assertEqual(receipt["last_paired_peer_sample"], peer[-1])
        self.assertEqual(receipt["post_work_host_sample"], host[-1])
        with self.assertRaisesRegex(ValueError, "overlap measured work"):
            score.reconcile_post_work_sample(host, peer, set(ids), ns("01.2"), ns("04.2"), ns("05"))
        with self.assertRaisesRegex(ValueError, "unknown or repeated"):
            foreign_peer = [*peer[:-1], {**peer[-1], "running": [*ids[:-1], "foreign"]}]
            score.reconcile_post_work_sample(host, foreign_peer, set(ids), ns("01.2"), ns("04.0"), ns("05"))


if __name__ == "__main__":
    unittest.main()
