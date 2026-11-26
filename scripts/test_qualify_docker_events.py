import contextlib
import io
import json
import sys
import unittest
from unittest.mock import patch

import qualify_docker_events as qualification
from qualify_docker_restart import LABEL


def event(action, nanoseconds):
    return {
        "Action": action, "Type": "container", "scope": "local", "time": nanoseconds // 1_000_000_000,
        "timeNano": nanoseconds, "Actor": {"ID": "fixture", "Attributes": {
            LABEL: "project", "com.docker.compose.project": "project", "com.docker.compose.service": "job", "exitCode": "0",
        }},
    }


class EventQualificationTests(unittest.TestCase):
    def test_wall_clock_inversion_keeps_lifecycle_order_and_replay_rows(self):
        rows = [event(action, stamp) for action, stamp in (
            ("create", 100), ("start", 120), ("die", 130), ("stop", 131),
            ("start", 80), ("die", 90), ("stop", 95), ("destroy", 99),
        )]
        evidence = qualification.event_order_evidence(rows)
        self.assertEqual(evidence["duplicate_rows"], [])
        self.assertEqual(evidence["timestamp_regressions"], [{
            "first_index": 3, "index": 4, "first_action": "stop", "action": "start",
            "first_time_nano": 131, "time_nano": 80, "delta_ns": -51,
        }])
        qualification.lifecycle(qualification.checked_engine_rows(rows, "fixture", "project"))
        self.assertEqual(qualification.replay_window(rows, evidence["timestamp_regressions"]), (80, 131, 4))
        sorted_times = [event(row["Action"], 100 + i * 10) for i, row in enumerate(rows)]
        self.assertEqual(qualification.replay_window(sorted_times, []), (111, 169, 3))

    def test_duplicate_event_has_identity_even_when_json_field_order_changes(self):
        original = event("exec_start: sh -c exit 0", 100)
        original["Actor"]["Attributes"]["execID"] = "exec-id"
        duplicate = dict(reversed(original.items()))
        rows = [original, event("die", 110), duplicate]
        evidence = qualification.event_order_evidence(rows)
        repeated, = evidence["duplicate_rows"]
        self.assertEqual((repeated["first_index"], repeated["index"]), (0, 2))
        self.assertEqual((repeated["actor_id"], repeated["exec_id"], repeated["action"]),
                         ("fixture", "exec-id", original["Action"]))
        self.assertEqual(len(repeated["sha256"]), 64)
        with self.assertRaisesRegex(RuntimeError, "repeated an event"):
            qualification.checked_engine_rows(rows, "fixture", "project")

    def test_failure_preserves_first_stream_and_cleanup_errors_in_json(self):
        def fail(_fixture, diagnostics):
            diagnostics["engine"] = {"received": [{"line": "raw event", "wall_ns": 10, "monotonic_ns": 20}]}
            raise RuntimeError("first failure")

        out, err = io.StringIO(), io.StringIO()
        with (patch.object(sys, "argv", ["qualify_docker_events", "--host", "unix:///unused.sock"]),
              patch.object(qualification, "qualify", side_effect=fail),
              patch.object(qualification.Qualification, "cleanup", side_effect=RuntimeError("cleanup failure")),
              contextlib.redirect_stdout(out), contextlib.redirect_stderr(err)):
            self.assertEqual(qualification.main(), 1)
        receipt = json.loads(out.getvalue())
        self.assertEqual(receipt["failure"]["message"], "first failure")
        self.assertEqual(receipt["cleanup_failure"]["message"], "cleanup failure")
        self.assertEqual(receipt["diagnostics"]["engine"]["received"][0]["line"], "raw event")


if __name__ == "__main__":
    unittest.main()
