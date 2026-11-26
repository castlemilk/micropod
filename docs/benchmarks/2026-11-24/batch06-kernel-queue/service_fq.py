"""Test one service-side fq change in each fixed NIC discipline using archived VM observations."""
import hashlib
import json
import re
import sys
from pathlib import Path
from statistics import median

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "scripts/relaybench"))
from gamma_contrasts import paired_median_interval, read_receipt, stream_rates
from irq_affinity_crossover import ARCHIVE, ARCHIVE_SHA, OWNER_FILES, SUFFIXES, order

ARMS = {"stock": ("pfifo_fast", "noqueue"), "podfq": ("pfifo_fast", "fq"),
        "fq": ("fq", "noqueue"), "bothfq": ("fq", "fq")}


def arm(records, block, name):
    prefix = f"queues/{block}-{name}."
    lines = records[prefix + "state"].splitlines()
    if (lines[:2] != ["0-3", "0"] or len(lines) != 7 or lines[-1] != "configured"
            or tuple(line.split()[1] for line in lines[2:4]) != ARMS[name]
            or "rto_min lock 20ms congctl reno" not in lines[5]):
        raise ValueError(f"mismatched settings at {prefix}")
    data = records[prefix + "json"]
    fresh = data["fresh"]
    if (records[prefix + "err"].strip() or data["mode"] != "mixed" or fresh["iterations"] != 100
            or fresh["incomplete_phase_samples"] or data["streams"] != 32 or
            any(data[k] != 0 for k in ("warmup_reopens","overlap_reopens","drain_reopens","reopened_connections"))):
        raise ValueError(f"inspect first-attempt error at {prefix}")
    stream_rates(dict(bytes=data["overlap_bytes"], per_stream_bytes=data["overlap_bytes_per_stream"]),
                 data["overlap_s"], data["overlap_mib_s"])
    normalized = [re.sub(r"^(qdisc \S+ )\S+( root )", r"\1<handle>\2", line).strip() for line in lines[2:4]]
    return dict(record=prefix+"json", position=order(block).index(name)+1,
                irq=lines[0:2], route=lines[4:6], nic_qdisc=normalized[0], service_qdisc=normalized[1],
                mib_s=data["overlap_mib_s"], mib=data["overlap_bytes"]/2**20, elapsed_s=data["overlap_s"],
                p95_ms=fresh["complete_ns"]["p95"]/1e6, p99_ms=fresh["complete_ns"]["p99"]/1e6,
                completed=fresh["iterations"], incomplete=fresh["incomplete_phase_samples"], reopened=data["reopened_connections"])


def run():
    d = read_receipt(ARCHIVE, ARCHIVE_SHA)
    r = d["records"]
    keys = {f"queues/{i}-{name}.{ext}" for i in range(4) for name in ARMS for ext in SUFFIXES}
    names = "|".join(ARMS)
    assert keys == {k for k in r if re.match(rf"queues/\d+-(?:{names})\.", k)}
    assert r["trial.boot"]["cpus"] == 4 and r["trial.limits"]["cpu.max"] == "400000 100000"
    assert "numtxqueues 1 numrxqueues 1" in r["queues/init"] and r["queues/restored"].splitlines()[:2] == ["0-3","0"]
    rows = [{name: arm(r,i,name) for name in ARMS} for i in range(4)]
    strata = []
    for before, after in [("stock","podfq"), ("fq","bothfq")]:
        diffs = []
        for row in rows:
            a,b = row[before],row[after]
            assert all(a[k]==b[k] for k in ("route","irq","nic_qdisc"))
            assert a["service_qdisc"].startswith("qdisc noqueue") and "flow_limit 100p" in b["service_qdisc"]
            diffs.append(100*(b["mib_s"]/a["mib_s"]-1))
        arms = {k: {v:median(row[k][v] for row in rows) for v in ("mib_s","p95_ms","p99_ms")} |
                {"p95_le_75ms":sum(row[k]["p95_ms"] <= 75 for row in rows)} for k in (before,after)}
        strata.append(dict(nic=ARMS[before][0], arms=arms, paired_pct=diffs, median_pct=median(diffs),
                           ci95_pct=paired_median_interval(diffs), wins=sum(x>0 for x in diffs)))
    return dict(direction="231.08", tier="archived VM, raw-verified", replay_base="17bcd4355234b11da3a7a1da2ded52f4dc20f5d1",
                archive=ARCHIVE.name,archive_sha256=ARCHIVE_SHA,archive_revision="692ace081c989f80fb2bce27a5a13af13098b77c",
                experiment_base="4f887ba5d28f47fa37d4bd0a2d89cd0914d74754",original_driver_hashes=OWNER_FILES,
                replay_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), image=d["platform"]["image_sha256"],
                rows=rows, strata=strata)

if __name__ == "__main__":
    print(json.dumps(run(), indent=2))
