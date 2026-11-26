"""Replay one-factor VMM service accounting on the archived four-vCPU pair study."""
import hashlib
import json
import math
from pathlib import Path
from statistics import median, stdev

from gamma_contrasts import ROOT, VM, read_receipt, vm_rows
from peer_verdict import ARCHIVE_SHA, archived


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def arm(row, client):
    counters = row["vmm"]
    return {
        "clean": row["clean"],
        "mib_s": row["mib_s"],
        "p95_ms": row["p95_ms"],
        "p99_ms": row["p99_ms"],
        "fresh_failed": row["fresh_failed"],
        "bulk_reopens": row["reopened"],
        "score_bytes": client["bytes"],
        "score_s": client["window_s"],
        "counter_s": counters["sample_seconds"],
        "vmm_cores": counters["cpu_s"] / counters["sample_seconds"],
        "score_bytes_per_vmm_cpu_s": client["bytes"] / counters["cpu_s"],
        "processes": {
            role: {key: row[role][key] for key in ("cpu_s_per_gib", "runnable_s_per_s", "wait_s_per_s")}
            for role in ("relay", "vmm") if role in row
        },
    }


def summarize(pairs, reference=None):
    service = [p["relative_vmm_cores"] for p in pairs]
    if reference is None:
        reference = median(service)
    observed = [p["rate_ratio"] for p in pairs]
    fixed = [p["rate_ratio"] * reference / p["relative_vmm_cores"] for p in pairs]
    return {
        "pairs": len(pairs),
        "fixed_relative_vmm_cores": reference,
        "observed_median_ratio": median(observed),
        "service_fixed_median_ratio": median(fixed),
        "observed_log_ratio_sd": stdev(math.log(x) for x in observed),
        "service_fixed_log_ratio_sd": stdev(math.log(x) for x in fixed),
        "observed_wins": sum(x > 1 for x in observed),
        "service_fixed_above_one": sum(x > 1 for x in fixed),
    }


def main():
    checked = archived()  # Validates raw workload, chronological order, counter identities and clean flags.
    receipt = read_receipt(VM, ARCHIVE_SHA)
    phase = receipt["phases"]["grace-holdout"]
    rows = {(r["round"], r["arm"]): r for r in vm_rows(receipt)}
    pairs = []
    for source in checked["pairs"]:
        i = source["pair"]
        arms = {}
        for label, name in (("Micropod", "confirm-micropod"), ("OrbStack", "confirm-orb")):
            arms[label] = arm(rows[i, name], phase["runs"][name][str(i)]["client"])
        a, b = arms["Micropod"], arms["OrbStack"]
        service = a["vmm_cores"] / b["vmm_cores"]
        efficiency = a["score_bytes_per_vmm_cpu_s"] / b["score_bytes_per_vmm_cpu_s"]
        bracket = (a["counter_s"] / a["score_s"]) / (b["counter_s"] / b["score_s"])
        rate = a["mib_s"] / b["mib_s"]
        if not math.isclose(service * efficiency * bracket, rate, rel_tol=1e-12):
            raise ValueError(f"throughput decomposition disagrees at pair {i}")
        pairs.append(dict(pair=i, order=source["order"], common_clean=a["clean"] and b["clean"],
                          rate_ratio=rate, relative_vmm_cores=service, relative_payload_per_cpu_s=efficiency,
                          relative_bracket_over_score=bracket, arms=arms))

    common = [p for p in pairs if p["common_clean"]]
    primary = summarize(common)
    reference = primary["fixed_relative_vmm_cores"]
    for pair in pairs:
        pair["service_fixed_ratio_at_common_reference"] = pair["rate_ratio"] * reference / pair["relative_vmm_cores"]
    delete_block = []
    for block in range(8):
        kept = [p for p in common if (p["pair"] - 1) // 2 != block]
        delete_block.append(dict(omitted_pairs=[2 * block + 1, 2 * block + 2], **summarize(kept)))
    here = Path(__file__).resolve()
    print(json.dumps({
        "date": "2026-11-24",
        "stable_id": "228.02",
        "issue": 228,
        "analysis": "peer-vmm-service",
        "tier": "Local raw-verified accounting replay of archived VM peer timings. No new timed holdout.",
        "revision": {
            "supporting_checkout": "2ccda8507355b8220258db2ce8160f3113d3e1ff",
            "replay_sha256": digest(here),
            "input": str(VM.relative_to(ROOT)),
            "input_sha256": ARCHIVE_SHA,
            "recorded_source_base": receipt["baseline_commit"],
            "installed_host_package_sha256": receipt["installation"]["host_sha256"],
            "fixture_image": receipt["binaries"]["image_config"],
            "client_sha256": receipt["binaries"]["client"],
            "source_timestamp": receipt["captured_utc"],
        },
        "workload": "Four vCPUs and nominal 4 GiB per VM, same image, four-CPU service quota, 32 downloads "
                    "and 240 fresh GETs per arm spaced 25 ms apart over six seconds. A is Micropod. B is OrbStack.",
        "method": "Control is the observed Micropod/OrbStack rate ratio in each pair. Replace only the ratio "
                  "of whole-VMM host CPU-s/wall-s with its common-clean median. Hold each pair's scored bytes "
                  "per bracket CPU-s and bracket-to-score durations at their measured values. The three "
                  "factors multiply to the observed ratio. Compare sample standard deviations of log ratios.",
        "limits": "This is an accounting identity using total host VMM CPU across setup, score and drain. "
                  "A change in service can reflect CPU availability, guest demand, blocking or thread mix. "
                  "These data do not identify a QoS effect, a kernel bottleneck or an achievable speedup. "
                  "The two VMM process boundaries differ. Orders alternated. One failed first attempt "
                  "has a valid bulk rate and remains visible in the all-attempt sensitivity.",
        "next_check": "During a separately admitted diagnostic on the revised fixture, align scored bytes "
                      "with per-vCPU on-CPU, runnable off-CPU and blocked time plus effective QoS and host "
                      "core placement. Separate runnable starvation from reduced runnable demand.",
        "guardrail_units": "Fresh p95/p99 are medians of per-attempt percentiles on each arm's clean attempts. "
                           "All first attempts contribute failures and reopens. Process CPU-s/GiB uses scored "
                           "payload and whole-invocation CPU. Runnable and wait use thread-seconds per bracket second.",
        "guardrails": checked["arm_clean_medians_and_all_attempt_counts"],
        "observed_paired_bootstrap_ci95": checked["bootstrap_ci95"],
        "primary_common_clean": primary,
        "by_order_at_common_reference": {
            order: summarize([p for p in common if p["order"] == order], reference) for order in ("AB", "BA")
        },
        "all_first_attempts_at_common_reference": summarize(pairs, reference),
        "leave_one_two_pair_block_out_refitting_reference": delete_block,
        "scored_first_attempts": pairs,
    }, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
