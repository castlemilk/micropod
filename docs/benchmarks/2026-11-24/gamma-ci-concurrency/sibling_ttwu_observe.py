"""Count native Linux queued cross-CPU callbacks during stock dense CI."""

import argparse
from collections import Counter
import gzip
import json
import os
from pathlib import Path
import re
import shutil
import time
from unittest.mock import patch

import sibling_ci
import sibling_file_fault_around_holdout as holdout
import sibling_tmpfs
from qualify import ROOT, require, terminal
from sibling_worker_volume import mounted_worker_volume


SEED, WINDOW = 250261, 65536
ARCHIVE = "sibling-ttwu-diagnostic"
WORK = "ttwu-trace"
SOURCE = "sibling_ttwu_observe_linux.go"
DRIVER = "sibling_ttwu_observe.py"
EVENT = "events/csd/csd_queue_cpu"
WHO = "sched_ttwu_pending"
CNTRL = "ipi_mb"
PHASES = ("control", *(f"dense-{k}" for k in range(4)))
OFF = {"tracing_on": "0", EVENT + "/enable": "0", "set_event": ""}
ON = {"tracing_on": "1", EVENT + "/enable": "1", "set_event": "csd:csd_queue_cpu"}
LINE = re.compile(r"\s*(.+)-(\d+)\s+\[(\d{3})\]\s+\S+\s+(\d+)\.(\d{6,9}):\s+([a-zA-Z_]+):\s+(.*)")
CALL = re.compile(r"cpu=([0-3]) callsite=\S+ func=([\w.$]+) csd=\S+", re.ASCII)
HEADER = re.compile(r"# entries-in-buffer/entries-written:\s*(\d+)/(\d+)\s+#P:4\s*")
LOSS = ("overrun", "commit overrun", "dropped events")
IMAGE = "488a83549377f9abcabfc44a9021f1451c9ed903f85f66f910e296c7ab2327ab"


def read(folder, name):
    return json.loads((folder / name).read_bytes())


def cpus(raw):
    mask = set()
    for chunk in raw.split(","):
        require(re.fullmatch(r"[0-3](?:-[0-3])?", chunk), f"bad guest CPU list {raw!r}")
        first, last = int(chunk[0]), int(chunk[-1])
        require(first <= last, f"bad guest CPU range {chunk}")
        mask.update(range(first, last + 1))
    return mask


def cache_groups(raw):
    require(raw["online"] == "0-3", "diagnostic needs four online guest vCPUs")
    last_cache = {}
    for cpu in range(4):
        prefix = f"cpu{cpu}/cache/"
        indices = sorted({k.rsplit("/", 1)[0] for k in raw if k.startswith(prefix)})
        candidates = [(int(raw[f"{index}/level"]), cpus(raw[f"{index}/shared_cpu_list"]))
                      for index in indices if raw[f"{index}/type"] in {"Data", "Unified"}]
        if not candidates:
            continue
        max_level = max(level for level, _ in candidates)
        domains = [mask for level, mask in candidates if level == max_level]
        require(max_level > 0 and len(domains) == 1 and cpu in domains[0], f"ambiguous guest cache sharing for CPU {cpu}")
        last_cache[cpu] = {"level": max_level, "shared_cpus": sorted(domains[0])}
    require(all(last_cache[member] == item for item in last_cache.values()
                for member in item["shared_cpus"] if member in last_cache), "guest cache-sharing masks disagree")
    missing = sorted(set(range(4)) - last_cache.keys())
    visibility = "complete" if not missing else "partial" if last_cache else "unavailable"
    return {"visibility": visibility, "per_cpu_highest_exported": last_cache, "missing_vcpus": missing}


