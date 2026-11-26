"""Replay stock polling with CUBIC vs Reno, preserving per-stream delivery and all attempts."""
import argparse
import gzip
import hashlib
import json
import random
from pathlib import Path
from statistics import median
import subprocess
import sys

HERE = Path(__file__).resolve().parent
TREE = HERE.parents[3]
sys.path.insert(0, str(TREE / "scripts/relaybench"))
from gamma_contrasts import clean_client, process_delta, stream_rates

REV = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
ARCH = "docs/benchmarks/2026-11-21/gamma-vm-scheduling.json.gz"
SHA = "29f33979ca570117e54addabfe07aecb452ab23af7f0b9e039c996dbb9611e51"
MIB = 2 ** 20
GIB = 2 ** 30


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git_bytes(path):
    return subprocess.check_output(["git", "show", f"{REV}:{path}"], cwd=TREE)


def paired(rows, metric):
    a = [r["reno"][metric] for r in rows]
    b = [r["cubic"][metric] for r in rows]
    ratios = [100 * (y / x - 1) for x,y in zip(a,b)]
    rng = random.Random(20261124)
    boot = sorted(median(rng.choices(ratios, k=len(rows))) for _ in range(10000))
    return {"reno_median": median(a), "cubic_median": median(b),
            "paired_median_percent": median(ratios), "wins": sum(y>x for x,y in zip(a,b)),
            "paired_bootstrap_95_percent": [boot[249],boot[9749]]}


def replay(target):
    archive = git_bytes(ARCH)
    assert digest(archive) == SHA
    source = json.loads(gzip.decompress(archive))
    recording = subprocess.check_output(["git", "rev-parse", source["baseline_commit"] + "^{commit}"], cwd=TREE, text=True).strip()
    assert recording == "7a4eb51a04b51f6332ed49561b3dd0bb42ffacd9"
    scope = source["scopes"]["lab-0"]
    assert scope["boot-policy"].splitlines()[:2] == ["0", "0"]
    assert scope["vm"].split()[:3] == ["4","4116488192",'"7.3.5-micropod-cc"']
    assert scope["image"] == "sha256:80996a25c9c753fcaf3f421a3f61557497b8ab539bdd68076074d181cfa71889"
    proofs = scope["controller_proofs"]
    stable = []
    for cc in ["reno", "cubic"]:
        proof = proofs[cc]
        assert proof["accepted_socket"] == proof["route"]["Congctl"] == cc
        assert proof["route"]["Dst"]["Mask"] == "/////w=="
        state = proof["state"]
        assert [state[k] for k in ["cpu.max", "cpuset.cpus.effective", "memory.max", "pids.max"]] == [
            "400000 100000", "0-3", "1073741824", "512"]
        stable.append({k:v for k,v in proof["route"].items() if k not in {"Congctl", "Src"}})
    assert stable[0] == stable[1]
    series = source["records"]["guest-screen"]
    assert set(series) == {str(n) for n in range(1,9)}
    rows = []
    identities = None
    for index in range(1,9):
        block = series[str(index)]
        row = {"block":index, "order":[v for v in block["order"] if v.startswith("lab-0_")]}
        assert len(row["order"]) == 2
        for cc in ["reno","cubic"]:
            a = block["engines"]["lab-0_"+cc]
            c = a["client"]
            assert (c["arrivals"], c["streams"], c["period_us"]) == (240,32,25000)
            assert clean_client(c) == a["valid"]
            stream_rates(c, c["window_s"], c["mib_s"])
            rates = sorted(b / MIB / c["window_s"] for b in c["per_stream_bytes"])
            before, after = a["before"], a["after"]
            tasks = [(x["pid"],x["birth_ticks"]) for x in before["tasks"]]
            assert len(tasks)==2 and (identities is None or tasks==identities)
            identities=tasks
            unit = {"raw_client":c, "clean": a["valid"], "mib_s": c["mib_s"],
                    "slowest_eight_mean_mib_s": sum(rates[:8])/8,
                    "slowest_eight_share_percent": 100*sum(sorted(c["per_stream_bytes"])[:8])/c["bytes"],
                    "p95_ms":c["fresh_p95_us"]/1000, "p99_ms":c["fresh_p99_us"]/1000,
                    "passes_75_ms": a["valid"] and c["fresh_p95_us"] <= 75000}
            for (pid,_),role in zip(tasks,["vmm","relay"]):
                delta=process_delta(before,after,pid)
                unit[role+"_cpu_s_per_gib"]=delta["cpu_s"]/(c["bytes"]/GIB)
                unit[role+"_runnable_s_per_s"]=delta["runnable_s"]/delta["sample_seconds"]
            row[cc]=unit
        rows.append(row)
    clean = [r for r in rows if r["reno"]["clean"] and r["cubic"]["clean"]]
    assert len(clean)==8
    metrics = ["mib_s","slowest_eight_mean_mib_s","slowest_eight_share_percent","p95_ms","p99_ms",
               "vmm_cpu_s_per_gib","relay_cpu_s_per_gib","vmm_runnable_s_per_s","relay_runnable_s_per_s"]
    result={"date":"2026-11-24","tier":"archived VM","stable_id":"231.07","analysis_revision":REV,
            "archive":ARCH,"archive_sha256":SHA,"recording_revision":recording,
            "kernel_sha256":source["sha256"]["cubic_kernel"],"image":scope["image"],
            "driver_and_client":{k:digest(source["files"][k].encode()) for k in ["guest-init.sh","fixed.go"]},
            "fixed_client_binary": source["sha256"]["fixed_go_client"],"polling":scope["boot-policy"].splitlines()[:2],
            "vm":scope["vm"],"controller_proofs":proofs,"host_process_identity_pid_and_birth":identities,
            "primary_metric":"Mean delivered rate of the eight lowest-byte streams within an arm and block, MiB/s per stream. Ranks may identify different sockets in the two services.",
            "attempted_pairs":len(rows),"complete_pairs":len(clean),"fresh_offers_per_arm":sum(r["reno"]["raw_client"]["arrivals"] for r in rows),
            "delivery_guardrail_passes":{cc:sum(r[cc]["passes_75_ms"] for r in rows) for cc in ["reno","cubic"]},
            "fresh_errors":{cc:sum(len(r[cc]["raw_client"]["errors"] or []) for r in rows) for cc in ["reno","cubic"]},
            "stream_reopens":{cc:sum(r[cc]["raw_client"]["reopened"] for r in rows) for cc in ["reno","cubic"]},
            "per_metric_paired_summary":{k:paired(clean,k) for k in metrics},"all_attempts":rows}
    with target.open("x") as f:
        json.dump(result,f,indent=2)
        f.write("\n")


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output",type=Path)
    replay(parser.parse_args().output)
