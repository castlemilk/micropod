import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
from statistics import median
from run import validate

HERE=Path(__file__).resolve().parent

def summarize(root,build):
    reporting=json.loads((root/"receipt.json").read_text())
    assert reporting["action"]=="run"
    spec=importlib.util.spec_from_file_location("mixed",build/"suite.py")
    mixed=importlib.util.module_from_spec(spec);spec.loader.exec_module(mixed)
    raw=reporting["raw"]
    scheduled=[(b,arm) for b,order in enumerate(reporting["order"],1) for arm in order]
    assert [(r["block"],r["arm"]) for r in raw]==scheduled[:len(raw)]
    if reporting["status"]=="complete": assert len(raw)==12
    for r in raw:
        path=root/f'block-{r["block"]}-{r["arm"]}'
        if "client" not in r: continue
        assert r["client"]==json.loads((path/"client.out").read_text())
        assert r["lifecycle_and_qos"]==validate(path/"relay-events.jsonl",r["arm"])
        if r["delivery_clean"]: assert r["client"]["bytes"]==sum(r["client"]["per_stream_bytes"])
    summaries={}
    for arm in (0,1):
        observed=[r for r in raw if r["arm"]==arm]
        measured=[r for r in observed if r.get("client")]
        clean=[r for r in measured if r["delivery_clean"]]
        summary={"admissions":len(observed),"first_attempts":sum(r["client_attempted"] for r in observed),
                 "completed":len(measured),"clean":len(clean),"p95_le_75ms":sum(r["latency_p95_at_most_75_ms"] for r in measured),
                 "fresh_scheduled":sum(r["client"].get("arrivals",0) for r in measured),"stream_reopens":sum(r["client"].get("reopened",0) for r in measured),
                 "client_errors":sum(len(r["client"].get("errors") or []) for r in measured)}
        if measured:
            summary["shared_loopback_input_queue_drops"]=sum(r["loopback_host_shared_delta"]["in_queue_drops"] for r in measured)
            summary["shared_loopback_in_out_errors"]=sum(sum(r["loopback_host_shared_delta"][k] for k in ("in_errors","out_errors")) for r in measured)
        if clean:
            summary["clean_medians"]={k:median(r["client"][k] for r in clean) for k in ("mib_s","fresh_p95_us","fresh_p99_us")}
            summary["cost_by_process"]={proc:{k:median(r["cost_per_role"][proc][k] for r in clean)
                                       for k in ("cpu_s_per_scored_GiB","runnable_thread_s_per_wall_s")} for proc in ("client","relay","server")}
            energy=[r["energy_delta_nj"]["relay"]/(r["client"]["bytes"]/2**30)/1e9 for r in clean if r["energy_delta_nj"]["relay"] is not None]
            summary["relay_energy_J_per_scored_GiB"]=(median(energy) if len(energy)==len(clean) else None)
            owner=[e for r in clean for e in r["lifecycle_and_qos"] if e["event"]=="owner_sample"]
            summary["effective_owner_qos_classes"]=sorted({e["qos_class"] for e in owner})
            summary["owner_priority_ranges"]={k:[min(e[k] for e in owner),max(e[k] for e in owner)] for k in ("base_priority","current_priority")}
        summaries[arm]=summary
    pairs=[]
    for block in range(1,7):
        row={r["arm"]:r for r in raw if r["block"]==block and r.get("delivery_clean")}
        if len(row)==2: pairs.append([row[arm]["client"] for arm in [0,1]])
    seen=[r for r in raw if "admission" in r]
    scored=[r for r in raw if "minimum_observed_free_GiB" in r]
    ids=[r["admission"]["idle_fraction"]*100 for r in seen if r["admission"]["idle_fraction"] is not None]
    return {"source_receipt_sha256":hashlib.sha256((root/"receipt.json").read_bytes()).hexdigest(),
            "complete":reporting["status"]=="complete","arms":summaries,"paired_clean":len(pairs),
            "paired_stats":{k:mixed.paired_stats(pairs,k) for k in ("mib_s","fresh_p95_us","fresh_p99_us")},
            "measured_idle_pct_range":[min(ids),max(ids)] if ids else None,
            "idle_samples_observed":len(ids),"idle_samples_unavailable":len(seen)-len(ids),
            "min_free_GiB":min(r["minimum_observed_free_GiB"] for r in scored) if scored else None}

if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("root",type=Path);p.add_argument("build",type=Path)
    a=p.parse_args();print(json.dumps(summarize(a.root.resolve(),a.build.resolve()),indent=2))
