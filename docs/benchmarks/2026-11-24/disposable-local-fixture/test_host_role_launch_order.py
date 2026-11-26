"""A change in VM launch order must preserve the score's Standard and Interactive arm identities."""
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import local_qos as qos
import local_terminal as terminal


class LaunchOrderTest(unittest.TestCase):
    def exercise(self, first, fail_second=False):
        args = ["--mode", "host-role", "--check-inputs"]
        if first:
            args += ["--host-role-first", first]
        opts = terminal.parse_options(args)
        expected = ["b", "a"] if first == "Interactive" else ["a", "b"]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "probe").mkdir()
            probe = root / "observer"
            probe.write_bytes(b"fixture observer")
            started = []

            def arm(letter, workers, files, workspace, oci, process_type):
                self.assertEqual(workers, 2)
                self.assertEqual(process_type, qos.ROLES[letter.upper()])
                started.append(letter)
                if fail_second and len(started) == 2:
                    raise RuntimeError("second boot failed")
                facts = root / (letter + "-facts")
                facts.write_text(process_type)
                return root / letter, facts

            runner = SimpleNamespace(root=root, arm=arm)
            files = {"build": root / "build", "role_probe": probe}
            with patch.object(qos, "signed_worker"), patch.object(qos.role, "GUEST_PROBE_SHA256", qos.relay.digest(probe)):
                if fail_second:
                    with self.assertRaisesRegex(RuntimeError, "second boot failed"):
                        qos.receiver_args(runner, files, root, root, root, root, opts)
                else:
                    argv = qos.receiver_args(runner, files, root, root, root, root, opts)
                    for letter in expected:
                        self.assertEqual(argv[argv.index("--scope-" + letter) + 1], root / letter)
                        self.assertEqual(argv[argv.index("--facts-" + letter) + 1], root / (letter + "-facts"))
            record = json.loads((root / "launch-order.json").read_text())
            self.assertEqual(record["requested_first"], opts.host_role_first)
            self.assertEqual(started, expected)
            a, b = record["launches"]
            self.assertEqual([a["arm"], b["arm"]], [s.upper() for s in expected])
            self.assertLessEqual(a["start_monotonic_ns"], a["ready_monotonic_ns"])
            self.assertLessEqual(a["ready_monotonic_ns"], b["start_monotonic_ns"])
            for item, letter in zip((a, b), expected):
                if fail_second and item is b:
                    self.assertNotIn("ready_monotonic_ns", item)
                    self.assertNotIn("guest_facts_sha256", item)
                else:
                    self.assertEqual(item["guest_facts_sha256"], qos.relay.digest(root / (letter + "-facts")))

    def test_default_and_reversed(self):
        for first in (None, "Interactive"):
            with self.subTest(first=first):
                self.exercise(first)

    def test_partial_provisioning(self):
        self.exercise("Interactive", fail_second=True)


if __name__ == "__main__":
    unittest.main()
