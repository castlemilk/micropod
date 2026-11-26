import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from service_qdisc import compare


BOOT = "297eb0f3-abd1-4123-8fa8-60d27327a81d"
NS = "net:[4026533001]"
PEER = "192.168.128.1"


def capture(tick, tx, *, kind="fq", handle="8001:", egress="mppub0", index_after=3,
            peer=PEER, count=None, drops=0, namespace=NS):
    def link(index):
        return json.dumps([{"ifindex": index, "ifname": "mppub0", "link_index": 5,
                            "link_netnsid": 0, "address": "02:00:00:00:00:03",
                            "linkinfo": {"info_kind": "macvlan", "info_data": {"mode": "private"}},
                            "stats64": {"rx": {"bytes": 6}, "tx": {"bytes": tx}}}])
    route = [{"dev": egress, "dst": peer, "prefsrc": "10.88.0.2"}]
    qdisc = [{"kind": kind, "handle": handle, "root": True, "options": {},
              "bytes": tx if count is None else count, "packets": 3, "drops": drops, "requeues": 0}]
    stamp = f"{tick}.00 5.42"
    return "\n".join(["service-qdisc-v1", BOOT, namespace, stamp, "@@ link-before", link(3),
                      "@@ route", json.dumps(route), "@@ qdisc", json.dumps(qdisc), "@@ link-after",
                      link(index_after), "@@ end", stamp, namespace, BOOT, ""]).encode()


class ServiceQdiscTests(unittest.TestCase):
    def test_shell_collector_output_is_decodable(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            sections = capture(10, 24).decode().splitlines()
            commands = {
                "cat": f'case "$1" in */boot_id) echo {BOOT};; /proc/uptime) echo "10.00 5.42";; *) exit 1;; esac',
                "readlink": f'test "$1" = /proc/self/ns/net && echo "{NS}"',
                "ip": f"""case "$*" in
                    "-j -s -d link show dev mppub0") echo '{sections[5]}' ;;
                    "-4 -j route get {PEER}") echo '{sections[7]}' ;; *) exit 1 ;; esac""",
                "tc": f"""test "$*" = "-j -s -d qdisc show dev mppub0" && echo '{sections[9]}'""",
            }
            for name, command in commands.items():
                path = directory / name
                path.write_text("#!/bin/sh\n" + command + "\n")
                path.chmod(0o700)
            raw = subprocess.check_output(["/bin/sh", str(Path(__file__).with_name("service_qdisc_capture.sh")), PEER],
                                          env={**os.environ, "PATH": tmp})
        result = compare(raw, capture(17, 140), BOOT, NS, PEER)
        self.assertEqual(result["qdisc_delta"]["bytes"], 116)

    def test_progress_and_drop_attribution(self):
        result = compare(capture(10, 24), capture(17, 140, drops=2), BOOT, NS, PEER)
        self.assertEqual(result["qdisc_delta"], {"bytes": 116, "packets": 0, "drops": 2, "requeues": 0})
        self.assertEqual(result["link_tx_bytes_between_inner_bounds"], 116)
        self.assertTrue(result["fq_counted_bytes"])

    def test_noqueue_and_idle_fq(self):
        for kind, handle in (("noqueue", "0:"), ("fq", "8001:")):
            a, b = [capture(t, n, kind=kind, handle=handle, count=0) for t, n in ((10, 24), (17, 140))]
            self.assertFalse(compare(a, b, BOOT, NS, PEER)["fq_counted_bytes"])

    def test_changed_scope_configuration_clock_or_counter(self):
        for edit in (dict(handle="8002:"), dict(egress="eth0"), dict(index_after=7),
                     dict(peer="192.168.128.2"), dict(count=1), dict(namespace="net:[9999]")):
            with self.subTest(edit=edit), self.assertRaises(ValueError):
                compare(capture(10, 24), capture(17, 140, **edit), BOOT, NS, PEER)
        with self.assertRaises(ValueError):
            compare(capture(10, 24), capture(10, 140), BOOT, NS, PEER)

    def test_unavailable_stats_do_not_become_zero(self):
        b = capture(17, 140).replace(b'"bytes": 140, "packets"', b'"packets"')
        with self.assertRaisesRegex(ValueError, "counter"):
            compare(capture(10, 24), b, BOOT, NS, PEER)
