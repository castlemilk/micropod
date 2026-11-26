import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

from local_terminal import Run, receiver_failure


class ReceiverFailureTests(unittest.TestCase):
    def setUp(self):
        self.folder = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (self.folder / "receiver").mkdir()
        self.status = self.folder / "receiver/status.json"

    def test_receiver_exit_reports_structured_error_and_preserves_evidence(self):
        self.status.write_text(json.dumps({"completed_schedule": False, "error": "'sched_ext'"}))
        runner = SimpleNamespace(folder=self.folder, admission=None, guard=lambda: None)
        with self.assertRaises(RuntimeError) as failed:
            Run.waited(runner, [sys.executable, "-c", "import sys; sys.exit('detail in stderr')"], "receiver", 5)
        self.assertIn("receiver exited 1: 'sched_ext'", str(failed.exception))
        self.assertIn(str(self.status), str(failed.exception))
        self.assertEqual((self.folder / "receiver.stderr").read_text(), "detail in stderr\n")
        self.assertFalse(json.loads(self.status.read_bytes())["completed_schedule"])

    def test_host_role_error_and_bounded_cause(self):
        self.status.write_text(json.dumps({"timed_first_attempts": 0, "error": "PREFIX" + "x" * 1200 + " END"}))
        reason = receiver_failure(self.folder)
        self.assertNotIn("PREFIX", reason)
        self.assertIn(" END", reason)

    def test_invalid_or_absent_status_uses_only_stderr_tail(self):
        stderr = self.folder / "receiver.stderr"
        stderr.write_bytes(b"PREFIX" + b"." * 1500 + b"\xff final cause\n")
        for content in (None, b"{", b"[]", b'{"error": null}', b'{"error": ""}'):
            with self.subTest(content=content):
                if content is not None:
                    self.status.write_bytes(content)
                message = receiver_failure(self.folder)
                self.assertIn("final cause", message)
                self.assertIn(str(stderr), message)
                self.assertNotIn("PREFIX", message)


if __name__ == "__main__":
    unittest.main()
