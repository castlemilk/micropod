import unittest

from guest_network_config import assess, gamma_stock


class GuestNetworkConfigTests(unittest.TestCase):
    def test_pinned_stock_distinguishes_the_optional_paths(self):
        report = gamma_stock()
        self.assertEqual(report["recorded_release"], "7.3.5-micropod")
        results = report["build_prerequisites"]
        for name in ("private macvlan with workload veth", "netkit peer redirect",
                     "netkit io_uring zero-copy RX", "IPv4 TCP pipe splice",
                     "SOCKMAP and SOCKHASH", "BPF socket stream parser"):
            with self.subTest(name=name):
                self.assertEqual(results[name]["state"], "built-in prerequisites")
        for name in ("ipvlan L2 or L3", "netkit AF_XDP"):
            self.assertEqual(results[name]["state"], "disabled prerequisite")

    def test_module_and_missing_settings_do_not_establish_builtin_support(self):
        report = assess(b"CONFIG_ARM64=y\nCONFIG_MACVLAN=m\nCONFIG_VETH=y\nCONFIG_NETKIT=y\n")
        results = report["build_prerequisites"]
        self.assertEqual(results["private macvlan with workload veth"]["state"], "module required")
        self.assertEqual(results["netkit AF_XDP"], {
            "state": "unrecorded prerequisite", "settings": {"CONFIG_NETKIT": "y", "CONFIG_XDP_SOCKETS": None}})

    def test_invalid_or_duplicate_effective_settings(self):
        for config in (b"CONFIG_ARM64=y\nCONFIG_NETKIT=1", b"CONFIG_ARM64=y\nCONFIG_NETKIT=y\nCONFIG_NETKIT=m",
                       b"CONFIG_X86=y\nCONFIG_VETH=y"):
            with self.subTest(config=config), self.assertRaises(ValueError):
                assess(config)
