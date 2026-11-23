import gzip
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from guest_nic import decode, feature_bitmap


HERE = Path(__file__).resolve().parent
BOOT = "d144b86b-54d1-44b3-b15e-cd055ae63c99"


class GuestNICTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Replace each external guest command. Running the real collector through
        # /bin/sh on the host does not read host procfs, sysfs or any interface.
        fixture = """#!/bin/sh
case "$1" in
    /proc/sys/kernel/random/boot_id) printf '%s\\n' BOOT 7.3.5-micropod 4 02:00:01:02:03:04 ;;
    /proc/self/ns/net) echo 'net:[4026531840]' ;;
    -f) case "$2" in
        */driver) echo /sys/bus/virtio/drivers/virtio_net ;;
        */device) echo /sys/devices/platform/virtio4 ;;
        *) exit 9 ;;
        esac ;;
    */features) echo BITMAP ;;
    -1) printf '%s\\n' tx-10 rx-0 tx-2 ;;
    -k) printf '%s\\n' 'Features for eth1:' 'generic-receive-offload: on [fixed]' ;;
    -l) printf '%s\\n' 'Channel parameters for eth1:' 'Current hardware settings:' 'Combined: 1' ;;
    -c) echo 'Operation not supported' >&2; exit 1 ;;
    *) exit 9 ;;
esac
""".replace("BOOT", BOOT).replace("BITMAP", "1" + "0" * 51 + "1" + "0" * 75)
        with tempfile.TemporaryDirectory() as directory:
            for cmd in ("cat", "readlink", "ls", "ethtool"):
                path = Path(directory) / cmd
                path.write_text(fixture)
                path.chmod(0o755)
            cls.raw = subprocess.check_output(["/bin/sh", str(HERE / "guest_nic_capture.sh")],
                                              env=dict(os.environ, PATH=directory))

    def test_capture_and_decode(self):
        report = decode(self.raw, BOOT)
        self.assertEqual(report["queues"], {"rx": [0], "tx": [2, 10]})
        self.assertTrue(report["bitmap"]["negotiated"]["VQ_NOTF_COAL"])
        self.assertFalse(report["bitmap"]["negotiated"]["NOTF_COAL"])
        self.assertIn("on [fixed]", report["offloads"])
        self.assertIn("Combined: 1", report["channels"])
        self.assertIsNone(report["coalescing"])
        self.assertEqual(report["unavailable"]["coalescing"], {"exit_code": 1, "diagnostic": "Operation not supported"})

    def test_real_archived_bitmap(self):
        archive = HERE.parents[1] / "docs/benchmarks/2026-11-21/gamma-vnic.json.gz"
        with gzip.open(archive, "rt") as stream:
            caps = json.load(stream)["raw"]["trial.caps"]
        bits = next(line.split()[1] for line in caps.splitlines() if line.startswith("/sys/class/net/eth0/device/features "))
        features = feature_bitmap(bits)["negotiated"]
        self.assertTrue(features["GUEST_TSO4"] and features["HOST_TSO4"])
        self.assertFalse(features["MQ"] or features["NOTF_COAL"])

    def test_wrong_boot_or_changed_identity(self):
        with self.assertRaises(ValueError):
            decode(self.raw, "d144b86b-54d1-44b3-b15e-cd055ae63c98")
        for changed in (self.raw.replace(b"7.3.5-micropod", b"7.3.6-micropod", 1),
                        self.raw.replace(b"drivers/virtio_net", b"drivers/macvlan")):
            with self.subTest(), self.assertRaises(ValueError):
                decode(changed, BOOT)

    def test_wrong_device_truncation_and_malformed_data(self):
        for changed in (self.raw.replace(b"Features for eth1", b"Features for eth0"),
                        self.raw.split(b"@@ end after")[0], self.raw + b"unexpected\n",
                        self.raw.replace(b"10000000", b"2", 1), self.raw.replace(b"rx-0", b"tx-2")):
            with self.subTest(), self.assertRaises(ValueError):
                decode(changed, BOOT)

    def test_missing_ethtool_is_unavailable(self):
        changed = self.raw.replace(b"@@ end offloads 0", b"@@ end offloads 127")
        report = decode(changed, BOOT)
        self.assertIsNone(report["offloads"])
        self.assertEqual(report["unavailable"]["offloads"]["exit_code"], 127)


if __name__ == "__main__":
    unittest.main()
