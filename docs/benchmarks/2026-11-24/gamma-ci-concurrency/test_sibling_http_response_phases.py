"""Check additive phase accounting and matched offered-ordinal tail selection."""

import unittest

import sibling_http_response_phases as report


class HTTPResponsePhasesTest(unittest.TestCase):
    def test_callback_differences_use_one_request_and_validate_elapsed_time(self):
        sample = {"got_conn_ns": 10, "wrote_request_ns": 25, "first_response_byte_ns": 45, "total_ns": 50}
        arrival = {"dispatch_offset_ns": 200, "completion_offset_ns": 250}
        self.assertEqual(report.sample_phases(sample, arrival), (50, 10, 15, 20, 5))
        with self.assertRaisesRegex(ValueError, "post-dispatch"):
            report.sample_phases({**sample, "first_response_byte_ns": 24}, arrival)
        with self.assertRaisesRegex(ValueError, "post-dispatch"):
            report.sample_phases(sample, {**arrival, "completion_offset_ns": 249})

    def test_rank_and_union_measure_different_populations_without_subtracting_quantiles(self):
        native = [(64, 4, 10, 20, 30)] * 160
        peer = [(48, 4, 5, 20, 19)] * 160
        native[:8] = [(100, 4, 10, 20, 66)] * 8
        peer[8:16] = [(80, 4, 5, 32, 39)] * 8
        actual = report.compare_group(native, peer, "all")
        self.assertEqual(actual["service_p95_gap_ns"], 16)
        self.assertEqual(actual["joint_slowest_5pct_requests"], 0)

        own = actual["own_slowest_5pct"]
        self.assertEqual([own[engine]["builder_requests"] for engine in ("micropod", "orbstack")], [8, 0])
        self.assertEqual(own["micropod_minus_orbstack_mean_ns"]["total"], 20)
        paired = actual["same_offers_slowest_5pct_union"]
        self.assertEqual([paired[engine]["builder_requests"] for engine in ("micropod", "orbstack")], [8, 8])
        self.assertEqual([paired[engine]["requests"] for engine in ("micropod", "orbstack")], [16, 16])
        deltas = paired["micropod_minus_orbstack_mean_ns"]
        self.assertEqual(deltas["total"], 18)
        self.assertEqual(sum(deltas[key] for key in report.PHASES), deltas["total"])

    def test_change_in_peer_gap_keeps_peer_movement_visible(self):
        def mode(native_last, peer_last):
            def observed(last):
                values = (30 + last, 4, 6, 20, last)
                return {"requests": 1, "sum_ns": dict(zip(report.COMPONENTS, values, strict=True))}

            native, peer = observed(native_last), observed(peer_last)
            selected = {"micropod": native, "orbstack": peer}
            group = {"median_p95_ns": {engine: outcome["sum_ns"]["total"] for engine, outcome in selected.items()},
                     **dict.fromkeys(report.RUNNER_SELECTIONS, selected)}
            return {"groups": dict.fromkeys(report.GROUPS, group)}

        change = report.runner_phase_change(mode(40, 20), mode(40, 30))["all"]
        self.assertEqual(change["median_p95_ns"], {"micropod": 0, "orbstack": 10})
        band = change["own_p95_band"]
        self.assertEqual(band["micropod"]["first_byte_to_completion"], 0)
        self.assertEqual(band["orbstack"]["first_byte_to_completion"], 10)
        self.assertEqual(band["micropod_minus_orbstack"]["first_byte_to_completion"], -10)


if __name__ == "__main__":
    unittest.main()
