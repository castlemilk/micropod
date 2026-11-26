"""Run and replay one diagnostic of the original two-revision Go build phases."""

import argparse
from datetime import UTC, datetime
import json
import os
from pathlib import Path
import re
import shutil
import signal
from statistics import median
import tempfile
from unittest.mock import patch

import sibling_build
import sibling_build_tail_results as tail
import sibling_ci
from sibling_flat_holdout_build_results import SOURCES as STOCK_SOURCES
import sibling_job_parent
from qualify import HERE, require, terminal


SEED = 250239
ORDER = ("BA", "AB", "BA", "AB")
SOURCE = "sibling_build_phases_linux.go"
DRIVER = "sibling_build_phases.py"
PROBE = "build-phases-probe"
CONTROL_FILE = "build-phases-control.sh"
JOB = "build-phases-job.sh"
DISPATCH = "build-phases-dispatch.sh"
PHASE_ANCHORS = (
    ("setup", "umask 022"), ("vet", "go vet -x "), ("test", "go test -x "),
    ("build", "go build -x "), ("verify", 'test "$("$tmp"/product ci-revision)"'),
    ("post_mark", "after=$(mark)"), ("go_list", "archive=$(go list -export "),
    ("receipt", "printf '%s %s %s "),
)
PHASES = tuple(phase for phase, _ in PHASE_ANCHORS) + ("end",)
CALIBRATION = ("marker_roundtrip_begin", "marker_roundtrip_end")
COUNTERS = ("cpu.stat", "cpu.pressure", "io.pressure")
MOUNT_TYPES = {"/dev/shm": "tmpfs", "/sys/fs/cgroup": "cgroup2"}
COLLECT = 'cat -- "$1/trace.json"; rm -- "$1/trace.json"; rmdir -- "$1"'

CONTROL = r'''
phase_cleanup() {
    if [ -n "$phase_pid" ]; then
        kill "$phase_pid" 2>/dev/null || :
        wait "$phase_pid" 2>/dev/null || :
    fi
    rm -f -- "$phase_dir/command" "$phase_dir/response" "$phase_dir/trace.json"
    rmdir -- "$phase_dir"
}
phase_open() {
    case "$1" in grouped-[0123]-all-[AB]) ;; *) return 64 ;; esac
    case "$2" in [01234567]) ;; *) return 64 ;; esac
    phase_dir="/dev/shm/mp-build-phases.$1.$2"
    [ "$(stat -f -c %T /dev/shm)" = tmpfs ]
    mkdir -m 0700 -- "$phase_dir"
    phase_pid=
    trap phase_cleanup EXIT
    mkfifo -m 0600 -- "$phase_dir/command" "$phase_dir/response"
    GOMAXPROCS=1 GOGC=off /mpcheck/build-phases-probe "$1" "$2" "$phase_dir/trace.json" \
        < "$phase_dir/command" > "$phase_dir/response" &
    phase_pid=$!
    exec 8>"$phase_dir/command" 9<"$phase_dir/response"
    IFS= read -r phase_reply <&9
    [ "$phase_reply" = ready ]
}
phase_mark() {
    printf '%s\t%s\n' "$1" "$2" >&8
    IFS= read -r phase_reply <&9
    [ "$phase_reply" = "$1/$2" ]
}
phase_close() {
    printf 'finish\n' >&8
    exec 8>&- 9<&-
    wait "$phase_pid"
    phase_pid=
    rm -- "$phase_dir/command" "$phase_dir/response"
    trap - EXIT
}
'''


def variants(job, dispatch):
    source = []
    inserted = []
    for line in job.splitlines(keepends=True):
        for phase, prefix in PHASE_ANCHORS:
            if line.startswith(prefix):
                source.append(f'phase_mark "$1" {phase}\n')
                inserted.append(phase)
        source.append(line)
        if line == "set -eu\n":
            source.append(f". /mpcheck/{CONTROL_FILE}\n")
    require(tuple(inserted) == PHASES[:-1], "stock Go phase anchors changed")
    source.append('phase_mark "$1" end\n')
    ready = 'printf ready > "/gate/$gate.go.$slot.ready"\n'
    start = 'mv "/gate/$gate.go.$slot.tmp" "/gate/$gate.go.$slot.start"\n'
    require(dispatch.count(ready) == dispatch.count(start) == 1 and dispatch.count("/mpcheck/job.sh") == 2,
            "stock dispatcher anchors changed")
    calibrated = "".join(f'phase_mark "$revision" {key}\n' for key in CALIBRATION)
    launched = dispatch.replace(ready, f'. /mpcheck/{CONTROL_FILE}\nphase_open "$gate" "$slot"\n' + ready)
    launched = launched.replace(start, start + calibrated).replace("/mpcheck/job.sh", "/mpcheck/" + JOB)
    return {CONTROL_FILE: CONTROL, JOB: "".join(source), DISPATCH: launched + "phase_close\n"}


