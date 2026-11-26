"""Replay one-queue qdisc batching through Linux 7.3.5's virtio-net/DQL transmit path."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
PREVIOUS = HERE.parent / "batch07-nic"
sys.path.insert(0, str(PREVIOUS))
import kernel_queue

SOURCES = {
    **kernel_queue.SOURCE,
    "qdisc": ("net/sched/sch_generic.c", "5396cd77c6e674722da773c652e0309e594c46df4afd467206a70d166c825160"),
    "sch_h": ("include/net/sch_generic.h", "8d0311e110ca9796231c5aa017b9846c3a2dc6bb82fe30b7ef8b111c90d08025"),
}
QDISC_FUNCS = [
    ("netdevice", "static inline int netdev_queue_dql_avail"),
    ("netdevice", "static inline bool dev_xmit_complete"),
    ("sch_h", "static inline bool qdisc_may_bulk"),
    ("sch_h", "static inline int qdisc_avail_bulklimit"),
    ("qdisc", "static u16 qdisc_cap_skb_tx_queue"),
    ("qdisc", "static void try_bulk_dequeue_skb"),
    ("dev", "struct sk_buff *dev_hard_start_xmit"),
]
BASE = "c9ec734fc9692e31ca99122fe13c9b71a5478c80"
TAR = "8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fragment(members, functions):
    parts = []
    for key, sig in functions:
        source = members[key]
        start = source.index(b"\n" + sig.encode() + b"(") + 1
        end = source.index(b"\n}\n", start) + 3
        parts.append(source[start:end])
    return b"\n".join(parts)


def run(tree):
    members = {key: (tree / path).read_bytes() for key, (path, _) in SOURCES.items()}
    for key, (path, expected) in SOURCES.items():
        if sha(members[key]) != expected:
            raise ValueError(f"Linux member mismatch: {path}")

    original = (PREVIOUS / "tx_bql.c").read_bytes()
    if sha(original) != "0ecdac50861b48953e4f88bcc6cb8d2b211045f717b3c77eee431b96b5254294":
        raise ValueError("batch seven's fixture changed")
    prefix = original.split(b'#include "linux_functions.inc"', 1)[0]
    prefix = prefix.replace(b"struct sk_buff {unsigned int len;};",
                            b"struct sk_buff {unsigned int len; struct sk_buff *next;};")
    prefix = prefix.replace(b"#define netdev_xmit_more() false",
                            b"static bool current_more;\n#define netdev_xmit_more() current_more")
    driver = fragment(members, kernel_queue.FUNCTIONS["tx_bql"])
    qdisc = fragment(members, QDISC_FUNCS)
    harness = HERE / "qdisc_bulk.c"
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for name, data in (("previous_fixture.inc", prefix), ("driver.inc", driver), ("qdisc.inc", qdisc)):
            (work / name).write_bytes(data)
        exe = work / "qdisc_bulk"
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-I", str(work),
                        str(harness), "-o", str(exe)], check=True)
        lines = subprocess.check_output([exe], text=True).splitlines()

    rows = {}
    for line in lines:
        size, bulk, first, count, ring, charged, kicks, stopped = map(int, line.split())
        key = size, bulk
        row = rows.setdefault(key, {"skb_bytes": size, "chaining": bool(bulk), "dequeues": []})
        row["dequeues"].append(dict(first_offer_zero_based=first, packets=count, cumulative_ring_bytes=ring,
                                    cumulative_dql_charged_bytes=charged, notifications=kicks, stopped=bool(stopped)))
    if len(rows) != 8:
        raise ValueError("incomplete fixed-work comparison")
    for row in rows.values():
        groups = row["dequeues"]
        row["submitted_skbs"] = sum(g["packets"] for g in groups)
        row["notifications"] = sum(g["notifications"] for g in groups)
        row["left_upstream"] = 32 - row["submitted_skbs"]

    return dict(date="2026-11-24", direction="231.08", tier="source/fixture", micropod_base=BASE,
                linux_version="7.3.5", linux_tar_sha256=TAR,
                kernel_member_sha256={p: h for p, h in SOURCES.values()},
                fragment_sha256={"qdisc": sha(qdisc), "driver": sha(driver), "prefix": sha(prefix)},
                source_sha256={p.name: sha(p.read_bytes()) for p in
                               (harness, Path(__file__), PREVIOUS / "tx_bql.c", PREVIOUS / "kernel_queue.py")},
                compiler=subprocess.check_output(["cc", "--version"], text=True).splitlines()[0],
                fixed=dict(offers=32, initial_dql_allowance_bytes=524288, tx_napi_weight=64, ring_entries=256,
                           tx_queue=0, completions=0, dequeue_budget=64, device_accepts_each_requested_notification=True),
                arms="One-buffer dispatch versus Linux ONETXQUEUE qdisc bulk-dequeue before identical driver calls.",
                observations=list(rows.values()))


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("linux_tree", type=Path)
    print(json.dumps(run(cli.parse_args().linux_tree), indent=2))
