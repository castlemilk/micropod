import copy
import unittest

from gamma_contrasts import read_receipt
from guest_ingress_replay import DIRECTORY, PATH_ARCHIVE, PATH_SHA, minimum_cut, trace_row


class IngressPhaseTests(unittest.TestCase):
    def test_phase_and_total_must_belong_to_same_request(self):
        # Nineteen observations determine p95. The one 100 ms response has
        # no setup to remove, while its 80 ms neighbour has 20 ms of setup.
        totals = [70_000] * 18 + [80_000, 100_000]
        self.assertEqual(minimum_cut([0] * 18 + [20_000, 0], totals), 2500)
        self.assertIsNone(minimum_cut([0] * 18 + [0, 20_000], totals))
        self.assertEqual(minimum_cut([0], [75_000]), 0)

    def test_rejects_reversed_phase_or_missing_raw_request(self):
        raw = read_receipt(DIRECTORY / PATH_ARCHIVE, PATH_SHA)
        original = raw["records"]["final-trace/1-candidate.json"]
        for defect in ("reversed", "missing"):
            with self.subTest(defect=defect):
                sample = copy.deepcopy(original)
                events = sample["trace"]["fresh"]
                if defect == "reversed":
                    events[0]["written_us"] = events[0]["first_byte_us"] + 1
                else:
                    events.pop()
                with self.assertRaises(ValueError):
                    trace_row(sample)
