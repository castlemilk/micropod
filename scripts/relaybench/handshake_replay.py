"""Replay guest-side SYN observations from Gamma's archived Linux 6.18.35 diagnostics.

Only guest-in and guest-out rows from the outer guest interface are counted.
For empty initial SYNs, match the reversed four-tuple and ACK = ISN + 1,
requiring a reply timestamp at or after the SYN. Collapse retransmissions by
four-tuple and ISN. Report the earliest observed flags on each side. Neither
the Accurate ECN bit in TCP header byte 12 nor TCP options were retained.
"""
import hashlib
import json
from collections import Counter

from gamma_contrasts import ROOT, read_receipt


ARCHIVE = ROOT / "docs/benchmarks/2026-11-21/gamma-mixed-scheduler.json.gz"
DIGEST = "9e3b184de862aafacff47312878441e940d030e8cfc8342c0e479d064f4724c8"
CAPTURES = ("eof/headers.jsonl", "inprocess-eof/headers.jsonl", "uncapped-wire/headers.jsonl", "reset-origin/1/syn.jsonl")
SYN = 0x02
ACK = 0x10


def summarize(records):
    initial_flags, reply_flags = Counter(), Counter()
    empty_syns = {}
    replies = []
    payload_packets = payload_bytes = 0
    stats = {}
    for packet in records:
        if "interface" in packet:
            stats[packet["interface"]] = {"packets": packet["packets"], "drops": packet["drops"]}
            continue
        flags = packet.get("flags", 0)
        if not flags & SYN:
            continue
        flags_byte = f"0x{flags:02x}"
        endpoints = (packet["src"], packet["sport"], packet["dst"], packet["dport"])
        if packet["stage"] == "guest-in" and not flags & ACK:
            initial_flags[flags_byte] += 1
            if packet["bytes"] > 0:
                payload_packets += 1
                payload_bytes += packet["bytes"]
            else:
                key = (*endpoints, packet["seq"])
                obs = (packet["ns"], flags_byte)
                if key not in empty_syns or obs < empty_syns[key]:
                    empty_syns[key] = obs
        elif packet["stage"] == "guest-out" and flags & ACK:
            reply_flags[flags_byte] += 1
            key = (*endpoints[2:], *endpoints[:2], (packet["ack"] - 1) % (1 << 32))
            replies.append((packet["ns"], key, flags_byte))

    first_replies = {}
    for time_ns, key, flags_byte in sorted(replies):
        if key in empty_syns and time_ns >= empty_syns[key][0]:
            first_replies.setdefault(key, flags_byte)
    patterns = Counter(f"{empty_syns[key][1]} -> {flags}" for key, flags in first_replies.items())
    return {
        "capture_counters": stats,
        "guest_initial_syn_packets": sum(initial_flags.values()),
        "guest_initial_syn_flags": dict(sorted(initial_flags.items())),
        "guest_initial_syns_with_payload": payload_packets,
        "guest_initial_syn_payload_bytes": payload_bytes,
        "guest_out_syn_ack_flags": dict(sorted(reply_flags.items())),
        "distinct_empty_syn_tuple_isns": len(empty_syns),
        "empty_syn_tuple_isns_with_matching_syn_ack": len(first_replies),
        "empty_syn_tuple_isns_without_matching_syn_ack": len(empty_syns) - len(first_replies),
        "first_observed_flag_pairs": dict(sorted(patterns.items())),
    }


def replay():
    archive = read_receipt(ARCHIVE, DIGEST)
    captures = {}
    for name in CAPTURES:
        raw = archive["records"][name]
        captures[name] = {"jsonl_sha256": hashlib.sha256(raw.encode()).hexdigest(),
                          **summarize(map(json.loads, raw.splitlines()))}
    return {"archive": ARCHIVE.name, "archive_sha256": DIGEST, "recorded_at": archive["timestamp"],
            "guest_kernel": archive["platform"]["guest_kernel"], "captures": captures}


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2))
