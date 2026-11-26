"""Attribute Go test wall time using the action graph of the pinned CI toolchain."""
import argparse
from collections import Counter
import gzip
import json
from pathlib import Path
import shutil
from statistics import median

import sibling_build_phases as phases
import sibling_ci
from sibling_results import docker_time_ns, read
from sibling_worker_volume import mounted_worker_volume
from sibling_worker_volume_results import verify_volume
from qualify import require, terminal


DRIVER = "sibling_go_test_actions.py"
JOB = "go-test-actions-job.sh"
DISPATCH = "go-test-actions-dispatch.sh"
VERSION = "go version go1.26.11 linux/arm64"
PACKAGES = {"github.com/castlemilk/micropod/guest", "github.com/castlemilk/micropod/guest/cmd/oci-batch"}
COLLECT = '''set -eu
printf '%s\\n' "$(go version)" "$MP_RAW_ID" "$(cat /proc/sys/kernel/random/boot_id)"
printf '['
cat -- "$1/$2-a.json"
printf ','
cat -- "$1/$2-b.json"
printf ']'
rm -- "$1/$2-a.json" "$1/$2-b.json"
'''


def variants(folder):
    job = (folder / phases.JOB).read_text()
    dispatch = (folder / phases.DISPATCH).read_text()
    open_phase = 'phase_open "$gate" "$slot"\n'
    require(job.count("go test -x ") == dispatch.count(open_phase) == 1 and dispatch.count(phases.JOB) == 2,
            "the qualified phase controls or Go invocation have changed")
    return {JOB: job.replace("go test -x ", 'go test -debug-actiongraph="$MP_GO_ACTION_DIR/$1.json" -x '),
            DISPATCH: dispatch.replace(open_phase, open_phase + 'export MP_GO_ACTION_DIR="$phase_dir"\n')
                              .replace(phases.JOB, JOB)}


def stage(folder, work, env):
    evidence = phases.stage(folder, work, env)
    scripts = variants(folder)
    for name, script in scripts.items():
        (folder / name).write_text(script)
        (work / "probe" / ("go-dispatch.sh" if name == DISPATCH else name)).write_text(script)
    shutil.copyfile(Path(__file__), folder / DRIVER)
    return {**evidence, "go_test_actions": True, "go_test_action_sources": {
        name: terminal.digest(folder / name) for name in (*scripts, DRIVER)}}


def collect_argv(tag, slot, job):
    prefix = f"sibling-{tag.split('-')[1]}-{slot}"
    return ["exec", job["id"], "/bin/sh", "-ec", COLLECT, "collect",
            f"/dev/shm/mp-build-phases.{tag}.{slot}", prefix]


def collect(cohort, folder, tag):
    def get(item):
        slot, job = item
        argv = collect_argv(tag, slot, job)
        version, container, boot, raw = cohort.cmd(*argv, timeout=35).split("\n", 3)
        require(version == VERSION and container == job["name"], "unexpected Go graph producer")
        return {"version": version, "container": container, "boot": boot, "argv": argv, "graphs": json.loads(raw)}

    jobs = cohort.jobs[cohort.count:cohort.count + cohort.builders]
    rows = sibling_ci.parallel(8, get, enumerate(jobs))
    with gzip.open(folder / f"go-test-actions-{tag}.json.gz", "xt", compresslevel=1) as dest:
        json.dump(rows, dest, separators=(",", ":"))
    phases.collect(cohort, folder, tag)


