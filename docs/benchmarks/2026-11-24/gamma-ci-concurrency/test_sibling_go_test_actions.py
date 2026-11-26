import unittest

from sibling_go_test_actions import action_totals, docker_time_ns


def graph():
    packages = ("github.com/castlemilk/micropod/guest", "github.com/castlemilk/micropod/guest/cmd/oci-batch")
    modes = ("go test", "test run", "test run", "link", "link", "vet", "build", "build",
             "build check cache", "build check cache")
    stamp = lambda n: f"2026-11-25T00:00:00.{n:09d}Z"
    rows = []
    for index, mode in enumerate(modes):
        tick = (len(modes) - index) * 10
        rows.append({"ID": index, "Mode": mode, "Package": packages[index - 1] if index in (1, 2) else "",
                     "TimeStart": stamp(tick), "TimeDone": stamp(tick + 4), "Cmd": None,
                     "Deps": [index + 1] if index + 1 < len(modes) else []})
    rows[5]["Deps"].append(6)  # cmd/go emits duplicate import prerequisites.
    return rows, docker_time_ns(stamp(0)), docker_time_ns(stamp(120))


class TestGoActionGraph(unittest.TestCase):
    def test_duplicate_dependency_is_counted_once(self):
        result = action_totals(*graph())
        self.assertEqual(sum(result["elapsed_ns"].values()), 120)
        self.assertEqual(result["elapsed_ns"]["vet"], 4)
        self.assertEqual(result["elapsed_ns"]["test run"], 8)

    def test_cyclic_dependency(self):
        rows, begin, end = graph()
        rows[8]["Deps"].append(6)
        with self.assertRaisesRegex(ValueError, "cyclic"):
            action_totals(rows, begin, end)

    def test_double_counting_parallel_actions(self):
        rows, begin, end = graph()
        rows[7]["TimeStart"] = rows[8]["TimeStart"]
        with self.assertRaisesRegex(ValueError, "parallel"):
            action_totals(rows, begin, end)

    def test_foreign_revision_interval(self):
        rows, begin, end = graph()
        with self.assertRaisesRegex(ValueError, "escaped"):
            action_totals(rows, begin + 1000, end + 1000)

