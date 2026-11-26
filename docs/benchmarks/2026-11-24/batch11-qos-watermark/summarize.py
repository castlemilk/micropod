"""Summarize all first attempts, keeping both process CPU and receiver delivery denominators."""
import argparse
import hashlib
import json
import math
import random
from pathlib import Path
from statistics import median

def pct(values, frac):
    return sorted(values)[math.ceil(frac*len(values))-1]

def equal_rate_interval(changes):
    r=random.Random(23006)
    m=sorted(median(r.choices(changes,k=len(changes))) for i in range(20000))
    return [pct(m,.025),pct(m,.975)]

def summarize(path):
    v=json.loads(path.read_bytes())
    rows=v["rows"]
    expected=[(n+1,letter) for n,arm in enumerate(v["order"]) for letter in arm]
    assert len(expected)==16 and v["order"].count("AB")==4 and v["order"].count("BA")==4
    assert [(r["block"],r["arm"]) for r in rows]==expected[:len(rows)]
    out=dict(first_attempts=len(rows),planned=16,raw_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),arms={})
    clean={}
    for arm in "AB":
        tries=[r for r in rows if r["arm"]==arm]
        valid=[r for r in tries if r.get("summary",{}).get("effective_qos_matches") and r["summary"]["all_markers_inside_window"] and r["exit_code"]==0]
        for r in valid: clean[(r["block"],arm)]=r
        d=dict(attempted=len(tries),eligible=len(valid),failed_exit=[r["exit_code"] for r in tries if r["exit_code"]!=0])
        if valid:
            ss=[r["summary"] for r in valid]; raw=[r["raw"] for r in valid]
            mark=[(x["received_ns"]-x["sent_ns"])/1e6 for r in raw for x in r["tails"]]
            timer=[ms for s in ss for ms in s["timers_ms"]]
            d.update({k:median(s[k] for s in ss) for k in ("MiB_s","cpu_s_GiB","runnable_s_s")})
            d.update(marked_replies=len(mark),sample_pooled_median_open_tail_ms=median(mark),
                     sample_pooled_p95_open_tail_ms=pct(mark,.95),sample_pooled_p99_open_tail_ms=pct(mark,.99),
                     total_bulk_sent=sum(r["bulk_sent"] for r in raw),total_bulk_received=sum(r["bulk_received"] for r in raw),
                     max_cpu_counter_offset_ms=max(max(abs(r["counter_open_ns"]-r["score_start_ns"]),abs(r["score_end_ns"]-r["counter_close_ns"]))/1e6 for r in raw))
            if timer:
                d.update(timer_service_median_ms=median(timer),timer_service_p95_ms=pct(timer,.95),timer_service_max_ms=max(timer),
                         markers_sent_while_timer_pending=sum(x["timer_armed_ns"]<=x["sent_ns"]<=x["timer_serviced_ns"] for r in raw for x in r["tails"]))
        out["arms"][arm]=d
    rc=[clean[(n,"B")]["summary"]["MiB_s"]/clean[(n,"A")]["summary"]["MiB_s"]-1 for n in range(1,9) if (n,"A") in clean and (n,"B") in clean]
    out.update(common_clean=len(rc))
    if rc:
        out.update(median_paired_delta_pct=100*median(rc),paired_bootstrap_95_pct=[100*x for x in equal_rate_interval(rc)],candidate_wins=sum(x>0 for x in rc))
    return out

if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("receipt",type=Path);args=p.parse_args();print(json.dumps(summarize(args.receipt),indent=2))
