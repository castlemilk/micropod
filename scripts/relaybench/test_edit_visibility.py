import multiprocessing
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import edit_visibility as ev


class EditVisibilityTests(unittest.TestCase):
    def test_eight_sample_tails_equal_observed_maximum_and_leave_empty_parent(self):
        with tempfile.TemporaryDirectory() as temp:
            result = ev.measure(temp, rounds=8)
            self.assertEqual(result["percentiles"], {
                "method": "nearest rank", "samples_per_action": 8, "one_based_ranks": {"p50": 4, "p95": 8, "p99": 8},
                "at_sample_maximum": ["p95", "p99"],
            })
            for action, summary in result["start_to_reader_ack"].items():
                observed = sorted(s["start_to_reader_ack_ns"] for s in result["samples"] if s["action"] == action)
                self.assertEqual(len(observed), 8)
                self.assertEqual(summary, {"p50_ns": observed[3], "p95_ns": observed[7], "p99_ns": observed[7]})
            self.assertEqual(list(Path(temp).iterdir()), [])

    def test_separate_reader_verifies_each_action_through_alias_and_preserves_existing_files(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            writer = directory / "source"
            writer.mkdir()
            preserved = writer / "draft"
            preserved.write_bytes(b"existing")
            reader = directory / "reader"
            reader.symlink_to(writer, target_is_directory=True)
            result = ev.measure(writer, reader, rounds=2, timeout=2)
            self.assertNotEqual(result["writer_pid"], result["reader_pid"])
            self.assertNotEqual(result["writer_parent"], result["reader_parent"])
            self.assertEqual([s["action"] for s in result["samples"]], list(ev.ACTIONS) * 2)
            for row in result["samples"]:
                self.assertEqual(row["start_to_reader_ack_ns"], row["mutation_ns"] + row["mutation_return_to_reader_ack_ns"])
                self.assertGreater(row["start_to_reader_ack_ns"], 0)
            self.assertEqual(list(writer.iterdir()), [preserved])
            self.assertEqual(preserved.read_bytes(), b"existing")

    def test_isolated_reader_root_times_out_and_all_owned_resources_are_cleaned(self):
        with tempfile.TemporaryDirectory() as temp:
            writer, reader = Path(temp) / "source", Path(temp) / "unrelated"
            writer.mkdir()
            reader.mkdir()
            children = {p.pid for p in multiprocessing.active_children()}
            with self.assertRaisesRegex((RuntimeError, TimeoutError), "timed out"):
                ev.measure(writer, reader, rounds=1, timeout=0.15)
            self.assertEqual(list(writer.iterdir()), [])
            self.assertEqual(list(reader.iterdir()), [])
            self.assertEqual({p.pid for p in multiprocessing.active_children()}, children)

    def test_missing_publication_and_writer_error_reap_reader(self):
        with tempfile.TemporaryDirectory() as temp:
            children = {p.pid for p in multiprocessing.active_children()}
            for error in (None, OSError("injected writer error")):
                with self.subTest(error=error), patch.object(ev, "apply", side_effect=error):
                    with self.assertRaisesRegex((OSError, RuntimeError), "timed out|injected writer error"):
                        ev.measure(temp, temp, rounds=1, timeout=0.15)
                self.assertEqual(list(Path(temp).iterdir()), [])
                self.assertEqual({p.pid for p in multiprocessing.active_children()}, children)

    def test_stale_same_size_bytes_duplicate_rename_and_missing_marker_cannot_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            marker = b"fixture"
            identity = root / "identity"
            identity.write_bytes(marker)
            create, edit, rename, delete = ev.states(marker, 1)
            (root / "draft").write_bytes(create[0])
            self.assertFalse(ev.matches(root, marker, edit))
            (root / "renamed").write_bytes(rename[1])
            self.assertFalse(ev.matches(root, marker, rename))
            (root / "draft").unlink()
            self.assertTrue(ev.matches(root, marker, rename))
            identity.unlink()
            (root / "renamed").unlink()
            self.assertFalse(ev.matches(root, marker, delete))

    def test_inputs_are_bounded_before_writing(self):
        with tempfile.TemporaryDirectory() as temp:
            for rounds, timeout in ((0, 1), (65, 1), (1, 0), (1, 31), (1, float("nan"))):
                with self.subTest(rounds=rounds, timeout=timeout), self.assertRaises(ValueError):
                    ev.measure(temp, rounds=rounds, timeout=timeout)
            self.assertEqual(list(Path(temp).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
