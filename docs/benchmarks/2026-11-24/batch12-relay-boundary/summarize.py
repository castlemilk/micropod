"""Independently verify all first attempts, raw service identity, rates, costs and guardrails."""
import hashlib
import json
import math
from pathlib import Path
from statistics import median
import sys

from run import check_build, SEAL, REV, sha


def main(out):
    _,mixed = check_build()
    receipt = out / "receipt.json"
    r = json.loads(receipt.read_text())
    assert r["revision"] == REV and r["build_receipt_sha256"] == sha(SEAL)
    raw = r["raw"]
    planned = [(i,arm) for i,b in enumerate(r["order"],1) for arm in b]
    assert sorted(map(tuple,r["order"])) == [(0,1)]*3+[(1,0)]*3
    assert [(a["block"],a["arm"]) for a in raw] == planned[:len(raw)]
    if r["status"] == "complete":
        assert len(raw) == 12
        for key in ("initial_route_proofs","final_route_proofs"):
            for arm,proof in enumerate(r[key]):
                assert proof["marker"] == r["marker"] and proof["data_sha256"] == mixed.PAYLOAD and proof["data_bytes"] == 8<<20
                base = r["initial_route_proofs"][arm]
                for k in ("endpoint","listener"):
                    assert proof[k] == base[k]
                assert proof["process"]["birth"] == base["process"]["birth"]
    for a in raw:
        if "client" not in a: continue
        c = a["client"]
        d = out / f'block-{a["block"]}-{a["arm"]}'
        assert json.loads((d/"client.out").read_bytes()) == c
        assert a["selected_endpoint"] == r["initial_route_proofs"][a["arm"]]["endpoint"]
        for i,k in enumerate(("relay","server")):
            proof = a["route_proofs"][i]
            assert proof["marker"] == r["marker"] and proof["listener"] == r["initial_route_proofs"][i]["listener"]
            assert a["raw_initial"][k]["birth"] == a["raw_final"][k]["birth"] == proof["process"]["birth"]
        for k in ("relay","server","client"):
            cost = mixed.cost(a["raw_initial"][k],a["raw_final"][k],c["bytes"],a["period_s"])
            assert cost and cost == a["cost_per_role"][k]
        lo = a["loopback_host_shared_raw"]
        assert [v for v in a["loopback_host_shared_delta"].values()] == [(y-x)%2**32 for x,y in zip(*lo)]
        if a["delivery_clean"]:
            assert c["arrivals"] == 240 and c["streams"] == 32 and c["period_us"] == 25000
            assert len(c["per_stream_bytes"]) == 32 and min(c["per_stream_bytes"])>0
            assert sum(c["per_stream_bytes"]) == c["bytes"]
            assert math.isclose(c["bytes"]/1048576/c["window_s"],c["mib_s"])
            assert not c["errors"] and not c["reopened"] and a["exit"] == 0
    clean = [a for a in raw if a.get("delivery_clean")]
    pairs = []
    for i in range(1,7):
        two = {a["arm"]:a for a in clean if a["block"]==i}
        if len(two) == 2: pairs.append([two[k]["client"] for k in (0,1)])
    result = {"raw_sha256":sha(receipt),"status":r["status"],"planned_pairs":6,"clean_pairs":len(pairs),"arms":{},
              "paired":{k:mixed.paired_stats(pairs,k) for k in ("mib_s","fresh_p95_us","fresh_p99_us")}}
    for arm,name in enumerate(("relay","direct")):
        allrows = [a for a in raw if a["arm"] == arm]
        rows = [a for a in allrows if a.get("client")]
        good = [a for a in rows if a["delivery_clean"]]
        summary = {"attempted":sum(a["client_attempted"] for a in allrows),"clean":len(good),
                   "fresh_scheduled":sum(a["client"]["arrivals"] for a in rows),
                   "streams_reopened":sum(a["client"]["reopened"] for a in rows),
                   "client_errors":sum(len(a["client"]["errors"] or []) for a in rows),
                   "p95_le_75_ms":sum(a["latency_p95_at_most_75_ms"] for a in rows)}
        if good:
            summary["medians"] = {k:median(a["client"][k] for a in good) for k in ("mib_s","fresh_p95_us","fresh_p99_us","dispatch_p95_us")}
            summary["per_process"]={proc:{k:median(a["cost_per_role"][proc][k] for a in good)
                                     for k in ("cpu_s_per_scored_GiB","runnable_s","runnable_thread_s_per_wall_s",
                                               "runnable_minus_cpu_s")} for proc in ("client","relay","server")}
        if rows:
            summary["shared_lo0_errors_drops"] = {k:sum(a["loopback_host_shared_delta"][k] for a in rows)
                                                   for k in ("in_errors","out_errors","in_queue_drops")}
        result["arms"][name] = summary
    q=[a["admission"].get("idle_fraction") for a in raw if "admission" in a]
    idles=[i*100 for i in q if i is not None]
    result["observed_host_idle_pct_range"]=[min(idles),max(idles)] if idles else None
    result["idle_unavailable"]=sum(i is None for i in q)
    result["min_free_gib"]=min((a["minimum_observed_free_GiB"] for a in raw if "minimum_observed_free_GiB" in a),default=None)
    print(json.dumps(result,indent=2))


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
