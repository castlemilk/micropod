"""Exercise the real host/observer handshake with local subprocesses and synthetic events."""
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

import guest_tx_trace as trace
from test_host_role import make_window


class ObserverWindow(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.dir = Path(temp.name)
        self.identity = dict(boot="boot-a", interface="eth1", address="00:00:00:00:00:01",
                             kernel="fixture", ifindex="3", netns="net:[44]")
        self.ready = dict(event="ready", boot_id="boot-a", interface="eth1", mac=self.identity["address"],
                          driver="virtio_net", kernel="fixture", ifindex=3, netns=44, queue=0,
                          object_sha256="sha", monotonic_ns=101, start_monotonic_ns=100, deadline_monotonic_ns=200)
        counts = dict(attempts=9, attempted_bytes=580608, completed_calls=9, tx_ok=9, tx_busy=0, tx_other=0,
                      dql_charged_bytes=0, read_errors=0, overlaps=0, boundary_crossings=0)
        self.result = dict(self.ready, event="result", reason="stop", complete=True, monotonic_ns=190, counters=counts)
        self.receipt = {}
        self.measure = Mock(side_effect=lambda check: check())

    def observe(self, after="", expected_sender=None):
        script = ("import json,sys\n" + f"print({json.dumps(self.ready)!r},flush=True)\n"
                  + "if sys.stdin.readline() != 'stop\\n': sys.exit(1)\n"
                  + f"print({json.dumps(self.result)!r},flush=True)\n" + after)
        trace.bracket([sys.executable, "-c", script], self.dir, self.identity, 0, "sha", lambda: {},
                      self.measure, self.receipt, expected_sender=expected_sender)

    def sender(self):
        expected = {"cgroup_v2": "/container-id", "args_sha256": "fixture-arguments"}
        self.ready["sender"] = dict(expected, namespace_pid=2, local_port=8080, netns_inode=45, tgid=471, start_ticks=33)
        self.result["sender"] = dict(self.ready["sender"])
        self.result["sender_counters"] = dict(calls=4, requested_bytes=8192, accepted_bytes=6144,
                                              full_calls=1, short_calls=1, zero_calls=1, error_calls=1,
                                              read_errors=0, oversized_returns=0)
        return expected

    def test_three_boundaries_can_use_distinct_service_and_device_namespaces(self):
        expected = self.sender()
        self.observe(expected_sender=expected)
        self.assertEqual(self.receipt["guest_result"]["sender_counters"]["accepted_bytes"], 6144)

    def test_wrong_workload_cgroup_aborts_before_load(self):
        expected = self.sender()
        self.ready["sender"]["cgroup_v2"] = "/other-id"
        with self.assertRaisesRegex(ValueError, "serving container"):
            self.observe(expected_sender=expected)
        self.measure.assert_not_called()

    def test_reused_sender_pid_invalidates_pair(self):
        expected = self.sender()
        self.result["sender"]["start_ticks"] += 1
        with self.assertRaisesRegex(ValueError, "sender process"):
            self.observe(expected_sender=expected)

    def test_more_accepted_than_requested_rejected(self):
        expected = self.sender()
        self.result["sender_counters"]["accepted_bytes"] = 8193
        with self.assertRaisesRegex(ValueError, "sender byte accounting"):
            self.observe(expected_sender=expected)

    def test_complete_and_zero_charge_stays_zero(self):
        self.observe()
        self.measure.assert_called_once()
        self.assertEqual(self.receipt["guest_result"]["counters"]["dql_charged_bytes"], 0)
        self.assertEqual(self.receipt["observer_exit_code"], 0)
        self.assertEqual(len((self.dir / "guest-tx.jsonl").read_text().splitlines()), 2)

    def test_wrong_namespace_prevents_client(self):
        self.ready["netns"] = 45
        with self.assertRaisesRegex(ValueError, "netns"):
            self.observe()
        self.measure.assert_not_called()

    def test_wrong_object_prevents_client(self):
        self.ready["object_sha256"] = "other"
        with self.assertRaisesRegex(ValueError, "object_sha256"):
            self.observe()
        self.measure.assert_not_called()

    def test_watchdog_cannot_be_mistaken_for_stop(self):
        self.result["reason"] = "timeout"
        with self.assertRaisesRegex(ValueError, "incomplete"):
            self.observe()

    def test_failed_charge_reads_are_not_zero_charge(self):
        self.result["counters"]["read_errors"] = 1
        with self.assertRaisesRegex(ValueError, "incomplete"):
            self.observe()
        self.assertNotIn("guest_result", self.receipt)

    def test_abort_preserves_first_attempt_and_closes_stdin(self):
        self.measure.side_effect = ValueError("lease changed")
        with self.assertRaisesRegex(ValueError, "lease changed"):
            self.observe()
        self.assertIn("observer_raw_sha256", self.receipt)
        self.assertEqual(self.receipt["observer_exit_code"], 1)

    def test_output_after_final_receipt_rejected(self):
        with self.assertRaisesRegex(ValueError, "termination"):
            self.observe("print('extra')")

    def test_only_explicit_single_scope_handoff_admits_diagnostic(self):
        now = 2000000000
        scope = self.dir / "a"
        fleet, release = make_window(self.dir, now, [scope])
        for mode in ("host-role", "guest-tx-trace"):
            with self.assertRaises(ValueError):
                trace.host_role.check_window(fleet, release, [scope], now, mode)
        owner = json.loads(release.read_text())
        owner["modes"].append("guest-tx-trace")
        release.write_text(json.dumps(owner))
        self.assertEqual(trace.host_role.check_window(fleet, release, [scope], now, "guest-tx-trace")["scopes"], [str(scope.resolve())])
        with self.assertRaises(ValueError):
            trace.host_role.check_window(fleet, release, [scope, self.dir / "b"], now, "guest-tx-trace")