def stage(folder, work, env):
    require(all(terminal.digest(folder / name) == digest for name, digest in STOCK_SOURCES.items()),
            "diagnostic needs the original qualified Go workload")
    scripts = variants((folder / "job.sh").read_text(), (folder / "go-dispatch.sh").read_text())
    probe = work / "probe"
    for name, content in scripts.items():
        (folder / name).write_text(content)
        (probe / (name if name != DISPATCH else "go-dispatch.sh")).write_text(content)
    here = Path(__file__).parent
    shutil.copyfile(__file__, folder / DRIVER)
    shutil.copyfile(here / SOURCE, folder / SOURCE)
    terminal.invoke("go", "build", "-trimpath", "-buildvcs=false", "-o", probe / PROBE, folder / SOURCE,
                    env={**(env or os.environ), "GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0", "GOPROXY": "off"},
                    timeout=90)
    return {"build_phases_diagnostic": True, "build_phases_probe_sha256": terminal.digest(probe / PROBE),
            "build_phases_sources": {name: terminal.digest(folder / name) for name in (*scripts, SOURCE, DRIVER)}}


def collect_argv(tag, slot, job):
    return ["exec", job["id"], "/bin/sh", "-ec", COLLECT, "collect", f"/dev/shm/mp-build-phases.{tag}.{slot}"]


def collect(cohort, folder, tag):
    def sample(item):
        slot, job = item
        command = collect_argv(tag, slot, job)
        return {"id": job["id"], "argv": command, "trace": json.loads(cohort.cmd(*command, timeout=12))}

    rows = sibling_ci.parallel(8, sample, enumerate(cohort.jobs[cohort.count:cohort.count + cohort.builders]))
    terminal.save(folder / f"build-phases-{tag}.json", rows)


def counters(raw):
    require("cpu.stat" in raw and raw.keys() <= set(COUNTERS), "unexpected resource counter source")
    values = {f"cpu.stat.{key}": int(value) for key, value in (line.split() for line in raw["cpu.stat"].splitlines())}
    for name in ("cpu.pressure", "io.pressure"):
        if name in raw:
            pressure = {line.split()[0]: int(line.split()[-1].removeprefix("total="))
                        for line in raw[name].splitlines()}
            require(pressure.keys() == {"some", "full"}, "incomplete CPU or IO pressure totals")
            values.update({f"{name}.{kind}": value for kind, value in pressure.items()})
    require("cpu.stat.usage_usec" in values and all(v >= 0 for v in values.values()), "invalid leaf CPU counters")
    return values


def check_trace(record, job, boot, tag, timed, raw):
    slot = timed["slot"]
    proof = record["trace"]
    require(record["id"] == raw["id"] == job["id"] and record["argv"] == collect_argv(tag, slot, job)
            and proof["tag"] == tag and proof["slot"] == slot and proof["container"] == job["name"]
            and proof["boot"] == boot and proof["cgroup"] == "0::/", "phase sidecar belongs to another builder")
    require(proof["mounts"].keys() == MOUNT_TYPES.keys(), "missing phase counter or sidecar mount")
    for target, kind in MOUNT_TYPES.items():
        before, after = proof["mounts"][target].split(" - ")
        parts = before.split()
        require(parts[4] == target and after.split()[0] == kind
                and (parts[3] == "/" if kind == "cgroup2" else "rw" in parts[5].split(",")),
                f"incorrect phase marker mount at {target}")
    revision = raw["revision"]
    expected = [(revision, p) for p in CALIBRATION] + [
        (f"{revision}-{suffix}", phase) for suffix in ("a", "b") for phase in PHASES]
    markers = proof["markers"]
    require([(m["revision"], m["phase"]) for m in markers] == expected, "missing or reordered build marker")
    initial = markers[0]
    previous_end, mono_end, previous_counters = timed["start"], 0, {}
    values = []
    for mark in markers:
        start, end, monotonic, sampled = (mark[k] for k in ("started_unix_ns", "ended_unix_ns", "monotonic_ns", "sample_ns"))
        require(previous_end <= start < end <= timed["end"] and mono_end <= monotonic and sampled > 0
                and abs((start - initial["started_unix_ns"]) - (monotonic - initial["monotonic_ns"])) < 1_000_000
                and abs(end - start - sampled) < 1_000_000, "phase clock escaped its original dispatcher interval")
        observed = counters(mark["counters"])
        require(not values or (observed.keys() == previous_counters.keys()
                               and all(observed[k] >= v for k, v in previous_counters.items())),
                "phase leaf counters reset or changed availability")
        values.append(observed)
        previous_counters, previous_end, mono_end = observed, end, monotonic + sampled

    revisions = []
    usage = "cpu.stat.usage_usec"
    for i, line in enumerate(raw["stdout"].splitlines()[:2]):
        base = len(CALIBRATION) + len(PHASES) * i
        first, last = int(line.split()[3]), int(line.split()[4])
        matched = dict(zip(PHASES, values[base:base + len(PHASES)], strict=True))
        require(matched["setup"][usage] <= first <= matched["vet"][usage]
                and matched["post_mark"][usage] <= last <= matched["go_list"][usage],
                "phase leaf counters do not bracket the original revision usage marks")
        intervals = {}
        for offset, phase in enumerate(PHASES[:-1], base):
            intervals[phase] = {"elapsed_ns": markers[offset + 1]["monotonic_ns"] - markers[offset]["monotonic_ns"],
                                "delta_usec": {k: values[offset + 1][k] - v for k, v in values[offset].items()}}
        revisions.append({"revision": expected[base][0], "phases": intervals})
    roundtrip = markers[1]["monotonic_ns"] - initial["monotonic_ns"]
    sampler = [m["sample_ns"] for m in markers]
    return {"slot": slot, "vcpu": timed["cpu"], "elapsed_ns": timed["elapsed_ns"], "revisions": revisions,
            "marker_roundtrip_ns": roundtrip, "marker_sample_ns": sum(sampler), "slowest_sample_ns": max(sampler)}


