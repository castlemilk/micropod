"""Read preserved receiver and process records; calculate paired effects in full blocks."""
import hashlib
from itertools import product
import json
from pathlib import Path
from statistics import median, quantiles
import sys

def compare(values):
    control,candidate=map(list,zip(*values))
    percent=[100*(b/a-1) for a,b in values]
    draws=sorted(median(s) for s in product(percent,repeat=len(percent)))
    bounds=quantiles(draws,n=40,method="inclusive")
    return dict(control=median(control),candidate=median(candidate),paired_pct=median(percent),
                ci95_pct=[bounds[0],bounds[-1]],greater=sum(b>a for a,b in values))


def summarize(path):
    rec=json.loads(path.read_bytes())
    assert rec["status"]=="complete" and len(rec["attempts"])==12
    assert len({(r["block"],r["arm_ns"]) for r in rec["attempts"]})==12
    grouped={arm:sorted((r for r in rec["attempts"] if r["arm_ns"]==arm),key=lambda r:r["block"]) for arm in (0,50000)}
    paired=[(a,b) for a,b in zip(grouped[0],grouped[50000]) if a["delivery_clean"] and b["delivery_clean"]]
    summary={"receipt_sha256":hashlib.sha256(path.read_bytes()).hexdigest(),"scope":rec["comparison_status"],
             "attempts":len(rec["attempts"]),"joint_clean_pairs":len(paired),"arm":{},"effects":{}}
    for r in rec["attempts"]:
        p=path.parent/f"block-{r['block']}-{r['arm_ns']}"/"client.out"
        assert json.loads(p.read_bytes())==r["client"],p
    for arm,rows in grouped.items():
        def count(key):return sum(r[key] for r in rows)
        clients=[r["client"] for r in rows]
        drops=[r["loopback_host_shared_delta"] for r in rows]
        summary["arm"][str(arm)] = dict(delivery_clean=count("delivery_clean"),
              latency_guard_count=count("latency_p95_at_most_75_ms"),
              fresh_arrivals=sum(c["arrivals"] for c in clients),client_errors=sum(len(c["errors"] or []) for c in clients),
              reopens=sum(c["reopened"] for c in clients),body_bytes=sum(c["bytes"] for c in clients),
              lo0_delta={k:sum(d[k] for d in drops) for k in ("in_errors","out_errors","in_queue_drops")},
              idle_fraction=[r["admission"]["idle_fraction"] for r in rows],
              min_free_GiB=min(r["minimum_observed_free_GiB"] for r in rows),
              greater_eq_90pct_idle=sum(r["admission"]["meets_stock_idle"] for r in rows))
    for key in ("mib_s","fresh_p95_us","fresh_p99_us","dispatch_p95_us"):
        summary["effects"][key]=compare([(a["client"][key],b["client"][key]) for a,b in paired])
    for role in ("relay","server","client"):
        for key in ("cpu_s_per_scored_GiB","runnable_thread_s_per_wall_s","runnable_s","runnable_minus_cpu_s"):
            summary["effects"][role+"_"+key]=compare([(a["cost_per_role"][role][key],b["cost_per_role"][role][key]) for a,b in paired])
    return summary

if __name__=="__main__":
    print(json.dumps(summarize(Path(sys.argv[1])),indent=2))
