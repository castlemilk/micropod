import copy
import unittest

from gamma_contrasts import ROOT, read_receipt
from guest_link_path import check, counters


class GuestLinkCoverageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.records = read_receipt(ROOT / "docs/benchmarks/2026-11-21/gamma-direct-macvlan.json.gz",
                                   "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976")["records"]
        cls.client = cls.records["matched"]["1"]["engines"]["direct"]["client"]

    def setUp(self):
        state = {"boot_id": "597eaa71-341b-44d8-b3b6-5b425b34f9a2", "netns": "net:[1202]",
                 "monotonic_ns": 1, "links": []}
        for idx, name, kind in ((2, "eth0", "veth"), (3, "mppub0", "macvlan")):
            state["links"].append({"ifindex": idx, "ifname": name, "address": f"02:00:00:00:00:0{idx}",
                                   "linkinfo": {"info_kind": kind, "info_data": {"mode": "private"} if idx == 3 else {}},
                                   "stats64": {"rx": {"bytes": 32}, "tx": {"bytes": 64}}})
        self.final = copy.deepcopy(state)
        self.final["monotonic_ns"] = 6_050_000_001
        self.final["links"][0]["stats64"]["tx"]["bytes"] += 350
        self.final["links"][1]["stats64"]["tx"]["bytes"] += self.client["bytes"]
        self.capture = {"before": state, "after": self.final, "client": self.client}

    def prove(self):
        return check(self.capture, "mppub0", "macvlan", "tx", "private")

    def test_direction_coverage_and_competing_counters(self):
        report = self.prove()
        self.assertEqual(report["other_interfaces_with_traffic"], {"eth0": 350})
        self.assertEqual(report["other_interfaces_covering_payload"], [])
        self.final["links"][0]["stats64"]["tx"]["bytes"] += self.client["bytes"]
        self.assertEqual(self.prove()["other_interfaces_covering_payload"], ["eth0"])
        with self.assertRaisesRegex(ValueError, "does not cover"):
            check(self.capture, "mppub0", "macvlan", "rx")

    def test_actual_archive_counters(self):
        # This older receipt has before/after MACs and counters, but no link kind or ifindex.
        worker = self.records["workers"]["direct"]
        before, after = (worker[key]["interfaces"] for key in ("start-scoring", "end-scoring"))
        direct = counters(before["mppub0"], after["mppub0"])
        self.assertEqual(direct["tx_bytes"], 478377036186)
        self.assertEqual(counters(before["eth0"], after["eth0"])["tx_bytes"], 70)
        self.assertNotIn("ifindex", before["mppub0"])

    def test_changed_boot_namespace_identity_or_counter(self):
        for field, value in (("netns", "net:[1203]"), ("boot_id", "728ef2ec-14ba-40b6-8d39-58cf647cad94")):
            altered = copy.deepcopy(self.capture)
            altered["after"][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "changed"):
                check(altered, "mppub0", "macvlan", "tx")
        for key, value in (("ifindex", 9), ("address", "06:00:00:00:00:03")):
            altered = copy.deepcopy(self.capture)
            altered["after"]["links"][1][key] = value
            with self.subTest(field=key), self.assertRaisesRegex(ValueError, "identity changed"):
                check(altered, "mppub0", "macvlan", "tx")
        self.final["links"][1]["stats64"]["rx"]["bytes"] = 1
        with self.assertRaisesRegex(ValueError, "decreasing"):
            self.prove()

    def test_wrong_device_kind_mode_or_unfinished_transfer(self):
        for device, kind, mode in (("eth0", "veth", None), ("mppub0", "ipvlan", None), ("mppub0", "macvlan", "bridge")):
            with self.subTest(device=device, kind=kind, mode=mode), self.assertRaises(ValueError):
                check(self.capture, device, kind, "tx", mode)
        self.final["monotonic_ns"] = 2
        with self.assertRaisesRegex(ValueError, "shorter than"):
            self.prove()
        self.capture["client"] = dict(self.client, errors=["EOF"])
        with self.assertRaisesRegex(ValueError, "complete"):
            self.prove()