def check_setup(setup, boot):
    mount = setup["mount"]
    trace = setup["trace"]
    pieces = setup["mountinfo"].split(" - ", 1)
    require(setup["boot"] == boot and re.fullmatch(r"/run/mp-ttwu-\d+", mount)
            and setup["root"] == mount + "/instances/" + Path(mount).name
            and len(pieces) == 2 and pieces[0].split()[4] == mount and pieces[1].split()[0] == "tracefs",
            "CSD trace did not use this boot's isolated tracefs mount")
    require(trace["trace_clock"].split().count("[mono]") == 1
            and 4080 <= int(trace["buffer_size_kb"]) <= 4120
            and trace["current_tracer"] == "nop" and trace["options/overwrite"] == "0"
            and int(trace["tracing_cpumask"].replace(",", ""), 16) == 15
            and trace["set_event"] == "" and trace[EVENT + "/filter"] == "none",
            "unexpected CSD ring configuration or preexisting filter")
    fmt = trace[EVENT + "/format"]
    require(fmt.startswith("name: csd_queue_cpu\n") and re.search(r"field:.*\bfunc;", fmt)
            and "cpu=%u callsite=%pS func=%ps csd=%p" in fmt,
            "CSD event did not provide native callback symbolization")
    addresses = []
    for name in (WHO, CNTRL):
        raw = setup["kallsyms"].get(name, "")
        require(re.fullmatch(rf"[a-f0-9]{{16}} [Tt] {name}", raw), f"trusted guest symbol missing for {name}")
        addresses.append(int(raw[:16], 16))
    require(addresses == [0, 0] or (all(addresses) and addresses[0] != addresses[1]),
            "CSD symbol addresses are mixed or ambiguous")
    return {"cache": cache_groups(setup["topology"]), "kallsyms_addresses_redacted": addresses == [0, 0]}


def entries(stats):
    require(set(stats) == {f"per_cpu/cpu{i}/stats" for i in range(4)}, "missing per-CPU trace data")
    counts = []
    for i in range(4):
        pairs = [line.split(":", 1) for line in stats[f"per_cpu/cpu{i}/stats"].splitlines() if ":" in line]
        raw = {k.strip(): v.strip() for k, v in pairs}
        require(len(pairs) == len(raw) and all(int(raw[k]) == 0 for k in LOSS),
                f"CPU {i} trace overrun or event loss")
        counts.append(int(raw["entries"]))
    return counts


def wall_offsets(receipt):
    first, second = (receipt[key] for key in ("start_clock", "end_clock"))
    lows, highs = [], []
    for start, unix, end in (first, second):
        require(type(start) is type(unix) is type(end) is int
                and 0 < start <= end < unix and end - start <= 500_000, "invalid guest clock bracket")
        lows.append(unix - end)
        highs.append(unix - start)
    require(first[2] <= second[0] and max(highs) - min(lows) <= 500_000, "guest trace clocks shifted")
    return min(lows), max(highs)


def parse_segment(folder, name):
    receipt = read(folder, f"ttwu-{name}.json")
    require(receipt["before"] == receipt["after"] == OFF and receipt["active"] == ON
            and entries(receipt["empty"]) == [0] * 4, f"{name} trace was not isolated and cleared")
    expected = entries(receipt["full"])
    lo, hi = wall_offsets(receipt)
    header, markers, rows = [], [], []
    actual, last_mono = [0] * 4, [0] * 4
    with gzip.open(folder / f"ttwu-{name}.ftrace.gz", "rt") as trace:
        for line in trace:
            if line.startswith("#") or not line.strip():
                match = HEADER.fullmatch(line)
                if match:
                    header.append(tuple(map(int, match.groups())))
                continue
            match = LINE.fullmatch(line.rstrip("\n"))
            require(match is not None, f"unrecognized {name} trace entry")
            comm, pid, source, sec, frac, kind, payload = match.groups()
            source = int(source)
            require(source in range(4), f"{name} trace CPU outside the guest allocation")
            actual[source] += 1
            mono = int(sec) * 10**9 + int(frac.ljust(9, "0"))
            require(mono >= last_mono[source], f"{name} CPU {source} monotonic trace clock reversed")
            last_mono[source] = mono
            rounding = 10**(9 - len(frac)) - 1
            bounds = mono + lo, mono + hi + rounding
            if kind == "tracing_mark_write":
                markers.append((payload, bounds, mono, mono + rounding))
            else:
                call = CALL.fullmatch(payload)
                require(kind == "csd_queue_cpu" and call, f"unexpected {name} event or unresolved callback")
                destination, callback = call.groups()
                destination = int(destination)
                require(not callback.startswith("0x") and (callback != WHO or destination != source),
                        f"{name} CSD callback symbol or TTWU destination is invalid")
                rows.append({"source": source, "destination": destination, "callback": callback,
                             "comm": comm, "trace_tid": int(pid), "wall_bounds": bounds})
    count = sum(expected)
    require(actual == expected and header == [(count, count)] and [m[0] for m in markers] ==
            [f"mp-ttwu-begin-{name}", f"mp-ttwu-end-{name}"], f"{name} trace entries or marker sequence differ")
    begin, end = (m[1] for m in markers)
    require(begin[1] < end[0] and receipt["start_clock"][2] <= markers[0][3]
            and markers[1][2] <= receipt["end_clock"][0], f"{name} markers disagree with guest trace clock brackets")
    return receipt, begin, end, rows


