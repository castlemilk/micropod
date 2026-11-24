"""Exercise the actual POSIX collector on a sysfs tree populated with surviving BQL values."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from bql_bounds import POLICY, boundaries, decode
from gamma_contrasts import ROOT, read_receipt
from tx_offload_bql_replay import SUPPLEMENT

HERE = Path(__file__).resolve().parent
BOOT = "aa000000-1234-4000-8000-000000000001"


class QueueBoundaryTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.nic = self.root / "sys/class/net/eth1"
        self.queue = self.nic / "queues/tx-0/byte_queue_limits"
        self.queue.mkdir(parents=True)
        inputs = read_receipt(ROOT / "docs/benchmarks/2026-11-24/tx-offload-bql-readbacks.json.gz", SUPPLEMENT)
        for line in inputs["bql"]["stock-bql"].splitlines():
            filename, value = line.split()
            self.put(self.root / filename.lstrip("/"), value)
        for name, value in (("boot_id", BOOT), ("osrelease", "7.3.5")):
            path = "random/" + name if name == "boot_id" else name
            self.put(self.root / "proc/sys/kernel" / path, value)
        ns = self.root / "proc/self/ns"
        ns.mkdir(parents=True)
        (ns / "net").symlink_to("net:[4026531980]")
        self.put(self.nic / "ifindex", 3)
        self.put(self.nic / "address", "02:00:00:00:00:01")
        device = self.root / "sys/devices/virtio3"
        device.mkdir(parents=True)
        (self.nic / "device").symlink_to("../../../devices/virtio3")
        (device / "driver").symlink_to("../../bus/virtio/drivers/virtio_net")
        for name, value in (("tx_bytes", 1000), ("tx_packets", 10), ("tx_dropped", 0), ("tx_errors", 0)):
            self.put(self.nic / "statistics" / name, value)
        self.put(self.root / "proc/uptime", "11.11 45.00")

    def put(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"{value}\n")

    def capture(self, check=True):
        return subprocess.run(["sh", str(HERE / "bql_capture.sh"), "eth1"],
                              env={**os.environ, "BQL_FIXTURE_ROOT": str(self.root)},
                              capture_output=True, check=check)

    def test_archived_linux_abi_and_possible_overshoot(self):
        before = self.capture().stdout
        self.put(self.queue / "inflight", 588916)
        self.put(self.root / "proc/uptime", "12.11 46.00")
        self.put(self.nic / "statistics/tx_bytes", 2000)
        result = boundaries(before, self.capture().stdout, BOOT, "eth1", 1879048192)
        self.assertEqual(result["interface_delta"]["tx_bytes"], 1000)
        self.assertEqual([result["before"]["values"][k] for k in POLICY], [1879048192, 0, 196, 0])
        self.assertEqual(result["after"]["values"]["inflight"], 588916)

    def test_missing_abi_field_stops_the_capture(self):
        (self.queue / "limit_max").unlink()
        result = self.capture(check=False)
        self.assertNotEqual(result.returncode, 0)
        with self.assertRaises(ValueError):
            decode(result.stdout)

    def test_misbound_or_incomplete_capture(self):
        before = self.capture().stdout
        self.put(self.root / "proc/uptime", "12.11 46.00")
        after = self.capture().stdout
        for other in (after.replace(BOOT.encode(), b"bb000000-1234-4000-8000-000000000001"),
                      after.replace(b"eth1\n", b"eth0\n"), after.replace(b"tx_bytes 1000", b"tx_bytes 0"),
                      after.replace(b"limit_max 1879048192", b"limit_max 524288"),
                      after.replace(b"limit_min 0", b"inflight 0"), before):
            with self.subTest(other=other), self.assertRaises(ValueError):
                boundaries(before, other, BOOT, "eth1", 1879048192)


if __name__ == "__main__":
    unittest.main()
