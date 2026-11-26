"""Replay the stock inventory from the first ready local VM against guest metrics schemas."""
import json
from pathlib import Path
import re
import unittest
from unittest.mock import patch

import receiver


# Extract from the recorded Gamma VM 20261124T084123Z-local-uobi2v8y/a/guest-facts.txt.
STOCK_FACTS = """release=7.3.5-micropod
boot=952ff2d8-4f63-4f29-87a9-903eea815349
machine=aarch64
config_sha256=a0da9a6ab98e69e253f2e8a27664bdb23f08ab4cef1dd66178c38c26d0035c9c
# CONFIG_SCHED_CLASS_EXT is not set
CONFIG_CFS_BANDWIDTH=y
CONFIG_DEBUG_INFO_BTF=y
virtio_nic=eth0
ethtool -i eth0
tcp-segmentation-offload: on
generic-receive-offload: on
/sys/class/net/eth0/queues/rx-0
/sys/class/net/eth0/queues/tx-0
virtio_nic=eth1
ethtool -i eth1
tcp-segmentation-offload: on
generic-receive-offload: on
/sys/class/net/eth1/queues/rx-0
/sys/class/net/eth1/queues/tx-0
"""
BOOT = "952ff2d8-4f63-4f29-87a9-903eea815349"
COMPILED_OUT = "# CONFIG_SCHED_CLASS_EXT is not set"
DIAGNOSTIC_MARKER = "ethtool_inventory=omitted_in_local_diagnostic"


class GuestKernelFactsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.full = STOCK_FACTS
        cls.abbreviated, count = re.subn(
            r"(?ms)^ethtool -i (\S+)\n.*?(?=^/sys/class/net/\1/queues/)",
            DIAGNOSTIC_MARKER + "\n", cls.full,
        )
        if count != 2:
            raise ValueError("expected both recorded virtio NICs")

    def capture(self, facts, metrics, *, abbreviated=False, kernel=None):
        home = Path("/private/tmp/test-disposable-worker")
        with patch.object(receiver.relay, "command", return_value=json.dumps(metrics)) as command:
            if abbreviated:
                result = receiver.abbreviated_kernel_facts(home, facts)
            else:
                result = receiver.path_pilot.kernel_facts(
                    receiver.relay, home, facts, kernel or receiver.path_pilot.STOCK,
                )
        command.assert_called_once_with("curl", "--noproxy", "*", "-fsS", "--max-time", "3",
                                        "--unix-socket", str(home / "oci.sock"), "http://localhost/oci/v1/kernel")
        return result

    def test_stock_metrics_generations(self):
        for extra in ({}, {"sched_ext": None}, {"sched_ext": {"state": "disabled"}}):
            with self.subTest(extra=extra):
                self.assertEqual(self.capture(self.full, {"boot": BOOT, **extra})["boot"], BOOT)

    def test_abbreviated_legacy_metrics(self):
        self.assertEqual(self.capture(self.abbreviated, {"boot": BOOT}, abbreviated=True)["boot"], BOOT)

    def test_rejects_active_or_malformed_scheduler(self):
        for facts, abbreviated in ((self.full, False), (self.abbreviated, True)):
            for value in ({"state": "enabled"}, {"state": "unknown"}, {}, "disabled", False):
                with self.subTest(abbreviated=abbreviated, value=value), self.assertRaises(ValueError):
                    self.capture(facts, {"boot": BOOT, "sched_ext": value}, abbreviated=abbreviated)

    def test_legacy_metrics_require_same_boot_and_unambiguous_stock_configuration(self):
        for facts, abbreviated in ((self.full, False), (self.abbreviated, True)):
            for label, invalid in (
                ("stale boot", facts.replace(BOOT, "retired")),
                ("different config", facts.replace(receiver.path_pilot.CONFIG, "0" * 64)),
                ("missing flag", facts.replace(COMPILED_OUT, "")),
                ("conflicting flag", facts + "\nCONFIG_SCHED_CLASS_EXT=y\n"),
            ):
                with self.subTest(abbreviated=abbreviated, label=label), self.assertRaises(ValueError):
                    self.capture(invalid, {"boot": BOOT}, abbreviated=abbreviated)

    def test_candidate_requires_live_scheduler_observation(self):
        kernel = {**receiver.path_pilot.STOCK, "config_sha256": "1" * 64}
        facts = self.full.replace(receiver.path_pilot.CONFIG, kernel["config_sha256"]).replace(
            COMPILED_OUT, "CONFIG_SCHED_CLASS_EXT=y\nCONFIG_EXT_GROUP_SCHED=y")
        observed = {"boot": BOOT, "sched_ext": {"state": "disabled"}}
        self.assertEqual(self.capture(facts, observed, kernel=kernel), observed)
        for absent in ({"boot": BOOT}, {"boot": BOOT, "sched_ext": None}):
            with self.subTest(absent=absent), self.assertRaises(ValueError):
                self.capture(facts, absent, kernel=kernel)


if __name__ == "__main__":
    unittest.main()