def action_totals(graph, begin, end):
    ids = set(range(len(graph)))
    require(len(graph) >= 10 and [a["ID"] for a in graph] == list(range(len(graph))) and
            graph[0]["Mode"] == "go test", "invalid action graph")
    mode_counts = Counter()
    ranges = []
    for row in graph:
        deps = row.get("Deps", [])
        require(not row.get("Failed") and set(deps) <= ids - {row["ID"]},
                "failed action or malformed dependency")
        start, done = (docker_time_ns(row[k]) for k in ("TimeStart", "TimeDone"))
        require(begin <= start <= done <= end, "action escaped its recorded test phase")
        mode = row["Mode"]
        mode_counts[mode] += 1
        if mode == "build":
            group = "external_build_action" if row["Cmd"] else "other_build_action"
        elif mode in {"link", "test run", "vet", "build check cache"}:
            group = mode
        else:
            group = "other_action"
        ranges.append((start, done, group, row["ID"]))
    # cmd/go can list the same prerequisite more than once for different imports.
    visited, active = set(), set()

    def visit(index):
        if index in visited:
            return
        require(index not in active, "cyclic Go action graph")
        active.add(index)
        for dep in graph[index].get("Deps", []):
            visit(dep)
        active.remove(index)
        visited.add(index)

    visit(0)
    require(visited == ids, "disconnected Go action graph")
    require(mode_counts["go test"] == 1 and {r["Package"] for r in graph if r["Mode"] == "test run"} == PACKAGES and
            mode_counts["test run"] == mode_counts["link"] == 2 and mode_counts["build check cache"] > 0,
            "missing Go tests, link, or cache actions")
    # -p=1 serializes the Go driver's actions. The gaps also include graph serialization.
    ranges.sort()
    elapsed = Counter()
    previous = ranges[0][0]
    elapsed["before_first_action"] = previous - begin
    by_id = {}
    for start, done, group, index in ranges:
        require(start >= previous, "parallel actions cannot be summed as sequential wall time")
        elapsed["between_actions"] += start - previous
        elapsed[group] += done - start
        by_id[index] = (start, done)
        previous = done
    require(all(by_id[dep][1] <= by_id[row["ID"]][0] for row in graph for dep in row.get("Deps", [])),
            "action begins before its prerequisite has returned")
    elapsed["after_last_action"] = end - previous
    require(sum(elapsed.values()) == end - begin, "unattributed action-graph time")
    return {"nodes": len(graph), "modes": dict(mode_counts), "elapsed_ns": dict(elapsed), "phase_ns": end - begin}


def tool_counters(graph):
    main = "github.com/castlemilk/micropod/guest"
    expected = {("compile", main), ("compile", main + ".test"), ("vet", main),
                ("link", main + ".test"), ("link", main + "/cmd/oci-batch.test")}
    observed = {}
    for node in graph:
        if not node["Cmd"]:
            continue
        require(len(node["Cmd"]) == 1, "compound Go tool accounting")
        executable = node["Cmd"][0].split(" ", 1)[0]
        binary = Path(executable).name
        key = binary, node["Package"]
        require(executable == "/usr/local/go/pkg/tool/linux_arm64/" + binary and key in expected - observed.keys(),
                "unexpected or repeated external Go tool command")
        actual = {name: node.get(field, 0) for name, field in (
            ("wall", "CmdReal"), ("user", "CmdUser"), ("system", "CmdSys"))}
        require(all(type(value) is int and value >= 0 for value in actual.values()) and
                0 < actual["wall"] <= docker_time_ns(node["TimeDone"]) - docker_time_ns(node["TimeStart"]),
                "invalid external Go command timing")
        observed[key] = actual
    require(observed.keys() == expected, "missing Go tools from the instrumented test")
    return {tool: {field: sum(c[field] for (binary, _), c in observed.items() if binary == tool)
                   for field in ("wall", "user", "system")} for tool in ("compile", "vet", "link")}