def histogram(rows, start=None, finish=None):
    certain, boundary = Counter(), Counter()
    for row in rows:
        low, high = row["wall_bounds"]
        if start is None or start <= low <= high < finish:
            certain[row["callback"]] += 1
        elif high >= start and low < finish:
            boundary[row["callback"]] += 1
    return {"ttwu": certain[WHO], "other": sum(certain.values()) - certain[WHO],
            "callbacks": dict(sorted(certain.items())), "boundary_uncertain": dict(sorted(boundary.items()))}


def control(folder):
    receipt, begin, end, rows = parse_segment(folder, "control")
    probe = receipt["control"]
    source, target = probe["source_cpu"], probe["target_cpu"]
    require((source, target) == (0, 3) and probe["membarriers"] == 8 and probe["source_comm"] == "mp-ttwu-waker"
            and probe["source_proc_tid"] > 0 and probe["target_proc_tid"] > 0
            and probe["source_proc_tid"] != probe["target_proc_tid"], "cross-CPU control threads were not pinned")
    witness = [row for row in rows if row["callback"] == CNTRL and row["comm"] == probe["source_comm"]
               and row["source"] == source and row["destination"] == target
               and begin[1] < row["wall_bounds"][0] <= row["wall_bounds"][1] < end[0]]
    require(0 < len(witness) <= probe["membarriers"] and len({row["trace_tid"] for row in witness}) == 1,
            "expedited membarrier did not verify a named remote CSD callback")
    return {"verified_remote_callbacks": len(witness), "waker_trace_tid": witness[0]["trace_tid"],
            "probe": probe, "whole_trace": histogram(rows)}


def dense(folder, block):
    receipt, begin, end, rows = parse_segment(folder, f"dense-{block}")
    require(receipt["control"] is None, "activity control overlapped the native workload")
    tag = f"grouped-{block}-all-A"
    builds = read(folder, tag + "-go.json")
    timing = read(folder, "windows.json")[f"grouped-{block}-all"]["A"]
    require(len(builds) == 8 and all(row["code"] == 0 for row in builds), f"{tag} lacks the eight stock builds")
    starts = [row["started_unix_ns"] for row in builds]
    finishes = [int(row["stdout"].splitlines()[-1].split()[1]) for row in builds]
    gate = max(starts) + 35_000_000
    nominal_end = gate + 1_500_000_000
    http_end = gate + timing["last_completion_offset_ns"]
    first, last = min(starts), max(finishes)
    require(all(a < b for a, b in zip(starts, finishes, strict=True))
            and timing["offered_rps"] == 64_000 and timing["offered_requests"] == timing["requests"] == 96_000
            and begin[1] < first <= gate < min(http_end, nominal_end)
            and max(http_end, nominal_end) < min(finishes) <= last < end[0],
            f"native stock build or offer interval was outside dense-{block} trace")
    observed_gate = folder / f"ttwu-dense-{block}-gate.txt"
    if observed_gate.is_file():
        require(observed_gate.read_text() == str(gate), f"{tag} stock release gate differs")
    return {"block": block, "total_trace": histogram(rows),
            "eight_builds": histogram(rows, first, last),
            "offer_interval": histogram(rows, gate, nominal_end),
            "until_last_response": histogram(rows, gate, http_end),
            "build_tail_after_http": histogram(rows, http_end, last),
            "guest_bounds": {"first_build_start_unix_ns": first, "gate_unix_ns": gate,
                             "http_end_unix_ns": http_end, "last_build_end_unix_ns": last}}


