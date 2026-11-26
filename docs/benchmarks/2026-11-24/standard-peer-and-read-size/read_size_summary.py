"""Replay the two native relay read caps from first-attempt sample and progress files."""
import json
import math
from pathlib import Path
from statistics import median
import struct
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[3] / "scripts/relaybench"))
from gamma_contrasts import paired_median_interval, percentile
from gamma_pilot import plan, require
from gamma_relay_pilot import verify_worker_controls


def summarize(folder):
    def load(name):
        return json.loads((folder / name).read_bytes())

    protocol, controls = load("plan.json"), load("worker-controls.json")
    orders, caps = plan(241126, 8), {"A": 256, "B": 512}
    require(protocol["action"] == "run" and protocol["order"] == orders and protocol["relay_read_kib"] == caps
            and protocol["ports"] == 1 and protocol["seconds"] == 6
            and protocol["arm_binaries"]["A"] == protocol["arm_binaries"]["B"],
            "read-size schedule or build differs")
    rows = {}
    counts = dict.fromkeys(caps, 0)
    for phase, pairs in orders.items():
        for number, order in enumerate(pairs, 1):
            for arm in order:
                name = f"{phase}-{number}-{arm}"
                raw, row = load(name + ".stdout"), load(name + ".json")
                for observed in (controls[arm], raw):
                    verify_worker_controls(observed, 2, caps[arm])
                require((row["phase"], row["pair"], row["arm"]) == (phase, number, arm)
                        and row["clean"] is True and raw["profile"] == 0 and raw["client_buffer_kib"] == 512
                        and raw["ports"] == 1 and raw["bulk_flows_per_owner"] == [16, 16], "wrong sample identity")
                require(struct.unpack("=II", (folder / (name + ".progress")).read_bytes()) == (240, 240)
                        and (row["fresh_offered"], row["submitted"], row["completed"]) == (240, 240, 240)
                        and len(raw["fresh_ns"]) == len(raw["dispatch_ns"]) == 240
                        and len(raw["per_stream_bytes"]) == 32 and min(raw["per_stream_bytes"]) > 0
                        and sum(raw["per_stream_bytes"]) == raw["bytes"], "incomplete native delivery")
                tick = raw["tick_numer"] / raw["tick_denom"] / raw["elapsed_ns"]
                observed = dict(mib_s=raw["bytes"] * 1e9 / (2**20 * raw["elapsed_ns"]),
                                p95_ms=percentile(raw["fresh_ns"], .95) / 1e6,
                                p99_ms=percentile(raw["fresh_ns"], .99) / 1e6,
                                cpu_s_per_gib=raw["process_cpu_us"] / 1e6 / (raw["bytes"] / 2**30),
                                wait_s_per_s=(raw["runnable_ticks"] - raw["cpu_ticks"]) * tick,
                                runnable_s_per_s=raw["runnable_ticks"] * tick)
                require(all(math.isclose(v, row[k]) for k, v in observed.items()), "native rate or cost differs")
                if phase == "scored":
                    rows[number, arm] = observed
                    counts[arm] += row["completed"]
    indexes = range(1, len(orders["scored"]) + 1)
    medians = {a: {k: median(rows[i, a][k] for i in indexes) for k in rows[1, a]} for a in caps}
    contrasts = {}
    for k in medians["A"]:
        ratios = [rows[i, "B"][k] / rows[i, "A"][k] for i in indexes]
        if k == "mib_s":
            require(load("complete.json")["candidate_over_control"] == dict(zip(map(str, indexes), ratios)),
                    "driver and replay disagree on paired throughput")
        contrasts[k] = dict(median=median(ratios), ci95=paired_median_interval(ratios),
                            increases=sum(r > 1 for r in ratios))
    return dict(evidence="Darwin host relay and load process, anonymous Unix socket pairs, no VM",
                clean_pairs=len(indexes), warmup_pairs=len(orders["warmup"]), verified_fresh_scored=counts,
                arm_medians=medians, paired_B_over_A=contrasts)


if __name__ == "__main__":
    print(json.dumps(summarize(HERE / "read-size-run"), indent=2, allow_nan=False))
