"""Compare same-endpoint connection tracking in the archived Gamma routed-path screen."""
import gzip
import hashlib
import itertools
import json
import math
from pathlib import Path
from statistics import median

ROOT = Path(__file__).resolve().parents[4]
ARCHIVE = ROOT / "docs/benchmarks/2026-11-21/gamma-mixed-path.json.gz"
DIGEST = "09ebe5510401244cd6d299c1d0cf6dd8f88b256bf14b8c2c14f6db3eff61b74a"
ARMS = ("routed", "untracked")


def counters(observation):
    return {line.split()[5]: int(line.split()[0]) for line in observation.splitlines() if "CT notrack" in line}


def main():
    raw = ARCHIVE.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == DIGEST
    study = json.loads(gzip.decompress(raw))
    records = study["records"]
    trial = records["trial.boot"]
    limits = records["forwarding/limits"]
    driver = records["fixtures/route-screen.sh"]
    assert trial["worker"] in driver and trial["cpus"] == 4
    assert limits["cpu.max"] == "400000 100000" and limits["cpuset.cpus.effective"] == "0-3"
    assert "routed|untracked)a=$(cat \"$d/routed.addr\")" in driver
    assert "const int n=2;" in records["fixtures/owner-placement.c"]
    assert study["baseline_commit"] == "4f887ba5"
    paths = records["forwarding/paths"].splitlines()
    assert paths == ["stock", "dnat", *ARMS, "orb"]
    assert records["forwarding/closed"].strip() == "closed"
    rows = []
    for block in range(6):
        order = [paths[(j+block)%len(paths) if block%2 == 0 else -1-(j+block)%len(paths)] for j in range(len(paths))]
        samples = {}
        for arm in ARMS:
            stem = f"forwarding/{block}-{arm}"
            policy = records[stem+".policy"]
            assert "cache rto_min lock 20ms congctl reno" in policy
            assert "192.168.128.241 via 10.88.0.40 dev mpci0" in policy
            assert policy.endswith("configured\n") and records[stem+".err"] == ""
            assert len(counters(policy)) == (2 if arm == "untracked" else 0)
            s = records[stem+".json"]
            assert s["streams"] == 32 and s["period_us"] == 25000 and s["arrivals"] == 240
            assert len(s["per_stream_bytes"]) == 32 and sum(s["per_stream_bytes"]) == s["bytes"]
            rate = s["bytes"]/s["window_s"]/2**20
            assert math.isclose(rate,s["mib_s"],rel_tol=1e-10)
            samples[arm] = dict(delivered_bytes=s["bytes"], window_s=s["window_s"], MiB_s=rate,
                                fresh_p95_ms=s["fresh_p95_us"]/1000, fresh_p99_ms=s["fresh_p99_us"]/1000,
                                arrivals=s["arrivals"], errors=s["errors"], reopened=s["reopened"],
                                positive_streams=sum(x>0 for x in s["per_stream_bytes"]))
        rows.append(dict(block=block, order=order, arms=samples))
    assert {f"forwarding/{i}-{arm}.json" for i in range(6) for arm in ARMS} == {
        k for k in records if k.startswith("forwarding/") and k.endswith(("-routed.json","-untracked.json"))}
    effects = [100*(r["arms"]["untracked"]["MiB_s"]/r["arms"]["routed"]["MiB_s"]-1) for r in rows]
    # Enumerate every six-block percentile bootstrap resample; exploratory with six blocks.
    draws = sorted(median(s) for s in itertools.product(effects, repeat=len(rows)))
    summary = {}
    for arm in ARMS:
        s = [r["arms"][arm] for r in rows]
        summary[arm] = {k:median(x[k] for x in s) for k in ("MiB_s","fresh_p95_ms","fresh_p99_ms")}
        summary[arm].update(first_attempts=len(s), clean=sum(not x["errors"] and x["reopened"]==0 and x["positive_streams"]==32 for x in s),
                            fresh_arrivals=sum(x["arrivals"] for x in s), p95_pass=sum(x["fresh_p95_ms"]<=75 for x in s))
    before = counters(records["forwarding-verify/untracked.before"])
    after = counters(records["forwarding-verify/untracked.after"])
    verify_delta = {dev:after[dev]-before[dev] for dev in before}
    assert verify_delta == {"mpci0":32,"eth1":48}
    assert not counters(records["forwarding-verify/routed.after"])
    result = dict(raw_sha256=DIGEST, archive_commit="692ace081c989f80fb2bce27a5a13af13098b77c",
                  recorded_parent="4f887ba5d28f47fa37d4bd0a2d89cd0914d74754", image=study["platform"]["image_sha256"],
                  fixed_client=study["binaries"]["fixed-client"], policy_fixture_sha256=hashlib.sha256(records["fixtures/route-path-action"].encode()).hexdigest(),
                  relay_fixture_sha256=hashlib.sha256(records["fixtures/owner-placement.c"].encode()).hexdigest(),
                  worker=trial["worker"], boot=trial["boot"], control="routed", candidate="untracked",
                  separate_verification_packets=verify_delta, summary=summary, paired_pct=effects, median_paired_pct=median(effects),
                  interval_pct=[draws[math.ceil(p*len(draws))-1] for p in (.025,.975)], bootstrap_resamples=len(draws),
                  candidate_wins=sum(x>0 for x in effects), candidate_first=sum(r["order"].index("untracked")<r["order"].index("routed") for r in rows), rows=rows)
    print(json.dumps(result,indent=2,sort_keys=True))


if __name__ == "__main__":
    main()
