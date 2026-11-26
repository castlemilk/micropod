"""Reject stale boots and reordered or truncated stock workload envelopes."""

from copy import deepcopy
from random import Random
import unittest

import sibling_file_fault_around_holdout_results as report


class StockFaultAroundReplayTest(unittest.TestCase):
    def test_actual_host_wave_order_is_required_even_with_balanced_engine_counts(self):
        seed = 250257
        orders = ["AB", "BA"] * 2
        Random(seed).shuffle(orders)
        rows, last = [], 100
        for block, order in enumerate(orders):
            for mode in ("one", "all"):
                for arm in order:
                    start = last + 2
                    last = start + 2_000_000_000
                    rows.append({"block": block, "mode": mode, "arm": arm,
                                 "host_started_unix_ns": start, "host_finished_unix_ns": last})
        cap = last + 2
        self.assertEqual(report.check_host_windows(rows, seed, 100, cap), (102, last))

        changed = deepcopy(rows)
        changed[2]["arm"], changed[3]["arm"] = changed[3]["arm"], changed[2]["arm"]
        with self.assertRaisesRegex(ValueError, "actual engine order"):
            report.check_host_windows(changed, seed, 100, cap)
        with self.assertRaisesRegex(ValueError, "missing host wave evidence"):
            report.check_host_windows(rows[:-1], seed, 100, cap)
        changed = deepcopy(rows)
        changed[2]["host_finished_unix_ns"] -= 1_000_000_000
        with self.assertRaisesRegex(ValueError, "host wave bounds"):
            report.check_host_windows(changed, seed, 100, cap)

    def test_holdout_cannot_reuse_discovery_scope_or_guest_boot(self):
        def boot(name, start, end):
            return {"archive": f"archive-{name}", "native_boot": f"boot-{name}", "peer_boot": "peer",
                    "native_volume": {"scope": f"scope-{name}", "volume_uuid": f"volume-{name}"},
                    "admission": {"first_utc": f"2026-11-25T05:{start:02d}:00Z",
                                  "last_utc": f"2026-11-25T05:{end:02d}:00Z"}}

        metadata = dict.fromkeys(report.IDENTITY_FIELDS, "fixed")
        discovery = {**metadata, "by_seed": [
            {"seed": seed, "boot_order_bytes": list(order),
             "boots": {label: boot(f"{seed}-{label}", 10 + index, 12 + index) for label in report.trial.LABELS}}
            for index, (seed, order) in enumerate(report.trial.SEED_ORDER.items())]}
        fresh = {0: {"receipt": boot("new", 20, 21)}}
        report.check_discovery(metadata, fresh, discovery)

        fresh[0]["receipt"]["native_boot"] = discovery["by_seed"][0]["boots"]["64KiB"]["native_boot"]
        with self.assertRaisesRegex(ValueError, "reused a discovery"):
            report.check_discovery(metadata, fresh, discovery)
        fresh[0]["receipt"] = boot("new", 20, 21)
        fresh[0]["receipt"]["native_volume"]["scope"] = discovery["by_seed"][0]["boots"]["64KiB"]["native_volume"]["scope"]
        with self.assertRaisesRegex(ValueError, "reused a discovery"):
            report.check_discovery(metadata, fresh, discovery)


if __name__ == "__main__":
    unittest.main()
