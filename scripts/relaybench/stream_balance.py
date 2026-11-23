"""Replay whole-window per-stream byte counts from two fixed mixed-TCP workloads."""
import argparse
import json
import math
from pathlib import Path
from statistics import median

from gamma_contrasts import IMAGE, RELAY, VM, clean_client, paired_median_interval, read_receipt, relay_rows, stream_rates


RELAY_SHA = "82ceb6976075b8054e61524777d2da8302f19cce2552a1c07515668686c6c969"
VM_SHA = "066cd4071f3f926a228d87310f6d7b6f361c38f07c7a8240aa09a57f03f201e4"


def product_holdout(vm):
    phases = vm["phases"]["grace-holdout"]["runs"]
    clean, failed = {}, []
    for arm in ("confirm-micropod", "confirm-orb"):
        assert vm["scopes"][arm]["image"] == IMAGE
        clean[arm] = {}
        for key, record in sorted(phases[arm].items(), key=lambda item: int(item[0])):
            client = record["client"]
            valid = clean_client(client)
            assert valid == record["clean"], (arm, key)
            if valid:
                clean[arm][int(key)] = stream_rates(client, client["window_s"], client["mib_s"])
            else:
                failed.append(dict(arm=arm, round=int(key), errors=client["errors"], reopened=client["reopened"]))
    mp, orb = clean["confirm-micropod"], clean["confirm-orb"]
    common = sorted(mp.keys() & orb.keys())
    actual = [mp[i]["mib_s"] / orb[i]["mib_s"] for i in common]
    equalized = [mp[i]["equalized_mib_s"] / orb[i]["mib_s"] for i in common]
    return dict(clean_rounds=clean, rejected_rounds=failed,
                extra_mib_s_min_median_max=spread(r["extra_mib_s"] for r in mp.values()),
                extra_pct_min_median_max=spread(r["extra_pct"] for r in mp.values()),
                orb_minus_micropod_clean_arm_medians_mib_s=median(r["mib_s"] for r in orb.values())
                                                            - median(r["mib_s"] for r in mp.values()),
                paired=dict(rounds=common, median_ratio=median(actual), median_equalized_ratio=median(equalized),
                            equalized_ratio_bootstrap_ci95=paired_median_interval(equalized),
                            wins=sum(r > 1 for r in actual), wins_if_equalized=sum(r > 1 for r in equalized),
                            newly_won_rounds=[i for i, a, e in zip(common, actual, equalized) if a <= 1 < e]))


def spread(values):
    values = list(values)
    return [min(values), median(values), max(values)]


def component_screen(relay):
    screen = relay["selection_screens"]["handoff_screen"]
    records = [r for r in screen["rounds"] if r["ports"] == 1 and r["arm"] in ("balanced2", "balanced4")]
    rounds = {}
    for record, checked in zip(records, relay_rows(records, 80)):
        sample = record["sample"]
        owners = [16, 16] if record["arm"] == "balanced2" else [8, 8, 8, 8]
        assert checked["clean"] and sample["profile"] == 0 and sample["bulk_flows_per_owner"] == owners
        assert sample["elapsed_ns"] >= 2_000_000_000 and math.isclose(checked["mib_s"], record["mib_s"])
        rates = stream_rates(sample, sample["elapsed_ns"] / 1e9, record["mib_s"])
        block = rounds.setdefault(record["round"], {})
        assert record["arm"] not in block
        block[record["arm"]] = rates
    assert sorted(rounds) == [1, 2, 3]
    above = [i for i, r in rounds.items() if r["balanced4"]["slowest_mib_s"] > r["balanced2"]["fastest_mib_s"]]
    return dict(protocol=screen["protocol"], selected_ports=1, rounds=rounds,
                four_worker_slowest_exceeds_two_worker_fastest=sorted(above))


def replay():
    return dict(source_sha256={VM.name: VM_SHA, RELAY.name: RELAY_SHA},
                scope="Whole-window per-stream rates. The sensitivity fixes window duration and fastest observed stream rate, "
                      "then assigns that rate to all 32 streams. Within-window timing and service attribution are unavailable.",
                product=product_holdout(read_receipt(VM, VM_SHA)), component=component_screen(read_receipt(RELAY, RELAY_SHA)))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(replay(), indent=2, allow_nan=False) + "\n")