def checked_wave(folder, block, arm, jobs, boot):
    tag = f"grouped-{block}-all-{arm}"
    raw = tail.read(folder, tag + "-go.json")
    originals = tail.build_rows(raw, jobs, arm, block, boot, 0)
    records = tail.read(folder, "build-phases-" + tag + ".json")
    return [check_trace(trace, job, boot, tag, timed, original)
            for trace, job, timed, original in zip(records, jobs, originals, raw, strict=True)]


def phase_gaps(pairs):
    return [{phase: median(a["revisions"][r]["phases"][phase]["elapsed_ns"]
                           - b["revisions"][r]["phases"][phase]["elapsed_ns"] for a, b in pairs)
             for phase in PHASES[:-1]} for r in range(2)]


def replay(folder):
    plan = tail.read(folder, "plan.json")
    require(plan["build_phases_diagnostic"] is True and plan["seed"] == SEED and plan["rounds"] == 4
            and plan["worker_scheduler"] == "hrtick-250us" and plan["worker_next_buddy"] is True
            and plan["network_topology"] == "per-job" and plan["build_scratch"] == "tmpfs"
            and plan["offered_rps"] == 64_000 and plan["dense_ms"] == 1500 and plan["build_nice"] == 0
            and "guest_fair" not in plan and not plan.get("job_parent")
            and re.fullmatch(r"[0-9a-f]{64}", plan["build_phases_probe_sha256"]), "unexpected phase diagnostic plan")
    scripts = variants((folder / "job.sh").read_text(), (folder / "go-dispatch.sh").read_text())
    require(all(terminal.digest(folder / name) == digest for name, digest in STOCK_SOURCES.items())
            and all((folder / name).read_text() == content for name, content in scripts.items())
            and plan["build_phases_sources"] == {name: terminal.digest(folder / name)
                                                 for name in (*scripts, SOURCE, DRIVER)}, "phase diagnostic sources changed")
    baseline, _, effective = tail.replay(folder)
    require(effective == 250_000 and tuple(row["order"] for row in baseline["windows"]) == ORDER,
            "wrong phase diagnostic boot slice or arm order")
    inventory = tail.read(folder, "grouped-inventory.json")
    require(all(sibling_job_parent.LABEL not in job["docker_inspect"]["Config"]["Labels"]
                for arm in "AB" for job in inventory[arm]["jobs"]), "build phases require flat CPU parents")
    boots = baseline["boots"]
    results = []
    for block, order in enumerate(ORDER):
        arms = {}
        for arm in order:
            jobs = inventory[arm]["jobs"][32:40]
            marks = checked_wave(folder, block, arm, jobs, boots[arm])
            timing = baseline["windows"][block]["engines"][arm]
            arms[arm] = {"last_finisher_slot": timing["last_finisher_slot"], "last_finisher_vcpu": timing["last_finisher_vcpu"],
                         "penultimate_finisher_slot": timing["penultimate_finisher_slot"], "slots": marks}
        results.append({"block": block, "order": order, "arms": arms})
    overhead = {}
    for arm in "AB":
        slots = [slot for block in results for slot in block["arms"][arm]["slots"]]
        probe_fraction = max(slot["marker_sample_ns"] / slot["elapsed_ns"] for slot in slots)
        calibrated_fraction = median((len(CALIBRATION) + 2 * len(PHASES)) * slot["marker_roundtrip_ns"]
                                     / slot["elapsed_ns"] for slot in slots)
        overhead[arm] = {"median_timed_handshake_ns": median(slot["marker_roundtrip_ns"] for slot in slots),
                         "max_timed_handshake_ns": max(slot["marker_roundtrip_ns"] for slot in slots),
                         "max_in_probe_fraction": probe_fraction, "median_calibrated_fraction": calibrated_fraction,
                         "within_one_percent_by_both_measures": max(probe_fraction, calibrated_fraction) <= .01}
    all_pairs, late_pairs = [], []
    for block in results:
        a, b = (block["arms"][arm]["slots"] for arm in "AB")
        require([(s["slot"], s["vcpu"]) for s in a] == [(s["slot"], s["vcpu"]) for s in b],
                "phase comparison requires identical measured slots and vCPUs")
        all_pairs.extend(zip(a, b, strict=True))
        for role in ("last_finisher_slot", "penultimate_finisher_slot"):
            i = block["arms"]["A"][role]
            late_pairs.append((a[i], b[i]))
    return {"archive": folder.name, "diagnostic_only": True, "boots": boots, "windows": results, "overhead": overhead,
            "paired_median_phase_gaps_ns": {"all_slots": phase_gaps(all_pairs), "native_last_two_slots": phase_gaps(late_pairs)},
            "measurement": "Phase intervals include the synchronous marker handshake. CPU and PSI totals cover the builder leaf, including its HTTP client and the marker. They measure CPU use and leaf-wide stalls rather than exact process wait causes."}


