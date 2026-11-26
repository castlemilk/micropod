"""Break-even CPU accounting using two checksum-pinned historical Gamma archives."""

import json
import math
import sys
from pathlib import Path
from statistics import median

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "scripts/relaybench"))
from gamma_contrasts import RELAY, contrast, read_receipt, relay_rows
from peer_verdict import archived

RELAY_SHA = "82ceb6976075b8054e61524777d2da8302f19cce2552a1c07515668686c6c969"


def break_even(pair, multiplier):
    """Scale scored bytes in the same duration, while retaining each counter bracket."""
    roles = pair["A"]["processes"]
    relay, vmm = roles["relay"], roles["vmm"]
    if not relay["sample_seconds"] == vmm["sample_seconds"] > 0:
        raise ValueError("processes must share a single counter bracket")
    dr, dv = relay["cpu_s_per_gib"], vmm["cpu_s_per_gib"]
    # Same sampled total CPU seconds before and after: g*(Dv + Dr') = Dv + Dr.
    relay_target = (dv + dr) / multiplier - dv
    if not math.isclose(multiplier * (dv + relay_target), dv + dr, rel_tol=1e-12):
        raise ValueError("CPU budget did not balance")
    # With unchanged work/GiB in each process, delivered CPU seconds scale with the bytes.
    extra_cores = {
        role: (multiplier - 1) * data["cpu_s"] / data["sample_seconds"]
        for role, data in roles.items()
    }
    return {
        "pair": pair["pair"],
        "order": pair["order"],
        "micropod_mib_s": pair["A"]["mib_s"],
        "bracket_seconds": relay["sample_seconds"],
        "observed_relay_cpu_s_per_scored_gib": dr,
        "observed_vmm_cpu_s_per_scored_gib": dv,
        "at_fixed_total_cpu_target_relay_cpu_s_per_scored_gib": relay_target,
        "at_fixed_total_cpu_relay_cost_reduction": 1 - relay_target / dr,
        "at_fixed_cost_extra_mean_cores_relay": extra_cores["relay"],
        "at_fixed_cost_extra_mean_cores_vmm": extra_cores["vmm"],
        "at_fixed_cost_extra_mean_cores_total": sum(extra_cores.values()),
    }


def scenario(pairs, multiplier):
    rows = [break_even(pair, multiplier) for pair in pairs]
    summary = {}
    for key in rows[0]:
        if key.startswith(("at_", "observed_")):
            values = [row[key] for row in rows]
            summary[key] = {"min": min(values), "median": median(values), "max": max(values)}
    return {
        "uniform_vm_rate_multiplier": multiplier,
        "metrics": summary,
        "rows": rows,
    }


def replay():
    peer = archived()  # Rechecks bytes, counter PIDs and births, chronology, quotas and loss.
    vm = peer["arm_clean_medians_and_all_attempt_counts"]
    pairs = peer["pairs"]
    clean_mp = [pair for pair in pairs if pair["A"]["clean"]]
    common = [pair for pair in clean_mp if pair["B"]["clean"]]
    source = read_receipt(RELAY, RELAY_SHA)
    samples = relay_rows(source["selection_screens"]["handoff_screen"]["rounds"], 80)
    host = contrast(samples, "balanced2", "balanced4", 1)
    return {
        "evidence": "Historical CPU budget sensitivity. No VM worker-count intervention.",
        "inputs": {RELAY.name: RELAY_SHA, peer["source"]: peer["source_sha256"]},
        "assumptions": [
            "One uniform rate multiplier for each eligible historical Micropod round.",
            "Unchanged score and counter-bracket durations within that round.",
            "Whole-invocation CPU divided by scored payload approximates proportional work. Setup and drain are included.",
            "Fixed total CPU case assumes the VMM retains its measured CPU-s/scored-GiB and the two processes can redistribute CPU.",
            "Fixed per-GiB cost case assumes both processes retain their respective CPU-s/scored-GiB.",
        ],
        "host_worker_screen": host,
        "historical_vm": {
            "clean_arm_medians_and_all_attempt_counts": vm,
            "median_gap_mib_s": vm["OrbStack"]["mib_s"] - vm["Micropod"]["mib_s"],
            "paired_median_micropod_over_orbstack": peer["median_ratio"],
            "paired_ci95": peer["bootstrap_ci95"],
            "omitted_from_paired_estimate": [p["pair"] for p in pairs if not (p["A"]["clean"] and p["B"]["clean"])],
        },
        "match_clean_arm_medians": scenario(clean_mp, vm["OrbStack"]["mib_s"] / vm["Micropod"]["mib_s"]),
        "match_paired_point_estimate": scenario(common, 1 / peer["median_ratio"]),
    }


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2, allow_nan=False))
