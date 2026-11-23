"""Archived Mac observations plus deliberately synthetic direct-path fixture and DF replies."""
import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import mtu_path
from gamma_contrasts import ROOT, read_receipt


class DirectPathMTUTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        archive = ROOT / "docs/benchmarks/2026-11-21/gamma-vnic.json.gz"
        cls.raw = read_receipt(archive, "2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f")["raw"]

    def fixture(self):
        gateway, worker = "192.168.73.1", "192.168.73.2"
        ip = {"family": "inet", "local": worker, "prefixlen": 24}
        parent = {"ifname": "eth1", "ifindex": 3, "addr_info": [ip], "flags": ["UP", "LOWER_UP"], "mtu": 9000}
        child = {"ifname": "mppub0", "link_index": 3, "flags": ["UP", "LOWER_UP"], "mtu": 9000,
                 "linkinfo": {"info_kind": "macvlan", "info_data": {"mode": "private"}}}
        service_ip = "10.88.0.3"
        origin = {"ifname": "eth0", "addr_info": [{"family": "inet", "local": service_ip}]}
        route = {"dst": gateway, "dev": "mppub0", "prefsrc": service_ip}
        probe = {"argv": ["/sbin/ping", "-n", "-D", "-b", "bridge103", "-S", gateway, "-c", "3", "-s", "8972", worker],
                 "returncode": 0, "stdout": "\n".join([f"8980 bytes from {worker}: icmp_seq={i} ttl=64 time=0.4 ms"
                                                       for i in range(3)] +
                                                      ["3 packets transmitted, 3 packets received, 0.0% packet loss"])}
        return dict(gateway_ipv4=gateway, worker_ipv4=worker, mac_route=self.raw["trial.route"],
                    mac_bridge=self.raw["trial.interface"], worker_links=[parent], service_links=[origin, child],
                    service_route=[route], ping=probe)

    def test_archived_bridge_and_route_differ_between_same_named_jumbo_workers(self):
        capture = self.fixture()
        self.assertEqual(mtu_path.qualify(capture, 9000)["host_to_worker_df_echo_ipv4_bytes"], 9000)
        capture.update(mac_route=self.raw["mtu-first/trial.route"], mac_bridge=self.raw["mtu-first/trial.interface"])
        self.assertIn("mtu 9000", self.raw["mtu-first/trial.state"])
        with self.assertRaisesRegex(ValueError, "'mac_bridge': 1500, 'mac_route': 1500"):
            mtu_path.qualify(capture, 9000)

    def test_rejects_wrong_interface_route_or_child(self):
        original = self.fixture()
        changes = [
            (["mac_bridge"], self.raw["control.interface"]),
            (["mac_route"], original["mac_route"].replace("route to: 192.168.73.2", "route to: 192.168.99.2")),
            (["worker_links", 0, "ifname"], "eth0"), (["worker_links", 0, "mtu"], 1500),
            (["service_links", 1, "mtu"], 1500), (["service_links", 1, "link_index"], 2),
            (["service_links", 1, "linkinfo", "info_data", "mode"], "bridge"),
            (["service_route", 0, "prefsrc"], "10.88.0.9"), (["service_route", 0, "dev"], "eth0"),
            (["service_route", 0, "metrics"], [{"mtu": 1500}]),
        ]
        for keys, value in changes:
            with self.subTest(keys=keys, value=value), self.assertRaises(ValueError):
                capture = copy.deepcopy(original)
                node = capture
                for key in keys[:-1]:
                    node = node[key]
                node[keys[-1]] = value
                mtu_path.qualify(capture, 9000)

    def test_rejects_unbound_fragmentable_short_partial_or_duplicated_echo(self):
        original = self.fixture()["ping"]
        args, out = original["argv"], original["stdout"]
        for key, value in (("argv", [s for s in args if s != "-D"]), ("argv", ["en0" if s == "bridge103" else s for s in args]),
                           ("argv", [s if s != "8972" else "1472" for s in args]), ("returncode", 1),
                           ("stdout", out.replace("icmp_seq=1", "icmp_seq=0")), ("stdout", out.replace("8980", "1480")),
                           ("stdout", out.replace("192.168.73.2", "192.168.73.3")),
                           ("stdout", out.replace("0.0% packet loss", "33.3% packet loss"))):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                capture = self.fixture()
                capture["ping"][key] = value
                mtu_path.qualify(capture, 9000)

    def test_cli_accepts_complete_capture_and_returns_nonzero_for_missing_fields(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "capture.json"
            capture = self.fixture()
            args = [sys.executable, "-B", mtu_path.__file__, str(path), "--mtu", "9000"]
            path.write_text(json.dumps(capture))
            self.assertEqual(json.loads(subprocess.check_output(args))["df_echo_replies"], 3)
            del capture["service_route"]
            path.write_text(json.dumps(capture))
            result = subprocess.run(args, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("service_route", result.stderr)
            self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