def replay(folder):
    plan = read(folder, "plan.json")
    scripts = variants(folder)
    require(plan["go_test_actions"] is True and plan["go_test_action_sources"] == {
        name: terminal.digest(folder / name) for name in (*scripts, DRIVER)} and
        all((folder / name).read_text() == script for name, script in scripts.items()), "modified action observer")
    baseline = phases.replay(folder)
    volume = verify_volume(folder)
    inventory = read(folder, "grouped-inventory.json")
    windows = []
    for block in baseline["windows"]:
        arms = {}
        for arm in block["order"]:
            tag = f"grouped-{block['block']}-all-{arm}"
            with gzip.open(folder / f"go-test-actions-{tag}.json.gz", "rt") as raw:
                records = json.load(raw)
            jobs = inventory[arm]["jobs"][32:40]
            traces = read(folder, "build-phases-" + tag + ".json")
            slots = []
            for slot, (record, job, trace) in enumerate(zip(records, jobs, traces, strict=True)):
                require(record["version"] == VERSION and record["boot"] == baseline["boots"][arm] and
                        record["container"] == job["name"] and record["argv"] == collect_argv(tag, slot, job) and
                        len(record["graphs"]) == 2, "graph provenance mismatch")
                marks = {(m["revision"], m["phase"]): m for m in trace["trace"]["markers"]}
                revisions = []
                for suffix, graph in zip(("a", "b"), record["graphs"], strict=True):
                    rev = f"sibling-{block['block']}-{slot}-{suffix}"
                    totals = action_totals(graph, marks[rev, "test"]["ended_unix_ns"],
                                           marks[rev, "build"]["started_unix_ns"])
                    revisions.append({**totals, "tool_ns": tool_counters(graph)})
                slots.append(revisions)
            arms[arm] = slots
        late = [block["arms"]["A"][key] for key in ("last_finisher_slot", "penultimate_finisher_slot")]
        windows.append({"block": block["block"], "native_last_two_slots": late, "arms": arms})
    gaps = {}
    for select_late in (False, True):
        pairs = [(w["arms"]["A"][i], w["arms"]["B"][i]) for w in windows for i in (
            w["native_last_two_slots"] if select_late else range(8))]
        gaps["native_last_two" if select_late else "all"] = []
        for rev in (0, 1):
            groups = sorted({key for a, b in pairs for slot in (a, b) for key in slot[rev]["elapsed_ns"]})
            samples = {key: [a[rev]["elapsed_ns"].get(key, 0) - b[rev]["elapsed_ns"].get(key, 0)
                             for a, b in pairs] for key in groups}
            # Means add to the measured gap. Component medians do not have that property.
            deltas = [a[rev]["phase_ns"] - b[rev]["phase_ns"] for a, b in pairs]
            gaps["native_last_two" if select_late else "all"].append({
                "pairs": len(pairs), "phase_mean_ns": sum(deltas) / len(pairs), "phase_median_ns": median(deltas),
                "group_mean_ns": {k: sum(v) / len(v) for k, v in samples.items()},
                "group_median_ns": {k: median(v) for k, v in samples.items()},
                "tool_mean_gap_ns": {tool: {field: sum(a[rev]["tool_ns"][tool][field] - b[rev]["tool_ns"][tool][field]
                                                       for a, b in pairs) / len(pairs)
                                            for field in ("wall", "user", "system")}
                                     for tool in ("compile", "vet", "link")}})
    return {"archive": folder.name, "diagnostic_only": True, "version": VERSION,
            "boots": baseline["boots"], "host_volume": volume, "windows": windows, "native_minus_orb": gaps}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    verbs = parser.add_subparsers(dest="verb", required=True)
    live = verbs.add_parser("run")
    live.add_argument("--seed", type=int, choices=(phases.SEED,), required=True)
    for name in ("product", "page-kernel-pair", "ipvlan-kernel", "quiet-source", "image-archive"):
        live.add_argument("--" + name, type=Path, required=True)
    verbs.add_parser("replay").add_argument("folder", type=Path)
    args = parser.parse_args()
    if args.verb == "replay":
        print(json.dumps(replay(args.folder), indent=2))
        return
    with mounted_worker_volume():
        folder = phases.run(args, archive_kind="sibling-go-test-actions", stage_probe=stage, collect_probe=collect)
    try:
        terminal.save(folder / "go-test-actions-summary.json", replay(folder))
    except BaseException as exc:
        terminal.save(folder / "status.json", {"complete": False, "diagnostic_only": True, "error": str(exc)})
        raise


if __name__ == "__main__":
    main()
