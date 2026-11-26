import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import local_socket_route as proof


# Netlink fields from gamma-vm-scheduling.json.gz, scopes.lab-0.controller_proofs.reno.route.
ROUTE = {"Family": 2, "Scope": 253, "Type": 1, "Table": 254, "Gw": "", "LinkIndex": 3,
         "Dst": {"IP": "192.168.132.1", "Mask": "/////w=="}, "Src": "10.88.0.2", "RtoMin": 20,
         "RtoMinLock": True, "Congctl": "reno", "MTU": 0, "QuickACK": 0}
FLOW = {"local_ip": "10.88.0.2", "remote_ip": "192.168.132.1", "local_port": 8080, "remote_port": 55001}
STATE = {"interfaces": {"pod0": {"addr": "[10.88.0.2/16 fe80::1/64]"}, "mppub0": {"addr": "[]"}}}
FIXTURE = {"id": "cid", "name": "marker", "address": "127.0.0.1:14123"}


class ServiceRouteTests(unittest.TestCase):
    def run_probe(self, path, *, samples=None, route=ROUTE, bodies=(b"marker", b"marker"), state=STATE):
        samples = iter([[], [FLOW], [FLOW], []] if samples is None else samples)

        def command(*args):
            if args[-1] == "/mpcheck/socket-inventory":
                return json.dumps({"source": "proc_net_tcp", "connections": next(samples)})
            if args[-2:] == ("/mpcheck/pathproof", "routes"):
                return json.dumps({"mppub0": [route]})
            if args[-2:] == ("/mpcheck/check", "state"):
                return json.dumps(state)
            self.fail(f"unexpected command {args}")

        with patch.object(proof.http.client, "HTTPConnection") as ctor, patch.object(proof.time, "sleep"):
            conn = ctor.return_value
            response = conn.getresponse.return_value
            response.status = 200
            response.read.side_effect = bodies
            proof.observe(Mock(command=command), ["docker"], FIXTURE, path)
            conn.close.assert_called_once()
        return json.loads(path.read_text())

    def test_route_only_proof_waits_and_binds_both_marker_observations(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "accepted.json"
            raw = self.run_probe(path, samples=[[FLOW], [], [FLOW], [FLOW], [FLOW], []])
            self.assertTrue(raw["passed"])
            self.assertIsNone(raw["socket_congestion_controller"])
            self.assertEqual(raw["flow"], FLOW)
            self.assertEqual(raw["route"], ROUTE)
            self.assertEqual([r["stage"] for r in raw["observations"]],
                             ["before_open", "before_open", "first_marker", "first_socket", "routes",
                              "service_addresses", "second_marker", "second_socket", "after_close", "after_close"])

    def test_wrong_flow_and_policy_are_rejected_with_observations(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "accepted.json"
            for why, overrides in (
                ("accepted peer", {"samples": [[], [{**FLOW, "remote_ip": "192.168.132.2"}]]}),
                ("local endpoint", {"samples": [[], [{**FLOW, "local_ip": "10.88.0.3"}]]}),
                ("accepted peer", {"route": {**ROUTE, "Dst": {"IP": "192.168.132.1", "Mask": "////AA=="}}}),
                ("Reno policy", {"route": {**ROUTE, "Congctl": "bbr"}}),
                ("service interfaces", {"state": {"interfaces": {"mppub0": {"addr": "[]"}}}}),
                ("one established", {"samples": [[], [FLOW, {**FLOW, "remote_port": 55002}]]}),
                ("connection changed", {"samples": [[], [FLOW], [{**FLOW, "remote_port": 55002}]]}),
                ("marker", {"bodies": (b"marker", b"wrong")}),
            ):
                with self.subTest(why=why, overrides=overrides), self.assertRaisesRegex(ValueError, why):
                    self.run_probe(path, **overrides)
                raw = json.loads(path.read_text())
                self.assertFalse(raw["passed"])
                self.assertIn(why, raw["error"])
                self.assertIsNone(raw["socket_congestion_controller"])
                self.assertTrue(raw["observations"])

    def test_existing_service_flow_times_out_without_opening_marker(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(proof.time, "monotonic", side_effect=[10, 13]):
            path = Path(tmp) / "accepted.json"
            with self.assertRaisesRegex(ValueError, "remain before_open"):
                self.run_probe(path, samples=[[FLOW]])
            raw = json.loads(path.read_text())
            self.assertEqual([row["stage"] for row in raw["observations"]], ["before_open"])

    def test_ambiguous_gateway_route_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            proof.match_route(FLOW, {"mppub0": [ROUTE, {**ROUTE, "Congctl": "bbr"}]}, STATE)


if __name__ == "__main__":
    unittest.main()
