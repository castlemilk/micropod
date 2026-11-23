"""Within-window accounting, resolution sensitivity, and counter-boundary checks."""
import unittest

from stream_progress_windows import progress, scored_points


def counts(a=0, b=0):
    return [a, b, *([0] * 30)]


class StreamProgressWindowTests(unittest.TestCase):
    def test_time_weighted_factorization_and_coarsening(self):
        points = [(0, counts()), (1, counts(10)), (6, counts(10)), (7, counts(12, 20)),
                  (10, counts(12, 20)), (12, counts(12, 22))]
        fine, coarse = (progress(points, group) for group in (1, 4))
        # The 5- and 3-us idle gaps contribute nothing; weighted active stream-us are 1 + 2 + 2.
        self.assertEqual(fine['progress_fraction'], 4/12)
        self.assertEqual(fine['moving_streams_during_progress'], 5/4)
        self.assertEqual(fine['longest_consecutive_idle_us'], 5)
        self.assertEqual(fine['moving_stream_counts']['0-0']['us'], 8)
        self.assertEqual(fine['bytes'], 34)
        self.assertEqual(coarse['bytes'], fine['bytes'])
        self.assertEqual(coarse['mib_s'], fine['mib_s'])
        self.assertEqual(coarse['sample_intervals'], 2)
        self.assertEqual(coarse['progress_fraction'], 1)
        self.assertEqual(coarse['moving_streams_during_progress'], 22/12)

    def test_skew_at_scoring_boundaries_remains_visible(self):
        samples = [(0, counts()), (2, counts(4)), (4, counts(6)), (6, counts(10))]
        inner, skew = scored_points(samples, 1, 5, counts(11))
        self.assertEqual(inner, samples[1:3])
        self.assertEqual(skew, {'0': 1})
        with self.assertRaisesRegex(ValueError, 'interior bytes'):
            scored_points(samples, 1, 5, counts(1))
        with self.assertRaisesRegex(ValueError, 'backwards'):
            scored_points([*samples[:2], (4, counts(3)), samples[3]], 1, 5, counts(10))
        with self.assertRaisesRegex(ValueError, 'backwards'):
            scored_points([samples[0], (2, counts(4)), (2, counts(6)), samples[3]], 1, 5, counts(10))
        with self.assertRaisesRegex(ValueError, 'malformed'):
            scored_points([samples[0], (2, counts(4)[:-1]), *samples[2:]], 1, 5, counts(10))