def report(folder):
    plan = read(folder, "plan.json")
    boot = holdout.parents.boots(folder)["A"]
    require(plan["ttwu_diagnostic"] is True and plan["seed"] == SEED
            and plan["file_fault_around_bytes"] == WINDOW and plan["offered_rps"] == 64_000
            and plan["builders"] == 8 and plan["rounds"] == 4
            and plan["pages"]["kernel_image_sha256"] == IMAGE
            and re.fullmatch(r"[a-f0-9]{64}", plan["ttwu_binary_sha256"])
            and all(plan["ttwu_sources"][name] == terminal.digest(folder / name) for name in (DRIVER, SOURCE)),
            "wrong TTWU diagnostic fixture, window or archive source")
    check_scheduler(folder)
    setup = read(folder, "ttwu-setup.json")
    preflight = check_setup(setup, boot)
    after = read(folder, "ttwu-retired.json")
    require((after["instance"], after["mount"], after["state"]) == (setup["root"], setup["mount"], OFF)
            and all(after[key] is True for key in ("instance_removed", "tracefs_unmounted", "mount_removed"))
            and after["topology"] == setup["topology"], "trace instance, mount or topology did not retire cleanly")
    return {"diagnostic_only": True, "boot": boot, "kernel_image_sha256": IMAGE,
            "guest_exported_data_cache": preflight["cache"],
            "kallsyms_addresses_redacted": preflight["kallsyms_addresses_redacted"],
            "positive_control": control(folder), "windows": [dense(folder, block) for block in range(4)]}


