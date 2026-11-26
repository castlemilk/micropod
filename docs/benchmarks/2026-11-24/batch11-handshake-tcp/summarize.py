"""Summarize every first attempt across the restart and the post-restart host diagnostic."""
import hashlib
import json
from pathlib import Path
from statistics import median

here = Path(__file__).resolve().parent
path = here / "post-restart-first/receipt.json"
post = json.loads(path.read_text())
old = json.loads((here / "first/receipt.json").read_text())
assert post["status"] == "complete" and len(post["raw"]) == 12
assert len(old["raw"]) == 1 and not (here / "first/block-1-1/client.out").read_bytes()
for x in post["raw"]:
    raw = json.loads((path.parent / f"block-{x['block']}-{x['arm']}/client.out").read_text())
    assert raw == x["client"]
    assert sum(raw["per_stream_bytes"]) == raw["bytes"]
summary = {}
for arm in (0, 1):
    rows = [x for x in post["raw"] if x["arm"] == arm]
    summary[arm] = dict(completed=len(rows), clean=sum(x["delivery_clean"] for x in rows),
                        started_including_interruptions=len(rows) + sum(x['arm']==arm for x in old['raw']),
                        fresh_scheduled=sum(x["client"]["arrivals"] for x in rows),
                        p95_at_most_75ms=sum(x['latency_p95_at_most_75_ms'] for x in rows),
                        errors=sum(len(x["client"]["errors"] or []) for x in rows),
                        reopens=sum(x["client"]["reopened"] for x in rows),
                        loopback_host_wide_input_queue_drops=sum(x["loopback_host_shared_delta"]["in_queue_drops"] for x in rows),
                        process_cost={role:{k:median(x["cost_per_role"][role][k] for x in rows)
                                            for k in ("cpu_s_per_scored_GiB","runnable_thread_s_per_wall_s")}
                                      for role in ("client","relay","server")})
print(json.dumps(dict(post_restart_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                      pre_restart_sha256=hashlib.sha256((here/"first/receipt.json").read_bytes()).hexdigest(),
                      arms=summary,paired=post["clean_summary"],
                      idle_pct_range=[func(100*x["admission"]["idle_fraction"] for x in post["raw"]) for func in (min,max)],
                      minimum_disk_GiB=min(x["minimum_observed_free_GiB"] for x in post["raw"])),indent=2))
