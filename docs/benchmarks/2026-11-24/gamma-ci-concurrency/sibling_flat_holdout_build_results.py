"""Explain build batch tails in the two accepted flat job-parent holdout boots."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
from statistics import median

from qualify import require
import sibling_build_tail_results as tail


SEEDS = (250227, 250229)
SOURCES = {
    "job.sh": "a9d3447427636fb10c6a0005c44a3936c2b3a9b61cb4983f39c0308d917a3704",
    "go-dispatch.sh": "b2b23088007a7ffd68372e1ae385e445554f7bd2b10d07741bdbdd3a07701762",
}


def revision_cpu(raw, elapsed_ns):
    first, second, _ = raw["stdout"].splitlines()
    a, b = (tuple(map(int, row.split()[3:5])) for row in (first, second))
    counts = [(end - start) * 1000 for start, end in (a, b)]
    require(0 < a[0] < a[1] <= b[0] < b[1] and sum(counts) <= elapsed_ns,
            "revision cgroup CPU marks contradict their serial singleton-CPU interval")
    return {"elapsed_ns": elapsed_ns, "revision_cgroup_cpu_ns": counts,
            "wall_minus_marked_cgroup_cpu_ns": elapsed_ns - sum(counts)}


def gap(slot):
    a, b = slot["A"], slot["B"]
    revisions = [x - y for x, y in zip(a["revision_cgroup_cpu_ns"], b["revision_cgroup_cpu_ns"], strict=True)]
    return {"elapsed_ns": a["elapsed_ns"] - b["elapsed_ns"], "revision_cgroup_cpu_ns": revisions,
            "two_revision_cgroup_cpu_ns": sum(revisions),
            "wall_minus_marked_cgroup_cpu_ns": a["wall_minus_marked_cgroup_cpu_ns"] - b["wall_minus_marked_cgroup_cpu_ns"]}


def windows(folder, run):
    for row in run["windows"]:
        block = row["round"]
        raw = {arm: tail.read(folder, f"grouped-{block}-all-{arm}-go.json") for arm in "AB"}
        slots = [{"slot": r["slot"], "vcpu": r["cpu"], **{
            arm: revision_cpu(raw[arm][r["slot"]], r["elapsed_ns"][arm]) for arm in "AB"}}
                 for r in row["slots"]]
        a = row["engines"]["A"]
        actual = row["gap_ns"]["makespan_ns"]
        yield {"seed": run["seed"], "round": block, "order": row["order"], "engines": row["engines"],
               "gap_ns": row["gap_ns"], "slots": slots,
               "aligned_start_gap_ns": row["gap_ns"]["slowest_job_elapsed_ns"],
               "launch_penalty_gap_ns": actual - row["gap_ns"]["slowest_job_elapsed_ns"],
               "gap_without_native_last_ns": actual - a["last_vs_penultimate_finish_ns"],
               "matched_native_last_gap": gap(slots[a["last_finisher_slot"]]),
               "matched_native_penultimate_gap": gap(slots[a["penultimate_finisher_slot"]])}


def distribution(values):
    return {"median_ns": median(values), "sum_ns": sum(values), "min_ns": min(values), "max_ns": max(values),
            "negative_count": sum(value < 0 for value in values), "count": len(values)}


def summarize(rows):
    slots = [gap(slot) for row in rows for slot in row["slots"]]
    fields = ("elapsed_ns", "two_revision_cgroup_cpu_ns", "wall_minus_marked_cgroup_cpu_ns")
    metrics = ("aligned_start_gap_ns", "launch_penalty_gap_ns", "gap_without_native_last_ns")
    largest = max(rows, key=lambda row: row["gap_ns"]["makespan_ns"])
    remaining = [row["gap_ns"]["makespan_ns"] for row in rows if row is not largest]
    return {"window_sensitivity": {k: distribution([row[k] for row in rows]) for k in metrics},
            "matched_slots": {**{k: distribution([row[k] for row in slots]) for k in fields},
                              "revision_cgroup_cpu_ns": [distribution([row["revision_cgroup_cpu_ns"][i] for row in slots])
                                                          for i in range(2)]},
            "matched_native_tail": {role: {k: distribution([row[f"matched_native_{role}_gap"][k] for row in rows])
                                           for k in fields} for role in ("last", "penultimate")},
            "largest_batch_gap": {"seed": largest["seed"], "round": largest["round"], "order": largest["order"],
                                  "gap_ns": largest["gap_ns"]["makespan_ns"],
                                  "native_slower_slots": sum(gap(slot)["elapsed_ns"] > 0 for slot in largest["slots"]),
                                  "remaining_batch_gaps": distribution(remaining)}}


def report(folders):
    folders = {tail.read(folder, "plan.json")["seed"]: folder for folder in folders}
    require(set(folders) == set(SEEDS), "expected the two prespecified flat holdout seeds")
    for folder in folders.values():
        plan = tail.read(folder, "plan.json")
        require(plan["job_parent"] == "flat" and plan["worker_scheduler"] == "hrtick-250us"
                and plan["offered_rps"] == 64_000 and plan["build_scratch"] == "tmpfs" and plan["rounds"] == 4
                and all(sha256((folder / name).read_bytes()).hexdigest() == digest for name, digest in SOURCES.items()),
                "unexpected flat worker, revision source, or dispatcher")
    baseline = tail.report(list(folders.values()))
    runs = []
    for run in baseline["runs"]:
        matched = list(windows(folders[run["seed"]], run))
        runs.append({"archive": run["run"], "seed": run["seed"], "boots": run["boots"], "summary": run["summary"],
                     "analysis": summarize(matched), "windows": matched})
    rows = [row for run in runs for row in run["windows"]]
    return {
        "engines": baseline["engines"], "gap_direction": baseline["gap_direction"], "settings": baseline["settings"],
        "scripts_sha256": SOURCES, "batch_summary": baseline["summary"], "analysis": summarize(rows), "runs": runs,
        "measurement": {
            "elapsed": "Guest wall time from each ready dispatcher's start mark through the two serial revisions and dispatcher end.",
            "revision": "Each revision has two cumulative cgroup usage_usec reads. Their difference includes concurrent HTTP and other work in that builder cgroup.",
            "residual": "Dispatcher wall time minus the two marked cgroup CPU intervals. It includes waiting and work elsewhere or outside the sampled parts, including go list and receipt generation.",
            "counterfactuals": "Arithmetic on measured intervals. The aligned start holds each observed elapsed time fixed. The removed last result keeps the other seven native finishes and the observed peer batch.",
            "independence": "Four windows per native boot. The two native boots share the same OrbStack comparison boot.",
        },
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folders", type=Path, nargs=2)
    print(json.dumps(report(parser.parse_args().folders), indent=2))
