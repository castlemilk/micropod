import tempfile
import unittest
from pathlib import Path
from unittest import mock

import guest_paths


class GuestPathTests(unittest.TestCase):
    incoming = ("192.0.2.2:8080", "192.0.2.1:50000")
    outgoing = ("10.88.0.2:12345", "10.88.0.2:8080")
    header = " sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n"
    in_row = "0: 020200C0:1F90 010200C0:C350 01 0:0 00:0 0 0 0 90\n"
    out_row = "0: 0200580A:3039 0200580A:1F90 01 0:0 00:0 0 0 0 91\n"

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.proc = Path(temp.name)
        boot = self.proc / "sys/kernel/random/boot_id"
        boot.parent.mkdir(parents=True)
        boot.write_text("2ce98b61-7054-483a-865b-14bcd495145b\n")
        for pid, ns, row in ((1, 404, self.in_row), (63, 421, self.out_row)):
            p = self.proc / str(pid)
            (p / "ns").mkdir(parents=True)
            (p / "net").mkdir()
            (p / "ns/net").symlink_to(f"net:[{ns}]")
            (p / "net/tcp").write_text(self.header + row)
            (p / "stat").write_text(f"{pid} (bench) guest) S " + "0 " * 18 + "555\n")
        self.fds = self.proc / "63/fd"
        self.fds.mkdir()
        (self.fds / "6").symlink_to("socket:[90]")
        (self.fds / "7").symlink_to("socket:[91]")

    def check_pair(self):
        return guest_paths.check(self.proc, 63, 1, 63, self.incoming, self.outgoing)

    def test_distinct_namespaces_and_owner(self):
        result = self.check_pair()
        self.assertEqual(result["forwarder"], {"pid": 63, "start_ticks": 555, "netns": "net:[421]"})
        self.assertEqual(result["legs"]["incoming"]["inode"], 90)
        self.assertEqual(result["legs"]["outgoing"]["inode"], 91)
        self.assertEqual(result["legs"]["incoming"]["netns"], "net:[404]")

    def test_socket_owned_by_another_process(self):
        (self.fds / "7").unlink()
        with self.assertRaisesRegex(ValueError, "own both"):
            self.check_pair()

    def test_listener_other_flow_or_duplicate(self):
        for row in (self.in_row.replace(" 01 ", " 0A "), self.in_row.replace("C350", "C351"),
                    self.in_row * 2):
            with self.subTest(row=row), self.assertRaisesRegex(ValueError, "one established"):
                (self.proc / "1/net/tcp").write_text(self.header + row)
                self.check_pair()

    def test_reused_inode_cannot_make_two_legs(self):
        (self.proc / "63/net/tcp").write_text(self.header + self.out_row.replace(" 91", " 90"))
        with self.assertRaisesRegex(ValueError, "both distinct"):
            self.check_pair()

    def test_process_replaced_during_sampling(self):
        get_fds = guest_paths.socket_inodes
        def replace_owner(owner):
            previous = get_fds(owner)
            (owner / "stat").write_text((owner / "stat").read_text().replace("555", "777"))
            return previous
        with mock.patch.object(guest_paths, "socket_inodes", side_effect=replace_owner):
            with self.assertRaisesRegex(ValueError, "changed"):
                self.check_pair()
