"""Exercise the process counters returned by the same observer as the worker pilot."""
import json
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

import gamma_contrasts as contrasts
import gamma_pilot as pilot


def snapshot(epoch, user, system, runnable, **hardware):
    return dict(epoch_ns=epoch, tick_numer=2, tick_denom=1,
                tasks=[dict(pid=31, birth_ticks=7, user_ticks=user, system_ticks=system,
                            runnable_ticks=runnable, **hardware)])


class ProcessWorkTests(unittest.TestCase):
    def test_worker_attempt_units_and_counter_resets(self):
        # Host snapshots bracket setup and drain as well as the 6s client window.
        payload = 2**30
        rate = payload / 2**20 / 6
        client = dict(streams=32, arrivals=240, period_us=25000, errors=[], reopened=0,
                      per_stream_bytes=[payload // 32] * 32, window_s=6, bytes=payload, mib_s=rate,
                      fresh_p95_us=150, fresh_p99_us=180)
        start = snapshot(1_000_000_000, 20, 10, 40, instructions=3, cycles=5)
        end = snapshot(9_000_000_000, 2_000_000_020, 1_000_000_010, 4_000_000_040,
                       instructions=3+2*payload, cycles=5+payload)
        row = {}
        fixture = dict(pids={"vmm": 31}, address="127.0.0.1:1234", name="test")
        output = subprocess.CompletedProcess([], 0, json.dumps(client), "")
        with patch.object(pilot, "snapshot", side_effect=[start, end]), patch.object(pilot, "run_in_window", return_value=output):
            pilot.attempt(Path("/unused"), fixture, {31: 7}, row, lambda: None)
        counters = row["host"]["vmm"]
        self.assertTrue(row["clean"])
        self.assertEqual(counters["mean_host_cores"], .75)
        self.assertEqual(counters["wait_s_per_s"], .25)
        self.assertEqual(counters["cpu_s_per_gib"], 6)
        self.assertEqual(counters["instructions_per_byte"], 2)
        self.assertEqual(counters["cycles_per_byte"], 1)
        self.assertEqual(counters["instructions_per_cycle"], 2)

        for value in (None, 0, 3, 2, -1, False, 4.5):
            bad = {**end["tasks"][0], "instructions": value}
            if value is None:
                del bad["instructions"]
            with self.subTest(instructions=value):
                partial = contrasts.process_work(start, dict(end, tasks=[bad]), 31, payload)
                self.assertIsNone(partial["instructions_per_byte"])
                self.assertIsNone(partial["instructions_per_cycle"])
                self.assertEqual(partial["cycles_per_byte"], 1)
                self.assertEqual(partial["mean_host_cores"], .75)
        # A user-time reset can be masked by the system-time increase in their sum.
        reset = dict(end["tasks"][0], user_ticks=19)
        with self.assertRaisesRegex(ValueError, "counter delta"):
            contrasts.process_work(start, dict(end, tasks=[reset]), 31, payload)
