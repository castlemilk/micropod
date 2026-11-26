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

    def attach_reverse(self, capture):
        gateway, worker = capture["gateway_ipv4"], capture["worker_ipv4"]
        echo_id = 12345
        ping_lines = [f"PING {gateway} ({gateway}) from {worker} eth1: 8972(9000) bytes of data."]
        requests = []
        for i in (1, 2, 3):
            ping_lines.append(f"8980 bytes from {gateway}: icmp_seq={i} ttl=64 time=0.5 ms")
            requests += [f"IP (tos 0x0, ttl 64, id {448 + i}, offset 0, flags [DF], proto ICMP (1), length 9000)",
                         f"    {worker} > {gateway}: ICMP echo request, id {echo_id}, seq {i}, length 8980"]
        ping_lines += [f"--- {gateway} ping statistics ---", "3 packets transmitted, 3 received, 0% packet loss, time 2002ms"]
        expression = f"icmp and src host {worker} and dst host {gateway} and icmp[0] = 8 and icmp[4:2] = {echo_id}"
        capture["worker_to_host"] = {
            "echo_id": echo_id, "worker_route": [{"dst": gateway, "prefsrc": worker, "dev": "eth1"}],
            "ping": {"argv": ["ping", "-4", "-n", "-M", "do", "-I", "eth1", "-e", str(echo_id),
                             "-c", "3", "-s", "8972", gateway], "returncode": 0, "stdout": "\n".join(ping_lines)},
            "bridge_capture": {
                "argv": ["/usr/sbin/tcpdump", "-i", "bridge103", "-t", "-n", "-v", "-s", "0", "-c", "3", expression],
                "returncode": 0, "stdout": "\n".join(requests),
                "stderr": ("tcpdump: listening on bridge103, link-type EN10MB (Ethernet), snapshot length 524288 bytes\n"
                           "3 packets captured\n3 packets received by filter\n0 packets dropped by kernel\n"),
            },
        }
        return capture

    def test_bidirectional_scope_and_cli_preserve_old_receipt(self):
        old = self.fixture()
        legacy = mtu_path.qualify(old, 9000)
        self.assertEqual(set(legacy), {"configured_mtu", "mac_interface", "host_to_worker_df_echo_ipv4_bytes",
                                      "df_echo_replies", "service_return_interface"})
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "mtu.json"
            args = [sys.executable, "-B", mtu_path.__file__, str(path), "--mtu", "9000", "--require-bidirectional"]
            path.write_text(json.dumps(old))
            missing = subprocess.run(args, capture_output=True, text=True)
            self.assertEqual(missing.returncode, 1)
            self.assertIn("worker_to_host", missing.stderr)
            case = self.attach_reverse(old)
            path.write_text(json.dumps(case))
            result = json.loads(subprocess.check_output(args))
        self.assertEqual(result, {**legacy, "worker_to_host_df_echo_ipv4_bytes": 9000,
                                  "worker_to_host_df_echo_replies": 3, "bridge_observed_worker_df_requests": 3})
        self.assertEqual(mtu_path.qualify(case, 9000), result)
        # The archived first jumbo worker selected a 1500-byte host route despite the guest setting.
        case.update(mac_route=self.raw["mtu-first/trial.route"], mac_bridge=self.raw["mtu-first/trial.interface"])
        with self.assertRaisesRegex(ValueError, "'mac_route': 1500"):
            mtu_path.qualify(case, 9000, require_bidirectional=True)

    def test_rejects_mismatched_worker_probe_or_mac_packets(self):
        original = self.attach_reverse(self.fixture())["worker_to_host"]
        ping, trace = original["ping"], original["bridge_capture"]
        old_args, replies, packets, stats = ping["argv"], ping["stdout"], trace["stdout"], trace["stderr"]
        changes = [
            (["echo_id"], 0), (["echo_id"], 65536),
            (["worker_route", 0, "prefsrc"], "192.168.73.8"), (["worker_route", 0, "dst"], "192.168.73.9"),
            (["worker_route", 0, "dev"], "eth0"), (["worker_route", 0, "gateway"], "192.168.73.3"),
            (["worker_route", 0, "metrics"], {"mtu": 1500}),
            (["ping", "argv"], [x if x != "do" else "want" for x in old_args]),
            (["ping", "argv"], [x if x != "eth1" else "eth0" for x in old_args]),
            (["ping", "argv"], [x if x != "8972" else "1472" for x in old_args]),
            (["ping", "argv"], [*old_args[:-1], "192.168.73.2"]), (["ping", "returncode"], 1),
            (["ping", "stdout"], replies.replace("from 192.168.73.2 eth1", "from 192.168.73.4 eth1")),
            (["ping", "stdout"], replies.replace("8980 bytes", "1480 bytes")),
            (["ping", "stdout"], replies.replace("icmp_seq=2", "icmp_seq=1")),
            (["ping", "stdout"], replies.replace("from 192.168.73.1:", "from 192.168.73.9:")),
            (["ping", "stdout"], replies.replace("3 received, 0%", "2 received, 33%")),
            (["bridge_capture", "argv"], ["tcpdump", "-r", "other.pcap"]),
            (["bridge_capture", "returncode"], 1), (["bridge_capture", "stderr"], stats.replace("bridge103", "bridge102")),
            (["bridge_capture", "stderr"], stats.replace("0 packets dropped", "1 packet dropped")),
            (["bridge_capture", "stdout"], packets.replace("flags [DF]", "flags [none]")),
            (["bridge_capture", "stdout"], packets.replace("offset 0", "offset 8")),
            (["bridge_capture", "stdout"], packets.replace("length 9000", "length 1500")),
            (["bridge_capture", "stdout"], packets.replace("length 8980", "length 1480")),
            (["bridge_capture", "stdout"], packets.replace("192.168.73.2 >", "192.168.73.5 >")),
            (["bridge_capture", "stdout"], packets.replace("> 192.168.73.1", "> 192.168.73.2")),
            (["bridge_capture", "stdout"], packets.replace("echo request", "echo reply")),
            (["bridge_capture", "stdout"], packets.replace("id 12345", "id 12344")),
            (["bridge_capture", "stdout"], packets.replace("seq 2", "seq 1")),
            (["bridge_capture", "stdout"], "\n".join(packets.splitlines()[2:])),
        ]
        for keys, value in changes:
            with self.subTest(keys=keys, value=str(value)[:70]), self.assertRaises(ValueError):
                capture = self.fixture()
                node = capture["worker_to_host"] = copy.deepcopy(original)
                for key in keys[:-1]:
                    node = node[key]
                node[keys[-1]] = value
                mtu_path.qualify(capture, 9000)

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