def run(args, *, archive_kind="sibling-build-phases", stage_probe=stage, collect_probe=collect):
    profile = sibling_job_parent.workload(args)
    require(all(path is None or path.exists() for path in (profile.product, profile.page_kernel_pair, profile.ipvlan_kernel,
                                                         profile.quiet_source, profile.image_archive)), "missing diagnostic inputs")
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-") + archive_kind + "-", dir=HERE))
    print(folder, flush=True)
    signal.signal(signal.SIGTERM, terminal.exit_on_signal)
    make, parallel, wave, build_stage = sibling_ci.Siblings.create, sibling_ci.parallel, sibling_ci.Siblings.run_wave, sibling_build.stage

    def prepare(output, runner, work, engine, archive, **kwargs):
        baseline = build_stage(output, runner, work, engine, archive, **kwargs)
        return {**baseline, **stage_probe(output, work, kwargs.get("env"))}

    def observe(cohort, output, block, indices, requests, dense_ms, offered_rps):
        scored = wave(cohort, output, block, indices, requests, dense_ms, offered_rps)
        if len(indices) > 1:
            collect_probe(cohort, output, f"grouped-{block}-all-{cohort.arm}")
            jobs = cohort.jobs[cohort.count:cohort.count + cohort.builders]
            prime = tail.read(output, "grouped-prime.json")[cohort.arm]
            boot = tail.check_revision(prime, "sib-prime", jobs[0]["name"])["boot"]
            checked_wave(output, block, cohort.arm, jobs, boot)
        return scored

    status = {"complete": False, "diagnostic_only": True}
    try:
        with terminal.terminal_lock(), patch.object(sibling_build, "stage", prepare), \
                patch.object(sibling_ci.Siblings, "run_wave", observe), patch.object(
                    sibling_ci.Siblings, "create", lambda c: sibling_job_parent.create_fixed(c, make, parallel, "flat")):
            sibling_ci.study(folder, profile)
        status["complete"] = True
        terminal.save(folder / "status.json", status)
        terminal.save(folder / "build-phases-summary.json", replay(folder))
    except BaseException as exc:
        status.update(complete=False, error=str(exc) or type(exc).__name__)
        raise
    finally:
        terminal.save(folder / "status.json", status)
    return folder


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    verbs = parser.add_subparsers(dest="action", required=True)
    live = verbs.add_parser("run")
    live.add_argument("--seed", choices=(SEED,), type=int, required=True)
    for name in ("product", "page-kernel-pair", "ipvlan-kernel", "quiet-source"):
        live.add_argument("--" + name, type=Path, required=True)
    live.add_argument("--image-archive", type=Path)
    offline = verbs.add_parser("replay")
    offline.add_argument("folder", type=Path)
    args = parser.parse_args()
    if args.action == "run":
        from sibling_worker_volume import mounted_worker_volume
        with mounted_worker_volume():
            run(args)
    else:
        print(json.dumps(replay(args.folder), indent=2))


if __name__ == "__main__":
    main()
