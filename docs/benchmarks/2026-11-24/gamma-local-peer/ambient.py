"""Descriptive peer comparison with one pre-client observation at natural host load."""

import json
import sys
from pathlib import Path
from statistics import median

from score import CANDIDATE, CLIENT, SELECTION, load, peer_verdict, relay, require

SEED = 34205


def schedule():
    orders = relay.plan(SEED, 4)
    return {"warmup": orders["warmup"][:1], "scored": orders["scored"]}


def summarize(folder):
    from score import checked_environment, first_attempt

    orders = schedule()
    plan = load(folder / "plan.json")
    require(
        plan["order"] == orders
        and plan["seed"] == SEED
        and plan["candidate"] == CANDIDATE
        and plan["tools"] == dict(relay.HASHES, fixed=CLIENT)
        and plan["selected_from_sha256"] == relay.digest(SELECTION)
        and plan["load_policy"] == "ambient"
        and plan["idle_wait_seconds"] == 0
        and plan["idle_floor_pct"] is None,
        "unexpected ambient plan",
    )
    arms = checked_environment(folder, "ambient")
    pairs = []
    births = {}
    previous_end = 0
    for phase, sequence in orders.items():
        for number, order in enumerate(sequence, 1):
            pair = {"number": number, "order": order}
            for arm in order:
                r = first_attempt(folder, arms, phase, number, arm)
                idle = r["idle_observations"]
                require(
                    len(idle) == 1 and idle[0]["idle_pct"] == r["idle_pct"] and 0 <= r["idle_pct"] <= 100,
                    "ambient window requires one actual idle observation",
                )
                require(
                    previous_end <= r["before"]["epoch_ns"] < r["after"]["epoch_ns"],
                    "ambient client order changed",
                )
                previous_end = r["after"]["epoch_ns"]
                identity = relay.identities(r["before"])
                require(
                    identity == births.setdefault(arm, identity) == relay.identities(r["after"]),
                    "observed host process changed",
                )
                metrics = peer_verdict.observation(r, arms[arm]["pids"], full_body_counts=True)
                require(phase != "warmup" or metrics["clean"], "ambient warmup incomplete")
                pair[arm] = dict(metrics, idle_pct=r["idle_pct"])
            if phase == "scored":
                pairs.append(pair)
    ratios = [p["A"]["mib_s"] / p["B"]["mib_s"] for p in pairs if p["A"]["clean"] and p["B"]["clean"]]
    summaries = {}
    for arm, name in peer_verdict.PRODUCT.items():
        rows = [p[arm] for p in pairs]
        clean = [r for r in rows if r["clean"]]
        summary = {
            k: median(r[k] for r in clean) if clean else None
            for k in ("mib_s", "p50_ms", "p95_ms", "p99_ms", "cpu_s_per_gib")
        }
        idle = [r["idle_pct"] for r in rows]
        summaries[name] = dict(
            summary,
            clean=len(clean),
            offered=sum(r["offered"] for r in rows),
            known_fresh_failures=sum(r["fresh_failed"] or 0 for r in rows),
            unknown_fresh_failure_counts=sum(r["fresh_failed"] is None for r in rows),
            bulk_reopens=sum(r["bulk_reopens"] for r in rows),
            idle_pct_range=[min(idle), max(idle)],
        )
    return {
        "study": "ambient",
        "common_clean_pairs": len(ratios),
        "micropod_pair_wins": sum(r > 1 for r in ratios),
        "median_ratio": median(ratios) if ratios else None,
        "arms": summaries,
        "pairs": pairs,
    }


if __name__ == "__main__":
    print(json.dumps(summarize(Path(sys.argv[1]).resolve()), indent=2, allow_nan=False))
