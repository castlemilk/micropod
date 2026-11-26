import json
import unittest

from handshake_replay import ROOT, replay, summarize


def packet(stage, ns, seq, ack, flags, size=0, port=8900):
    src, sport, dst, dport = ("host", port, "guest", 8080)
    if stage == "guest-out":
        src, sport, dst, dport = dst, dport, src, sport
    return dict(stage=stage, ns=ns, seq=seq, ack=ack, flags=flags, bytes=size,
                src=src, sport=sport, dst=dst, dport=dport)


class HandshakeReplayTests(unittest.TestCase):
    def test_retransmission_wraparound_reordered_output_and_two_capture_interfaces(self):
        syn = packet("guest-in", 10, 0xffffffff, 0, 0xc2)
        rows = [packet("guest-out", 21, 5, 0, 0x12), dict(syn, stage="to-container"),
                dict(syn, ns=15, flags=0x02), packet("guest-out", 20, 5, 0, 0x52), syn,
                packet("guest-in", 30, 25, 0, 0x02), packet("guest-out", 29, 8, 26, 0x12),
                packet("guest-out", 33, 8, 26, 0x12, port=8901)]
        summary = summarize(rows)
        self.assertEqual(summary["guest_initial_syn_packets"], 3)
        self.assertEqual(summary["distinct_empty_syn_tuple_isns"], 2)
        self.assertEqual(summary["empty_syn_tuple_isns_without_matching_syn_ack"], 1)
        self.assertEqual(summary["first_observed_flag_pairs"], {"0xc2 -> 0x52": 1})

    def test_payload_and_capture_loss_stay_visible(self):
        summary = summarize([packet("guest-in", 1, 25, 0, 0x02, 64),
                             packet("guest-out", 2, 5, 90, 0x12), {"interface": "eth1", "drops": 2, "packets": 4}])
        self.assertEqual(summary["guest_initial_syns_with_payload"], 1)
        self.assertEqual(summary["guest_initial_syn_payload_bytes"], 64)
        self.assertEqual(summary["distinct_empty_syn_tuple_isns"], 0)
        self.assertEqual(summary["capture_counters"]["eth1"]["drops"], 2)

    def test_archived_receipt_replays(self):
        receipt = ROOT / "docs/benchmarks/2026-11-23/guest-handshake-replay.json"
        self.assertEqual(replay(), json.loads(receipt.read_text()))
