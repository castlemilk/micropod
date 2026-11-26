"""Exercise paced latency attribution with synthetic receipt timestamps."""

import unittest
from pathlib import Path
from unittest.mock import patch

import sibling_paced_delay_results as delay
import sibling_paced_results as paced


GATE = 1_795_562_000_000_000_000
MICROPOD_BOOT = "12345678-1234-1234-1234-123456789012"
ORBSTACK_BOOT = "12345678-1234-1234-1234-123456789013"


def sample(call=8, *, warm=False):
    return {"got_conn_count": 1, "dial_starts": int(warm), "reused": not warm, "same_as_warmup": not warm,
            "got_conn_ns": 1, "wrote_request_ns": 2, "first_response_byte_ns": 3, "total_ns": call}


def make_wave(rate, page_bytes=16384, changes=None):
    changes = changes or {}
    jobs = [{"id": f"id-{index}", "name": f"job-{index}", "ip": f"10.0.0.{index + 1}"}
            for index in range(2 * paced.PAIRS)]
    total = paced.offered_slots(rate, paced.OFFER_NS)
    rows = []
    for slot in range(paced.PAIRS):
        server, client = jobs[slot], jobs[paced.PAIRS + slot]
        arrivals, samples = [], []
        previous = 0
        for index, ordinal in enumerate(range(slot, total, paced.PAIRS)):
            extra, call = changes.get((slot, index), (0, 8))
            due = paced.due_offset(ordinal, rate)
            dispatch = max(due, previous) + extra
            previous = dispatch + call
            arrivals.append({"due_offset_ns": due, "dispatch_offset_ns": dispatch,
                             "completion_offset_ns": previous, "latency_ns": previous - due})
            samples.append(sample(call))
        rows.append({"index": slot, "code": 0, "receipt": {
            "url": f"http://{server['ip']}:8080/id", "marker": server["name"], "warmup": sample(warm=True),
            "requests": len(samples), "requested": len(samples), "complete": True, "samples": samples,
            "pace": {"offered_rps": rate, "slot": slot, "arrivals": arrivals, "wait_clock": paced.WAIT_CLOCK,
                     "clock_calibration_ns": 10, "timer_slack_ns": 50_000},
            "window": {"local": f"{client['ip']}:1234", "remote": f"{server['ip']}:8080", "page_bytes": page_bytes,
                       "ready_unix_ns": GATE - 1, "scheduled_unix_ns": GATE, "duration_ns": paced.OFFER_NS,
                       "started_unix_ns": GATE + arrivals[0]["dispatch_offset_ns"], "finished_unix_ns": GATE + previous},
        }})
    return rows, jobs


class RequestPhasesTest(unittest.TestCase):
    def test_carryover_and_additional_dispatch_wait_have_disjoint_intervals(self):
        arrival = {"due_offset_ns": 100, "dispatch_offset_ns": 128, "completion_offset_ns": 136, "latency_ns": 36}
        self.assertEqual(delay.request_phases(120, arrival, sample()), (20, 8, 1, 1, 1, 5))
        self.assertEqual(delay.request_phases(98, arrival, sample()), (0, 28, 1, 1, 1, 5))
        self.assertEqual(delay.request_phases(128, arrival, sample()), (28, 0, 1, 1, 1, 5))

    def test_rejects_reversed_or_inexact_intervals(self):
        arrival = {"due_offset_ns": 100, "dispatch_offset_ns": 128, "completion_offset_ns": 136, "latency_ns": 36}
        with self.assertRaisesRegex(ValueError, "phases do not add"):
            delay.request_phases(129, arrival, sample())
        with self.assertRaisesRegex(ValueError, "phases do not add"):
            delay.request_phases(120, arrival, {**sample(), "first_response_byte_ns": 1})
        with self.assertRaisesRegex(ValueError, "phases do not add"):
            delay.request_phases(120, {**arrival, "latency_ns": 37}, sample())
        with self.assertRaisesRegex(ValueError, "integer nanoseconds"):
            delay.request_phases(120, arrival, {**sample(), "total_ns": 8.0})


