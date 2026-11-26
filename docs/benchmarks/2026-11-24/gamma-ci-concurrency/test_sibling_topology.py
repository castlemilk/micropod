import unittest

import sibling_topology as topology
from qualify import LABEL


class JobNetworkMembershipTest(unittest.TestCase):
    def test_subnets_and_complete_membership_on_both_topologies(self):
        for mode in topology.MODES:
            with self.subTest(mode=mode):
                prefix, owner = "test-grouped", "owner"
                subnets = topology.networks(prefix, mode)
                rows, events, jobs = {}, {}, []
                for idx, (name, subnet) in enumerate(subnets.items(), 1):
                    nid = f"{idx:064x}"
                    rows[name] = {"Id": nid, "Name": name, "Driver": "ipvlan", "Internal": True, "Scope": "local",
                                  "Labels": {LABEL: owner}, "IPAM": {"Config": [{"Subnet": str(subnet)}]}, "Containers": {}}
                    events[name] = {"id": nid, "started_ns": 2 * idx, "finished_ns": 2 * idx + 1}
                for idx in range(2 * topology.PAIRS):
                    side, slot = divmod(idx, topology.PAIRS)
                    name = topology.slot_network(prefix, mode, slot)
                    subnet = subnets[name]
                    ip = str(subnet.network_address + 2 + (side if mode == "per-job" else idx))
                    cid, container = f"{128 + idx:064x}", f"holder-{idx}"
                    link = {"NetworkID": rows[name]["Id"], "IPAddress": ip}
                    jobs.append({"name": container, "id": cid, "ip": ip, "endpoint": {"ipv4": [ip], "default_route": False},
                                 "docker_inspect": {"NetworkSettings": {"Networks": {name: link}}}})
                    rows[name]["Containers"][cid] = {"Name": container, "IPv4Address": f"{ip}/{subnet.prefixlen}"}
                cohort = {"attached_networks": rows, "network_creates": events, "jobs": jobs}
                self.assertEqual(len(topology.check_membership(cohort, owner, prefix, mode)), len(subnets))
                first = next(iter(rows))
                rows[first]["Containers"]["unexpected"] = {"Name": "other", "IPv4Address": "10.0.0.1/28"}
                with self.assertRaisesRegex(ValueError, "unexpected members"):
                    topology.check_membership(cohort, owner, prefix, mode)

    def test_cleanup_checks_all_labeled_networks_before_removal(self):
        commands = []
        def run(*argv):
            commands.append(argv[:2])
            return "different-network"
        with self.assertRaisesRegex(ValueError, "ownership"):
            topology.retire(run, "scope", "owned", "per-job")
        self.assertEqual(commands, [("network", "ls")])
