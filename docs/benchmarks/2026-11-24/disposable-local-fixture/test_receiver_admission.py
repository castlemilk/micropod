"""Verify a refused VM window reaches the suite with the correct failure kind."""
from argparse import Namespace
from contextlib import ExitStack
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import local_idle
import receiver


class ReceiverAdmissionTests(unittest.TestCase):
    def test_idle_timeout_and_single_observation_failure_keep_clients_stopped(self):
        for seconds, kind in ((0, None), (6, "host_idle_timeout")):
            with self.subTest(seconds=seconds), TemporaryDirectory() as tmp, ExitStack() as stack:
                root = Path(tmp)
                facts = root / "guest.txt"
                facts.write_text("fixture inventory")
                args = Namespace(socket_evidence="controller", idle_wait_seconds=seconds, tools=root, out=root/"out",
                                 disk_path=root, min_free_gib=1, mode="baseline", endpoint=None, ambient_diagnostic=False,
                                 abbreviated_inventory=False, scope_a=root, facts_a=facts, build=root/"build.json",
                                 pairs=4, seed=1, run=True)
                fixture = {"address": "127.0.0.1:1234", "name": "service",
                           "socket_evidence": "controller", "accepted_socket_reno_verified": True}
                stack.enter_context(patch.dict(receiver.relay.HASHES, clear=True))
                stack.enter_context(patch.object(receiver, "scope_fixture", return_value=(fixture, [])))
                stack.enter_context(patch.object(receiver, "marker"))
                stack.enter_context(patch.object(receiver.path_pilot, "cpu_idle", return_value=56.77))
                ticks = iter(range(100))
                def observe(*args):
                    return local_idle.await_idle(*args, clock=lambda: next(ticks), sleep=lambda _: None)
                stack.enter_context(patch.object(receiver, "await_idle", side_effect=observe))
                snapshot = stack.enter_context(patch.object(receiver.relay, "snapshot"))
                timed = stack.enter_context(patch.object(receiver.relay, "run_in_window"))
                with self.assertRaisesRegex(ValueError, "host idle"):
                    receiver.run(args)
                status = json.loads((args.out / "status.json").read_bytes())
                self.assertEqual(status["idle_wait_seconds"], seconds)
                self.assertEqual(status["error_kind"], kind)
                self.assertEqual((status["started"], status["scored"]), (0, 0))
                self.assertFalse(status["local_vm_idle_and_delivery_qualified"])
                row = json.loads((args.out / "warmup-1-A.json").read_bytes())
                self.assertEqual(row["idle_observations"][0]["idle_pct"], 56.77)
                self.assertFalse(row["started"])
                snapshot.assert_not_called()
                timed.assert_not_called()


if __name__ == "__main__":
    unittest.main()
