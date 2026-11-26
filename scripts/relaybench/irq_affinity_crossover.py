"""Replay the effective IRQ CPU crossover on the same four-vCPU publication NIC."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from statistics import median

from gamma_contrasts import ROOT, read_receipt, stream_rates

ARCHIVE = ROOT / "docs/benchmarks/2026-11-21/gamma-mixed-path.json.gz"
ARCHIVE_SHA = "09ebe5510401244cd6d299c1d0cf6dd8f88b256bf14b8c2c14f6db3eff61b74a"
OWNER_FILES = {
    "queue-screen.sh": "e091c9d50bca0433ffd9ecb2363914b80c6a18e57593f5cefd2e1f381cb177d9",
    "candidate-tools/runner/vnic-action.sh": "e1fa881926558a3e32a5af7df69b999c2afb17b18ddaeddd12f1deb4457236f0",
    "netbench": "b6850b2d05cedbd2b08d30525f675551504007c8374ecc38e02eb5f84af32f1f",
}
ROTATION = ("stock", "irq", "fq", "podfq", "bothfq", "irqfq", "gso", "bbrfq")
SUFFIXES = ("json", "err", "load", "state")


def order(block):
    # The eight-arm archived driver rotated three positions and reversed odd blocks.
    positions = [(i + 3 * block) % len(ROTATION) for i in range(len(ROTATION))]
    return [ROTATION[7 - i if block % 2 else i] for i in positions]


def snapshot(records, block, arm, pinned, fair):
    prefix = f"queues/{block}-{arm}."
    lines = records[prefix + "state"].splitlines()
    affinities = ["3", "3"] if pinned else ["0-3", "0"]
    if lines[:2] != affinities or lines[-1] != "configured":
        raise ValueError(f"IRQ readback mismatch at {prefix}")
    if len(lines) != 7 or "rto_min lock 20ms congctl reno" not in lines[5]:
        raise ValueError(f"unexpected route at {prefix}")
    expected = ["fq", "fq"] if fair else ["pfifo_fast", "noqueue"]
    if [line.split()[1] for line in lines[2:4]] != expected:
        raise ValueError(f"unexpected NIC/service queue settings at {prefix}")
    # tc allocates a new handle after replacing fq. Keep every other setting and
    # handle position intact so the paired check catches e.g. a quantum change.
    qdiscs = [re.sub(r"^(qdisc \S+ )\S+( root )", r"\1<handle>\2", line).strip()
              for line in lines[2:4]]
    state = dict(nic_qdisc=qdiscs[0], service_qdisc=qdiscs[1], service_route=lines[4:6])
    c = records[prefix + "json"]
    f = c["fresh"]
    if (records[prefix + "err"].strip() or c["mode"] != "mixed" or f["iterations"] != 100
            or f["incomplete_phase_samples"] != 0 or c["streams"] != 32
            or any(c[k] != 0 for k in ("reopened_connections", "warmup_reopens", "overlap_reopens", "drain_reopens"))):
        raise ValueError(f"unexpected attempt or incomplete historical record at {prefix}; account explicitly")
    stream_rates({"bytes": c["overlap_bytes"], "per_stream_bytes": c["overlap_bytes_per_stream"]},
                 c["overlap_s"], c["overlap_mib_s"])
    return dict(record=prefix + "json", requested=lines[0], effective=lines[1], fixed_settings=state,
                fresh_completed=f["iterations"], fresh_incomplete=f["incomplete_phase_samples"],
                reopens=c["reopened_connections"], mib_s=c["overlap_mib_s"], bulk_bytes=c["overlap_bytes"],
                window_s=c["overlap_s"], p95_ms=f["complete_ns"]["p95"] / 1e6,
                p99_ms=f["complete_ns"]["p99"] / 1e6)


def comparison(records, before, after, fair):
    prefixes = {f"queues/{block}-{arm}.{suffix}" for block in range(4)
                for arm in (before, after) for suffix in SUFFIXES}
    selected = {k for k in records if re.match(rf"queues/\d+-(?:{before}|{after})\.", k)}
    if selected != prefixes:
        raise ValueError("attempt population differs from all four planned blocks")
    rows = []
    for block in range(4):
        a = snapshot(records, block, before, False, fair)
        b = snapshot(records, block, after, True, fair)
        if a["fixed_settings"] != b["fixed_settings"]:
            raise ValueError("more than IRQ placement changed within a pair")
        arms = order(block)
        rows.append(dict(block=block, positions=[arms.index(before) + 1, arms.index(after) + 1],
                         control=a, cpu3=b, throughput_change_pct=100 * (b["mib_s"] / a["mib_s"] - 1)))
    changes = [r["throughput_change_pct"] for r in rows]
    medians = {k: {m: median(r[k][m] for r in rows) for m in ("mib_s", "p95_ms", "p99_ms")}
               for k in ("control", "cpu3")}
    return dict(arms=[before, after], pairs=rows, clean_pairs=len(rows), medians=medians,
                p95_within_75ms={k: sum(r[k]["p95_ms"] <= 75 for r in rows) for k in medians},
                faster_cpu3=sum(x > 0 for x in changes), median_change_pct=median(changes),
                observed_range_pct=[min(changes), max(changes)])


def replay():
    d = read_receipt(ARCHIVE, ARCHIVE_SHA)
    r = d["records"]
    if (r["trial.boot"]["cpus"] != 4 or r["trial.limits"]["cpu.max"] != "400000 100000"
            or r["trial.limits"]["cpuset.cpus.effective"] != "0-3"
            or not all(x in r["queues/init"] for x in ("eth1:", "mtu 1500", "numtxqueues 1 numrxqueues 1",
                                                      "parentbus virtio parentdev virtio1"))
            or r["queues/restored"].splitlines()[:2] != ["0-3", "0"]):
        raise ValueError("boot, service or restored IRQ fixture changed")
    return dict(date="2026-11-24", direction="237.05", tier="Offline replay of archived VM observations",
                archive=ARCHIVE.name, archive_sha256=ARCHIVE_SHA,
                archive_revision="692ace081c989f80fb2bce27a5a13af13098b77c",
                experiment_base="4f887ba5d28f47fa37d4bd0a2d89cd0914d74754",
                replay_base="a3b561c6a97320d4ca9aff60885ae6393ccaa613",
                replay_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                original_driver_sources_sha256=OWNER_FILES,
                platform=d["platform"], boot=r["trial.boot"]["boot"], image_sha256=d["platform"]["image_sha256"],
                control="Guest publication NIC IRQ requested 0-3, effective CPU 0.",
                candidate="Request CPU 3 on that IRQ; effective CPU 3 before every included attempt.",
                workload="One guest and service, 32 ongoing downloads and 100 closed-loop fresh requests per "
                         "attempt. Two verified separate qdisc conditions in the same four rotated blocks. "
                         "Do not pool the contrasts. Limits/route fixed. All 16 included first attempts retained.",
                stock_qdiscs=comparison(r, "stock", "irq", False),
                fair_qdiscs=comparison(r, "bothfq", "irqfq", True),
                limits="Ranges describe the four paired changes within a stratum. No independent confidence "
                       "interval, scored-window NIC drops, IRQ residence, per-process CPU/GiB, runnable time "
                       "or CPU 1 treatment. Closed-loop latency starts at the request. IRQ affinity reads do "
                       "not measure per-CPU interrupt distribution throughout scoring.",
                verdict="A CPU 3 pin won two of four pairs in either queue setup. Keep stock affinity. Bind "
                        "per-CPU IRQ deltas to the scored interval and verify the actual online CPUs before a "
                        "separate CPU 1 trial on the revised worker.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner-root", type=Path, help="optionally verify retained original driver/binary bytes")
    args = parser.parse_args()
    if args.owner_root:
        for name, expected in OWNER_FILES.items():
            if hashlib.sha256((args.owner_root / name).read_bytes()).hexdigest() != expected:
                raise ValueError(f"unexpected owner bytes in {name}")
    print(json.dumps(replay(), indent=2, allow_nan=False))