class WavePhasesTest(unittest.TestCase):
    def test_latency_keeps_build_slots_and_other_jobs_separate(self):
        rows, jobs = make_wave(128, changes={(7, 1): (100, 12), (8, 2): (200, 24)})
        _, scored = delay.score_wave(rows, jobs, 128, 16384)
        builders, others = (scored["client_latency"][k] for k in ("with_build", "without_build"))
        self.assertEqual((builders["clients"], builders["requests"], builders["worst_client_slots"]), (8, 48, [7]))
        self.assertEqual((others["clients"], others["requests"], others["worst_client_slots"]), (24, 144, [8]))
        self.assertEqual(builders["worst_client_arrival_p95_us"], .112)
        self.assertEqual(others["worst_client_arrival_p95_us"], .224)

    def test_tail_distinguishes_fresh_wait_from_following_backlog(self):
        rows, jobs = make_wave(128, changes={(0, 0): (1_700_000_000, 8)})
        _, scored = delay.score_wave(rows, jobs, 128, 16384)
        self.assertEqual(scored["requests"], 192)
        carryover, additional = delay.PHASES[:2]
        self.assertEqual(scored["positive_requests"][carryover], 5)
        self.assertEqual(scored["positive_requests"][additional], 1)
        self.assertEqual(scored["median_ns"][carryover], 0)
        tail = scored["slowest_one_percent_by_arrival"]
        self.assertEqual(tail["requests"], 2)
        self.assertEqual(tail["max_ns"][carryover], 1_450_000_008)
        self.assertEqual(tail["max_ns"][additional], 1_700_000_000)
        self.assertEqual(tail["largest_phase_requests"][carryover], 1)
        self.assertEqual(tail["largest_phase_requests"][additional], 1)
        self.assertEqual(tail["tied_largest_phase_requests"], 0)
        self.assertAlmostEqual(sum(tail["fraction_of_request_latency"].values()), 1.0)
        self.assertAlmostEqual(tail["carryover_fraction_of_dispatch_delay"], 1_450_000_008 / 3_150_000_008)

    def test_tail_ties_use_offer_order(self):
        rows, jobs = make_wave(64, changes={(0, 0): (20, 8), (1, 0): (0, 28)})
        _, scored = delay.score_wave(rows, jobs, 64, 16384)
        tail = scored["slowest_one_percent_by_arrival"]
        self.assertEqual(tail["requests"], 1)
        self.assertEqual(tail["min_arrival_ns"], 28)
        self.assertEqual(tail["largest_phase_requests"][delay.PHASES[1]], 1)

    def test_rejects_missing_slot_shifted_due_and_changed_reuse(self):
        rows, jobs = make_wave(64)
        with self.assertRaisesRegex(ValueError, "invalid offered cohort"):
            delay.score_wave(rows[:-1], jobs, 64, 16384)
        for changed, name, invalid, message in (
            (rows[0]["receipt"]["pace"]["arrivals"][0], "due_offset_ns", 1, "invalid paced timing"),
            (rows[0]["receipt"]["samples"][0], "same_as_warmup", False, "expected warmed connection"),
        ):
            with self.subTest(name=name), patch.dict(changed, {name: invalid}):
                with self.assertRaisesRegex(ValueError, message):
                    delay.score_wave(rows, jobs, 64, 16384)


def builds_for(jobs, boot):
    builds = []
    for slot, job in enumerate(jobs[paced.PAIRS:paced.PAIRS + paced.BUILDERS]):
        revision = f"sibling-0-{slot}"
        lines = []
        for index, suffix in enumerate("ab"):
            digest = f"{2 * slot + index + 1:064x}"
            lines.append(f"{revision}-{suffix} {job['name']} 8 10 30 1 1 1 {digest} 1:2 1:3 {boot} 7 action")
        builds.append({"code": 0, "id": job["id"], "revision": revision, "stderr": "",
                       "started_unix_ns": GATE - 35_000_000,
                       "stdout": "\n".join([*lines, f"end {GATE + 3_000_000_000} 0"])})
    return builds


class BootReplayTest(unittest.TestCase):
    def test_reads_each_dense_wave_once_and_checks_saved_metrics(self):
        path = Path("retained-run")
        plan = {"scope": "/retired", "seed": 1, "rounds": 1, "offered_rps": 64, "build_nice": 0,
                "pages": {"kernel_page_kib": 16}, "layouts": ["grouped"]}
        saved = {"grouped-0-one": {"order": "BA", "A": {}, "B": {}}, "grouped-0-all": {"order": "BA"}}
        records = {"plan.json": plan, "windows.json": saved}
        boots = {"A": MICROPOD_BOOT, "B": ORBSTACK_BOOT}
        inventory, raw = {}, {}
        for arm, page_bytes in (("A", 16384), ("B", 4096)):
            rows, jobs = make_wave(64, page_bytes)
            build_rows = builds_for(jobs, boots[arm])
            tag = f"grouped-0-all-{arm}"
            raw[tag] = rows
            records[f"{tag}-go.json"] = build_rows
            inventory[arm] = {"jobs": jobs}
            wave = paced.score_wave(rows, jobs, 64, page_bytes)
            saved["grouped-0-all"][arm] = {field: wave[field] for field in paced.LIVE_SCORE_FIELDS}
            saved["grouped-0-all"][arm]["build"] = paced.score_builds(build_rows, jobs, 0, 0, GATE, expected_boot=boots[arm])

        with (patch.object(delay, "read", side_effect=lambda folder, name: records[name]),
              patch.object(paced, "check_inputs", return_value={}),
              patch.object(paced, "check_boot", return_value=(MICROPOD_BOOT, {})),
              patch.object(paced, "check_cohorts", return_value=(inventory, {}, boots)),
              patch.object(paced, "read_wire", side_effect=lambda folder, tag: raw[tag]) as wire):
            replayed = delay.replay_boot(path)
            self.assertCountEqual([call.args[1] for call in wire.call_args_list], raw.keys())
            window = replayed["layouts"]["grouped"][0]
            self.assertEqual(window["order"], "BA")
            self.assertEqual(window["A"]["requests"], 96)
            self.assertIsNone(window["A"]["slowest_one_percent_by_arrival"]["carryover_fraction_of_dispatch_delay"])
            saved["grouped-0-all"]["A"]["p95_us"] += 1
            with self.assertRaisesRegex(ValueError, "stored paced wave differs"):
                delay.replay_boot(path)


if __name__ == "__main__":
    unittest.main()