def wait(work, name, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if (work / name).is_file():
            return
        if (work / "error.json").is_file():
            raise ValueError(f"guest TTWU preflight or capture failed: {read(work, 'error.json')}")
        time.sleep(.025)
    raise ValueError(f"guest TTWU observer did not publish {name}")


def collect(work, folder, name, timeout=15):
    wait(work, name + ".json", timeout)
    shutil.copyfile(work / (name + ".json"), folder / f"ttwu-{name}.json")
    shutil.copyfile(work / (name + ".ftrace.gz"), folder / f"ttwu-{name}.ftrace.gz")


def check_scheduler(folder):
    saved = read(folder, "fair-scheduler.json")
    raw = {key: sorted((folder / "fair-scheduler" / key).read_text().split()) for key in ("before", "after")}
    require(raw["before"] == raw["after"] == saved["before"] == saved["after"]
            and {"TTWU_QUEUE", "HRTICK", "NEXT_BUDDY"} <= set(raw["after"])
            and saved["base_slice_ns"] == int((folder / "fair-scheduler/base-slice").read_text()) == 250_000,
            "native diagnostic lost packaged scheduling or the live TTWU feature")


def run(args):
    args.seed, args.fault_around_bytes = SEED, WINDOW
    state = {}
    with mounted_worker_volume():
        base_stage, base_qualify = sibling_tmpfs.stage, sibling_tmpfs.qualify
        base_wave, base_run = sibling_ci.Siblings.run_wave, terminal.Run

        def stage(oci, work, folder, mode):
            result = base_stage(oci, work, folder, mode)
            data = work / WORK
            data.mkdir(mode=0o700)
            state.update(folder=folder, work=data)
            for name in (DRIVER, SOURCE):
                shutil.copyfile(Path(__file__).with_name(name), folder / name)
            binary = work / "probe" / "ttwu-observer"
            env = {**os.environ, "GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0", "GOPROXY": "off"}
            terminal.invoke("go", "-C", ROOT / "guest/runner", "build", "-trimpath", "-buildvcs=false",
                            "-o", binary, folder / SOURCE, env=env, timeout=120)
            with (oci / "runner/fixture-facts.sh").open("a") as script:
                script.write('\n"$MICROPOD_ENGINE_WORKSPACE/probe/ttwu-observer" '
                             '"$MICROPOD_ENGINE_WORKSPACE/ttwu-trace" </dev/null '
                             '>"$MICROPOD_ENGINE_WORKSPACE/ttwu-trace/observer.log" 2>&1 &\n')
            return {**result, "ttwu_diagnostic": True, "ttwu_binary_sha256": terminal.digest(binary),
                    "ttwu_sources": {name: terminal.digest(folder / name) for name in (DRIVER, SOURCE)}}

        def qualify(folder, cohorts, mode, phase):
            base_qualify(folder, cohorts, mode, phase)
            work = state["work"]
            if phase == "before":
                wait(work, "setup.json")
                shutil.copyfile(work / "setup.json", folder / "ttwu-setup.json")
                require(read(folder, "plan.json")["pages"]["kernel_image_sha256"] == IMAGE,
                        "TTWU diagnostics require the pinned IPvlan Image")
                check_scheduler(folder)
                check_setup(read(folder, "ttwu-setup.json"), holdout.parents.boots(folder)["A"])
                (work / "control.start").touch(exist_ok=False)
                collect(work, folder, "control")
                control(folder)
            else:
                wait(work, "retired.json")
                shutil.copyfile(work / "retired.json", folder / "ttwu-retired.json")
                terminal.save(folder / "ttwu-summary.json", report(folder))

        def wave(cohort, folder, block, indices, requests, dense_ms, offered_rps):
            if cohort.arm != "A" or len(indices) == 1:
                return base_wave(cohort, folder, block, indices, requests, dense_ms, offered_rps)
            work, name = state["work"], f"dense-{block}"
            (work / (name + ".start")).touch(exist_ok=False)
            wait(work, name + "-armed.json")
            primary = None
            try:
                result = base_wave(cohort, folder, block, indices, requests, dense_ms, offered_rps)
                gate = cohort.work / "gate" / f"grouped-{block}-all-A"
                shutil.copyfile(gate, folder / f"ttwu-{name}-gate.txt")
                return result
            except BaseException as exc:
                primary = exc
                raise
            finally:
                try:
                    (work / (name + ".stop")).touch(exist_ok=False)
                    collect(work, folder, name, timeout=15 if primary is None else 3)
                except (ValueError, OSError) as exc:
                    if primary is None:
                        raise
                    primary.add_note(f"failed native wave's partial TTWU trace could not be copied: {exc}")

        def preserve():
            if not state or not state["work"].is_dir():
                return
            work, folder = state["work"], state["folder"]
            (work / "abort").touch()
            deadline = time.monotonic() + 3
            while not any((work / name).is_file() for name in ("retired.json", "error.json")) \
                    and time.monotonic() < deadline:
                time.sleep(.05)
            metadata = ("setup.json", "retired.json", "error.json", "observer.log")
            captures = [name for phase in PHASES if (work / f"{phase}.json").is_file()
                        for name in (f"{phase}.json", f"{phase}.ftrace.gz")]
            for name in (*metadata, *captures):
                artifact = work / name
                if artifact.is_file() and not (folder / f"ttwu-{name}").exists():
                    shutil.copyfile(artifact, folder / f"ttwu-{name}")

        def runner(*pos, **kw):
            instance = base_run(*pos, **kw)
            cleanup = instance.cleanup

            def cleanup_with_trace():
                try:
                    preserve()
                except OSError as exc:
                    terminal.save(instance.folder / "ttwu-preserve-error.json", {"error": str(exc)})
                finally:
                    cleanup()

            instance.cleanup = cleanup_with_trace
            return instance

        with patch.dict(holdout.SEED_ORDER, {SEED: (WINDOW,)}), patch.object(holdout, "PREFIX", ARCHIVE), \
                patch.object(sibling_tmpfs, "stage", stage), patch.object(sibling_tmpfs, "qualify", qualify), \
                patch.object(sibling_ci.Siblings, "run_wave", wave), patch.object(terminal, "Run", runner):
            holdout.run(args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    live = commands.add_parser("run")
    for name in ("product", "page-kernel-pair", "ipvlan-kernel", "quiet-source"):
        live.add_argument("--" + name, type=Path, required=True)
    live.add_argument("--image-archive", type=Path)
    replay = commands.add_parser("replay")
    replay.add_argument("folder", type=Path)
    args = parser.parse_args()
    if args.command == "run":
        del args.command
        run(args)
    else:
        require(read(args.folder, "status.json") == {"complete": True}, "TTWU diagnostic did not complete")
        print(json.dumps(report(args.folder), indent=2))


if __name__ == "__main__":
    main()
