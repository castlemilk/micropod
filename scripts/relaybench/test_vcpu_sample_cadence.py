"""Regress window, identity, clock and state aliasing in the trace diagnostic."""
import copy
import unittest

from vcpu_sample_cadence import project, score

MS = 1_000_000
HEADER = dict(pid=81, levels=1, level_names=["P"], tick_numer=1, tick_denom=1)


def observed(states):
    # Each millisecond is running (R), runnable waiting (W) or blocked (B).
    # Snapshots arrive at the start of each 10 ms period.
    samples = []
    for i in range(0, len(states), 10):
        samples.append(dict(epoch_ns=(1000 + i)*MS, monotonic_ns=(200 + i)*MS, birth_ticks=123,
                            threads=[dict(id=31, group="vcpu", state=3 if states[i]=="B" else 1,
                                          level_cpu_ticks=[states[:i].count("R")*MS])]))
    return samples


def client():
    return dict(begin_ns=1_035*MS, end_ns=1_095*MS, window_s=.060, bytes=32*1024,
                per_stream_bytes=[1024]*32, mib_s=32*1024/(2**20*.060))


class SchedulerBounds(unittest.TestCase):
    def setUp(self):
        self.c = client()
        self.samples = observed("RRWWWWWWWW"*14)

    def capture(self, samples):
        return project(HEADER, samples, self.c, 81, 123, 1)

    def test_hidden_sleeps_produce_identical_samples(self):
        blocked = "RRBBBBBBBW"*14
        samples = observed(blocked)
        self.assertEqual(samples, self.samples)
        result = score(self.capture(samples), self.c)["rows"][0]
        low, high = result["score_running_cpu_s_bounds"]
        cpu = blocked[35:95].count("R")/1000
        self.assertLessEqual(low, cpu)
        self.assertGreaterEqual(high, cpu)
        self.assertEqual(blocked[35:95].count("B"), 42)
        self.assertEqual(result["sample_estimates"]["every_sample"]["estimated_nonrunnable_fraction"], 0)
        self.assertEqual(result["sample_estimates"]["every_sample"]["running_cpu_fraction"], .2)

    def test_unbracketed_window_rejected(self):
        with self.assertRaisesRegex(ValueError, "enclosing"):
            self.capture(self.samples[4:])

    def test_thread_replacement_rejected(self):
        samples = copy.deepcopy(self.samples)
        samples[5]["threads"][0]["id"] += 1
        with self.assertRaisesRegex(ValueError, "identity"):
            self.capture(samples)

    def test_clock_step_rejected(self):
        for s in self.samples[6:]:
            s["epoch_ns"] += 4*MS
        with self.assertRaisesRegex(ValueError, "clocks separated"):
            self.capture(self.samples)

    def test_counter_reset_rejected(self):
        self.samples[7]["threads"][0]["level_cpu_ticks"] = [0]
        with self.assertRaisesRegex(ValueError, "counter decreased"):
            score(self.capture(self.samples), self.c)

    def test_wrong_birth_rejected(self):
        with self.assertRaisesRegex(ValueError, "birth"):
            project(HEADER, self.samples, self.c, 81, 999, 1)


if __name__ == "__main__":
    unittest.main()
