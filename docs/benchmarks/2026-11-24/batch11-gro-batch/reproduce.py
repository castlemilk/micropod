"""Exercise Linux's original folded GRO segment-count batching and NAPI completion."""
import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
HASHES = {
    "include/net/gro.h": "b535246a33dc3afb3596916bad9d2d368db401ed48f8b219ef0d5ed0b54c84ad",
    "net/core/gro.c": "1b1e8d1db28f7b79e4cec43d85cd3f19893d8ba64aba8488ea77a4638fe0a961",
    "net/core/dev.c": "8b3c43e8becfd552ead597c2e009edf16b126924a7cbe4c5c961e74563b76274",
    "net/core/hotdata.c": "4eb475935e2797ed959bbbddf6d505a394e04c10bece65a726b829e03935d209",
    "net/core/sysctl_net_core.c": "5d12437f760382ba86724c1ab1809fcf1a4058fc5e433d1a347b8cf97e0d0b99",
}
CASES = {
    # Each entry receives one SKB representing the given number of TCP segments.
    # The marked singleton represents a separate small response or ACK on this receive queue.
    "32 singletons, eighth marked": ([1] * 32, 8),
    "five singletons, first marked": ([1] * 5, 1),
    "seven-segment aggregate then one small SKB, four repetitions": ([7, 1] * 4, 2),
    "sixteen-segment aggregates interleaved with singletons": ([16, 1] * 4, 2),
    "eight-segment aggregate then seven singletons": ([8] + [1] * 7, 2),
}


def original(text, header):
    p = text.index(header)
    return text[p:text.index("\n}", p) + 2]


def modeled(segments, threshold):
    groups = []
    first, count = 1, 0
    for index, n in enumerate(segments, 1):
        count += n
        if count >= threshold:
            groups.append([index, "enqueue", list(range(first, index + 1))])
            first, count = index + 1, 0
    if count:
        groups.append([len(segments), "complete", list(range(first, len(segments) + 1))])
    return groups


def measure(binary, segments, marked, threshold):
    output = subprocess.check_output([str(binary), str(threshold), *map(str, segments)], text=True)
    groups = []
    for line in output.splitlines():
        position, source, *ids = line.split()
        groups.append([int(position), source, list(map(int, ids))])
    assert groups == modeled(segments, threshold)
    delivery = next(g for g in groups if marked in g[2])
    return dict(threshold=threshold, list_dispatches=len(groups), marked_skb_handoff=delivery[0],
                later_skb_offers_before_handoff=delivery[0] - marked, dispatches=groups)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("kernel", type=Path)
    args = parser.parse_args()
    raw = {name:(args.kernel/name).read_bytes() for name in HASHES}
    assert {k:hashlib.sha256(b).hexdigest() for k,b in raw.items()} == HASHES
    text = {k:b.decode() for k,b in raw.items()}
    assert re.search(r"\.gro_normal_batch\s*=\s*8\b",text["net/core/hotdata.c"])
    assert re.search(r'\.procname\s*=\s*"gro_normal_batch",\s*\.data\s*=\s*&net_hotdata.gro_normal_batch',text["net/core/sysctl_net_core.c"])
    assert "gro_normal_one(gro, skb, NAPI_GRO_CB(skb)->count);" in text["net/core/gro.c"]
    assert "case GRO_NORMAL:\n\t\tgro_normal_one(gro, skb, 1);" in text["net/core/gro.c"]
    originals = [original(text["include/net/gro.h"], "static inline void " + fn + "(")
                 for fn in ("gro_flush", "gro_normal_list", "gro_flush_normal", "gro_normal_one")]
    originals.append(original(text["net/core/dev.c"], "bool napi_complete_done("))
    rows = []
    with tempfile.TemporaryDirectory() as d:
        temp = Path(d)
        (temp/"linux-gro.inc").write_text("\n".join(originals))
        binary = temp/"gro"
        subprocess.run([os.environ.get("CC","cc"), "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I", str(temp), str(HERE/"fixture.c"), "-o", str(binary)], check=True)
        for name, (segments, marked) in CASES.items():
            assert segments[marked - 1] == 1
            rows.append(dict(workload=name, segment_counts=segments, marked_skb=marked,
                             skbs=len(segments), segments=sum(segments),
                             arms=[measure(binary,segments,marked,n) for n in (8,16)]))
    print(json.dumps(dict(micropod_revision="2e9b37c1e68334c443d71b729f0bd6334d824ddd", source_sha256=HASHES,
                          calls_compiled=["gro_normal_one","gro_normal_list","gro_flush_normal","gro_flush","napi_complete_done"],
                          workloads=rows), indent=2))


if __name__ == "__main__":
    main()
