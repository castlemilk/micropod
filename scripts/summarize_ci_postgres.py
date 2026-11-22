#!/usr/bin/env python3
"""Recompute queue-free PostgreSQL and cache baselines from immutable Gamma receipts."""
import argparse
from collections import Counter
from datetime import datetime
import gzip
import hashlib
import json
from pathlib import Path

from bench_postgres_fixture import distribution, require, verify_shutdown
from ci_benchmark_store import store

ROOT = Path(__file__).resolve().parents[1]


def baseline(directory, trace_events=None):
    sources = {}

    def read(name):
        data = (directory / name).read_bytes()
        sources[name] = hashlib.sha256(data).hexdigest()
        return json.loads(gzip.decompress(data) if name.endswith(".gz") else data)

    original = read("gamma-worker-pipelines.json")
    suite = read("full-ci/pipelines.json.gz")
    rig = read("full-ci/rig.json")
    pair = read("gamma-worker-orbstack-ubuntu.json")
    prepare = read("full-ci/prepare.json")
    controls = read("full-ci/cache-controls.json")
    go = read("full-ci/go-jobs.json.gz")
    publication = read("go-suite-layers.json.gz")
    layers = read("worker-profile/adaptive-buildkit.json.gz")
    require(all(d["passed"] for d in (original, suite, pair, controls, go, publication)), "An input series did not qualify")
    resources = pair["engine_resources"]
    require(original["worker"]["cpus"] == original["peer"]["NCPU"] == rig["worker_before"]["cpus"] == 4
            and all(v["NCPU"] == 4 for v in resources.values()), "Different CPU budgets")
    memories = [original["worker"]["memoryBytes"], original["peer"]["MemTotal"], rig["worker_before"]["memoryBytes"],
                *(v["MemTotal"] for v in resources.values())]
    require(max(memories)/min(memories) < 1.05, "RAM differs by more than 5%")

    summary = {"schema": 1, "percentiles": "median and nearest-rank p95; success samples only",
               "ci_queue_s": None, "queue_source": "direct local submissions; no scheduler timestamps",
               "engine_resources": resources, "sources_sha256": sources, "original_warm": {},
               "matched_pipeline": [], "caches": {}, "preliminary_failure": rig["earlier_incomplete_series"]}
    for engine, key in (("micropod","worker"),("orbstack","orbstack")):
        durations = original["pipeline_seconds"][key]
        warm = [k for k in durations if k.startswith("warm_")]
        summary["original_warm"][engine] = {
            "pipeline_s": distribution([durations[k] for k in warm]),
            "postgres_s": distribution([original["pipeline_stages_seconds"][key][k]["postgres"] for k in warm]),
            "readiness_s": None, "fixture_restore_s": None, "sql_s": None, "teardown_s": None}
    for engine in ("micropod","orbstack"):
        for rev in ("baseline","candidate"):
            rows = [r for r in suite["batches"] if r["engine"] == engine and r["revision"] == rev and r["round"] > 0]
            require(len(rows) == 6, "Incomplete steady-state series")
            lifetimes, stopping, prestop, codes = [], [], [], Counter()
            for row in rows:
                require(len(row["postgres"]) == 1, "Expected exactly one database lifecycle")
                events, = row["postgres"].values()
                start, = [e["ns"] for e in events if e["action"] == "start"]
                stop = min(e["ns"] for e in events if e["action"] == "kill")
                die, = [e for e in events if e["action"] == "die"]
                end, = [e["ns"] for e in events if e["action"] == "destroy"]
                require(start <= stop <= die["ns"] <= end, "Invalid Docker event order")
                if rev == "candidate":
                    verify_shutdown(events)
                    require(row["sql"] and row["live_node_tests"] and row["unit_tests"] and die["exit"] == "0",
                            "Candidate application or clean shutdown assertion failed")
                else:
                    require(any(e["signal"] == "9" for e in events) and die["exit"] == "137", "Expected forced stop in the baseline")
                lifetimes.append((end-start)/1e9)
                stopping.append((end-stop)/1e9)
                prestop.append((stop-start)/1e9)
                codes[die["exit"]] += 1
                if trace_events is not None:
                    pid = 1 + ("micropod", "orbstack").index(engine)
                    tid = row["round"] * 4 + (2 if rev == "candidate" else 0) + (1 if row["mode"] == "repeat" else 0)
                    lane = dict(pid=pid, tid=tid)
                    name = f"{engine} {rev} {row['mode']} {row['round']}"
                    trace_events.append(dict(**lane, ph="M", name="thread_name", args={"name": name}))
                    for title, a, b in (("start to stop request", start, stop), ("stop request to destroy", stop, end)):
                        trace_events.append(dict(**lane, ph="X", cat="docker", name=title, ts=(a-start)/1000,
                                                 dur=(b-a)/1000, args={"exit": die["exit"]}))
                    for event in events:
                        trace_events.append(dict(**lane, ph="i", s="t", cat="docker", ts=(event["ns"]-start)/1000,
                                                 name=event["action"], args={"signal": event["signal"], "exit": event["exit"]}))
            summary["matched_pipeline"].append(dict(engine=engine, revision=rev,
                repeat_s=distribution([r["seconds"] for r in rows if r["mode"]=="repeat"]),
                edit_s=distribution([r["seconds"] for r in rows if r["mode"]=="edit"]),
                postgres_s=distribution([r["stages"]["postgres"] for r in rows]),
                db_start_to_stop_request_s=distribution(prestop), db_stop_request_to_destroy_s=distribution(stopping),
                db_start_to_destroy_s=distribution(lifetimes), exit_codes=codes,
                first_attempt_failures=sum(bool(r["previous_attempts"]) for r in rows),
                readiness_s=None, fixture_restore_s=None, sql_s=None))
        key = "micropod-worker" if engine == "micropod" else engine
        blocks = [b["package_caches"]["blocks"][0] for b in pair["blocks"] if b["engine"]==key]
        require(len(blocks)==5 and all(b["same_payload_inodes"] and b["empty_offline_controls"]
                and b["before"]==b["after"] for b in blocks), "Package-cache controls failed")
        sizes = blocks[0]["after"]
        require(all(b["after"]==sizes for b in blocks), "Package footprint varied across blocks")
        cold = {k: distribution([b["cold"][k] for b in blocks]) for k in blocks[0]["cold"]}
        jobs = [j for b in blocks for j in b["batches"]]
        measured = {tool: {} for tool in ("npm","go")}
        for tool, groups in measured.items():
            for n in (1,4,8,16):
                group = [j for j in jobs if j["tool"]==tool and j["clients"]==n]
                require(len(group)==5, "Missing package samples")
                groups[n] = dict(seconds=distribution([j["seconds"] for j in group if not j["errors"]]),
                                 verified_payload_reuses=sum(j["passed"] for j in group),
                                 first_attempt_failures=sum(len(j["errors"]) for j in group))
        image = layers[engine]
        imagegroups = {}
        for category in sorted({b["context"] for b in image}):
            group = [b for b in image if b["context"]==category]
            counts = Counter()
            for b in group: counts.update(b["outcomes"])
            imagegroups[category] = dict(steps=counts,
                solve_s=distribution([(datetime.fromisoformat(b["completed"].replace("Z","+00:00"))
                                     -datetime.fromisoformat(b["started"].replace("Z","+00:00"))).total_seconds() for b in group]))
        summary["caches"][engine] = dict(cold_seed=cold, warm_fresh_containers=measured, logical_bytes=sizes,
                                         buildkit_image_steps=imagegroups)
    summary["prepared_go_image"] = dict(cold_publish_s=prepare["wall_s"], warm_lookup_s=controls["original"]["seconds"],
        concurrent=Counter(x["event"]["cache"] for x in controls["concurrent_changed_prepares"]),
        buildkit_inventory_before=rig["cache_before"]["buildCache"], buildkit_inventory_after=rig["cache_after"]["buildCache"])
    native = [p for p in publication["preparations"] if p["mode"] == "native"]
    misses = sorted((p for p in native if p["cache"] == "miss"), key=lambda p: p["trial"])
    hits = sorted((p for p in native if p["cache"] == "hit"), key=lambda p: p["trial"])
    require(len(misses) == len(hits) == 6 and all(
        (a["source"], a["key"], a["image"]) == (b["source"], b["key"], b["image"]) for a, b in zip(misses, hits)),
        "Prepared image hits do not match their cold keys")
    summary["matched_go_image_cache"] = dict(miss_s=distribution([p["wall_s"] for p in misses]),
        hit_s=distribution([p["wall_s"] for p in hits]), publications=[{
            k: p["publication"][k] for k in ("layer", "layer_bytes", "blob_bytes_sent", "import_bytes", "layer_reused")} for p in misses],
        concurrent=Counter(p["cache"] for p in publication["concurrent_prepare"]["rows"]),
        concurrent_batch_s=publication["concurrent_prepare"]["seconds"])
    hardware = go["rig"]
    ubuntu = hardware["ubuntu"]
    require(hardware["micropod"]["cpus"] == hardware["orbstack"]["NCPU"] == int(ubuntu[1]) == 4
            and hardware["micropod_tools"][:2] == hardware["orbstack_tools"][:2] == ubuntu[3:5],
            "Go comparison differs in CPU budget or toolchain")
    budgets = [hardware["micropod"]["memoryBytes"], hardware["orbstack"]["MemTotal"], int(ubuntu[2].split()[1])*1024]
    require(max(budgets)/min(budgets) < 1.05, "Go comparison differs in memory budget")
    summary["matched_go_batches"] = [dict(engine=engine, mode=mode, clients=n,
        seconds=distribution([b["seconds"] for b in go["batches"] if b["round"] > 0 and
                              (b["engine"], b["mode"], b["clients"]) == (engine, mode, n)]))
        for engine in ("micropod", "orbstack", "ubuntu") for mode in ("source","suite") for n in (1,16,32)]
    require(all(b["seconds"]["n"] == 3 for b in summary["matched_go_batches"]), "Incomplete raw Ubuntu comparison")
    summary["run"] = hashlib.sha256(json.dumps(sources,sort_keys=True).encode()).hexdigest()
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT/"docs/benchmarks/2026-11-20")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--trace", type=Path, help="Docker event lanes aligned to each database start")
    args = parser.parse_args()
    events = []
    data = baseline(args.source, events)
    if args.trace:
        args.trace.parent.mkdir(parents=True, exist_ok=True)
        args.trace.write_text(json.dumps({"traceEvents": events, "displayTimeUnit":"ms"}, separators=(",",":"))+"\n")
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(data,indent=2)+"\n")
    store(args.database, data["run"], "postgres-saved-baselines", data)
