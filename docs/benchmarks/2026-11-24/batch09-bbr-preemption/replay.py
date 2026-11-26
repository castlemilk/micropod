"""Score the full/lazy kernel pair at fixed configured BBR in the archived tuning series."""
import hashlib
import json
import random
import sys
from pathlib import Path
from statistics import median

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "scripts/relaybench"))
from gamma_contrasts import clean_client, host_units, process_delta, read_receipt
from kernel_candidate import config_options

ARCHIVE = ROOT / "docs/benchmarks/2026-11-21/gamma-direct-macvlan.json.gz"
DIGEST = "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976"
ARMS = ("full-bbr", "lazy-bbr")


def replay():
    source = read_receipt(ARCHIVE, DIGEST)
    blocks = source["records"]["tuning"]
    workers = source["records"]["workers"]
    assert set(blocks) == {str(i) for i in range(1, 11)}
    configs = []
    for arm in ARMS:
        worker = workers[arm]
        kernel = source["kernels"][arm.split("-")[0]]
        config = kernel["config"].encode()
        assert hashlib.sha256(config).hexdigest() == kernel["config_sha256"]
        configs.append(config_options(config))
        assert worker["controller"] == "bbr"
        assert worker["image"] == "sha256:" + source["image_config_sha256"]
        assert worker["boot.json"]["cpus"] == 4
        for phase in ("state", "tuning-end"):
            state = worker[phase]
            assert state["release"] == kernel["release"].strip()
            assert state["cpu.max"] == "400000 100000" and state["cpuset.cpus.effective"] == "0-3"
            assert int(state["memory.max"]) == 2**30
    changes = {k: [a.get(k) for a in configs] for k in sorted(set.union(*(set(a) for a in configs)))
               if configs[0].get(k) != configs[1].get(k)}
    rows = []
    for index in range(1, 11):
        block = blocks[str(index)]
        row = {"round": index, "order": block["order"]}
        for arm in ARMS:
            sample = block["engines"][arm]
            client = sample["client"]
            assert sample["valid"] and clean_client(client)
            row[arm] = {k: client[k] for k in ("bytes", "mib_s", "fresh_p95_us", "fresh_p99_us",
                                                 "window_s", "arrivals", "errors", "reopened")}
            for role in ("relay", "vmm"):
                pid = int(workers[arm][role])
                delta = process_delta(sample["before"], sample["after"], pid)
                row[arm][role] = dict(**delta, **host_units(delta, client["bytes"]))
        rows.append(row)
    ratios = [r[ARMS[1]]["mib_s"] / r[ARMS[0]]["mib_s"] for r in rows]
    rng = random.Random(23510)
    boot = sorted(median(rng.choices(ratios, k=len(rows))) for _ in range(20000))
    summary = {}
    for arm in ARMS:
        hits = [r[arm] for r in rows]
        out = {k: median(h[k] for h in hits) for k in ("mib_s", "fresh_p95_us", "fresh_p99_us")}
        out["p95_within_75_ms"] = sum(h["fresh_p95_us"] <= 75000 for h in hits)
        for role in ("relay", "vmm"):
            out[role] = {k: median(h[role][k] for h in hits)
                         for k in ("cpu_s_per_gib", "runnable_s_per_s", "wait_s_per_s")}
        summary[arm] = out
    return dict(archive_sha256=DIGEST, archive_commit="7a4eb51a04b51f6332ed49561b3dd0bb42ffacd9",
                recording_base=source["baseline_commit"], service_sha256=source["service_sha256"],
                image=source["image_config_sha256"], kernel_changes=changes, arms=summary,
                median_ratio=median(ratios), interval=[boot[499], boot[19499]],
                candidate_wins=sum(r > 1 for r in ratios), rows=rows)


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2, sort_keys=True))
