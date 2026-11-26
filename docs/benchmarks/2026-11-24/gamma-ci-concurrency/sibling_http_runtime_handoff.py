"""Trace two actual warmed Go clients per engine in a separate diagnostic boot."""

import argparse
from bisect import bisect_left
from dataclasses import dataclass
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from unittest.mock import patch

from qualify import HERE, require, terminal
import sibling_ci
import sibling_http_client_boundaries as boundaries


PREFIX = "sibling-http-runtime-handoff"
SOURCE = Path(__file__).name
GUEST = "sibling_http_runtime_handoff_linux.go"
BASE_PROBE = boundaries.probe_source
SEED = 250285
SLOTS = {0: 0, 1: 9}
CAP = 8 << 20
CATEGORY = "micropod-http-handoff"
TRACE_FUZZ_NS = 2_000
TOOLS_SHA = "cce41bbb97e4cf81c9ccbbfaa5af6650488307da345a49191bd2b88b6614e7d4"
PHASES = ("headers", "body_eof", "body_socket")
DENSE = re.compile(r"grouped-([0-3])-all-([AB])")
HEADER = re.compile(r"M=(-?\d+) P=(-?\d+) G=(-?\d+) (\w+) Time=(\d+)(?: (.*))?")
STATE = re.compile(r'GoID=(\d+) (\w+)->(\w+) Reason="([^"]*)"')
SYNC = re.compile(r"N=(\d+) Trace=(\d+) Mono=(\d+) Wall=.+")
FRAME = re.compile(r"(.+) @ 0x[0-9a-f]+")
LOCATION = re.compile(r"(.+):(\d+)")


def probe_source(original, helper=None):
    source = BASE_PROBE(original)
    if helper is None:
        helper = (HERE / GUEST).read_bytes()
    marker = b"// Handoff source appended to the archived boundary client.\n"
    require(helper.count(marker) == 1, "unrecognized runtime trace helper source")
    edits = (
        (b'\t"context"\n', b'\t"context"\n\t"crypto/sha256"\n'),
        (b'\t"os/exec"\n\t"runtime"\n', b'\t"os/exec"\n\t"path/filepath"\n\t"runtime"\n\t"runtime/trace"\n'),
        (b"type paceClock struct {\n", b"type paceClock struct {\n\ttraceSampleNS, traceGoOffsetNS int64\n"),
        (b"\t\t\tlog.ClockCalibrationNS = span\n", b"""\t\t\tlog.ClockCalibrationNS = span
\t\t\tc.traceSampleNS = clock[0]*int64(time.Second) + clock[1]
\t\t\tc.traceGoOffsetNS = before.Sub(c.origin).Nanoseconds()
"""),
        (b"conn net.Conn, p pacing) {\n", b"conn net.Conn, p pacing, handoff *handoffTrace) {\n"),
        (b"\tfor i := range result.Requested {\n", b"""\tif handoff != nil {
\t\thandoff.evidence.Local, handoff.evidence.Remote, handoff.evidence.Marker = w.Local, w.Remote, result.Marker
\t\thandoff.evidence.GateNS = w.Scheduled
\t\thandoff.evidence.ClockSampleNS, handoff.evidence.ClockGoOffsetNS = clock.traceSampleNS, clock.traceGoOffsetNS
\t\thandoff.evidence.OriginUpperNS, handoff.evidence.ClockWidthNS = clock.kernelOrigin, result.Pace.ClockCalibrationNS
\t\tif err := handoff.anchor(ctx, clock.origin, "begin"); err != nil {
\t\t\tw.Error = err.Error()
\t\t\treturn
\t\t}
\t}
\tfor i := range result.Requested {
"""),
        (b'\tif ctx.Err() != nil && w.Error == "" {\n', b"""\tif handoff != nil {
\t\tif err := handoff.anchor(ctx, clock.origin, "end"); err != nil && w.Error == "" {
\t\t\tw.Error = err.Error()
\t\t}
\t}
\tif ctx.Err() != nil && w.Error == "" {
"""),
        (b"\twarmup, expected := request(ctx, client, endpoint, marker, nil)\n", b"""\thandoff, err := startHandoffTrace(gate.ready, gate.pace.rate, gate.pace.slot)
\tif err != nil {
\t\tresult.Warmup.Error = err.Error()
\t\treturn result
\t}
\tdefer handoff.stop()
\twarmup, expected := request(ctx, client, endpoint, marker, nil)
"""),
        (b"measurePaced(ctx, &result, client, expected, gate.pace)\n",
         b"measurePaced(ctx, &result, client, expected, gate.pace, handoff)\n"),
        (b"\t\t\treturn result\n\t\t}\n\t\tif err := w.await", b"""\t\t\tif handoff != nil {
\t\t\t\tif err := handoff.save(ctx); err != nil && w.Error == "" {
\t\t\t\t\tw.Error, result.Complete = err.Error(), false
\t\t\t\t}
\t\t\t}
\t\t\treturn result
\t\t}
\t\tif err := w.await"""),
    )
    for before, after in edits:
        require(source.count(before) == 1, "unexpected boundary client source marker")
        source = source.replace(before, after, 1)
    return source + b"\n" + helper.split(marker, 1)[1]


def tag_for(block, arm):
    return f"grouped-{block}-all-{arm}.{SLOTS[block]}"


def trace_path(folder, tag, ext):
    return folder / f"{tag}.runtime.{ext}"


def read(path):
    return json.loads(path.read_bytes())


def trace_receipt(folder, tag):
    record = read(trace_path(folder, tag, "json"))
    path = trace_path(folder, tag, "trace")
    require(record["tag"] == tag and record["overflow"] is False and
            0 < record["bytes"] == record["seen_bytes"] == path.stat().st_size <= CAP and
            record["sha256"] == terminal.digest(path), "missing, unbounded or truncated Go execution trace")
    return record


def run(args):
    base_stage, base_wave = boundaries.holdout.stage, sibling_ci.Siblings.run_wave

    def stage(oci, work, folder, selected):
        fields = base_stage(oci, work, folder, selected)
        shutil.copyfile(Path(__file__), folder / SOURCE)
        shutil.copyfile(HERE / GUEST, folder / GUEST)
        return {**fields, "http_runtime_handoff": True, "http_runtime_handoff_slots": {str(k): v for k, v in SLOTS.items()},
                "http_runtime_handoff_sources": {name: terminal.digest(folder / name) for name in (SOURCE, GUEST)}}

    def wave(cohort, folder, block, indices, requests, dense_ms, offered_rps=None):
        selected = block in SLOTS and len(indices) == 32
        tag = tag_for(block, cohort.arm) if selected else None
        try:
            result = base_wave(cohort, folder, block, indices, requests, dense_ms, offered_rps)
        finally:
            if selected:
                for ext in ("trace", "json"):
                    src = trace_path(cohort.work / "gate", tag, ext)
                    if src.is_file():
                        shutil.copyfile(src, trace_path(folder, tag, ext))
        if selected:
            trace_receipt(folder, tag)
        return result

    with patch.object(boundaries, "PREFIX", PREFIX), patch.object(boundaries, "probe_source", probe_source), \
            patch.object(boundaries.holdout, "stage", stage), patch.object(sibling_ci.Siblings, "run_wave", wave):
        boundaries.run(args)


@dataclass
class Event:
    thread: int
    emitter: int
    time: int
    kind: str
    body: str
    stack: list
    transition_stack: list


def parsed_events(lines):
    event, stack = None, None
    previous = -1
    for line in lines:
        line = line.rstrip("\n")
        match = HEADER.fullmatch(line)
        if match:
            if event is not None:
                yield event
            thread, _, emitter, kind, ns, body = match.groups()
            require(int(ns) > previous, "Go trace times were not strictly ordered")
            previous = int(ns)
            event = Event(int(thread), int(emitter), previous, kind, body or "", [], [])
            stack = None
        elif line == "Stack=" or line == "TransitionStack=":
            require(event is not None, "Go trace stack has no event")
            stack = event.stack if line == "Stack=" else event.transition_stack
        elif line.startswith("\t"):
            require(stack is not None, "unexpected Go trace stack frame")
            stack.append(line.strip())
        else:
            require(not line, "unexpected text from pinned Go trace decoder")
    if event is not None:
        yield event


def decode(path, go):
    with tempfile.TemporaryFile(mode="w+t") as output:
        result = subprocess.run([go, "tool", "trace", "-d=parsed", path], stdout=output,
                                stderr=subprocess.PIPE, text=True, timeout=60)
        require(result.returncode == 0 and 0 < output.tell() <= 192 << 20,
                "pinned Go tool could not decode full trace: " + result.stderr[-500:])
        output.seek(0)
        return [event for event in parsed_events(output) if event.kind in ("Log", "StateTransition", "Sync")]


def intersect(first, second):
    lo, hi = max(first[0], second[0]), min(first[1], second[1])
    require(lo <= hi, "runtime and paced Linux monotonic clocks disagree")
    return lo, hi


def bind_clock(record, receipt, events, boot):
    require(record["boot_id"] == boot and record["go_version"] == "go1.27.2" and
            re.fullmatch(r"pid:\[\d+\]", record["pid_namespace"]), "unexpected traced client boot, Go or namespace")
    window, pace = receipt["window"], receipt["pace"]
    require((record["local"], record["remote"], record["marker"], record["gate_unix_ns"]) ==
            (window["local"], window["remote"], receipt["marker"], window["scheduled_unix_ns"]) and
            record["clock_width_ns"] == pace["clock_calibration_ns"], "trace differs from the verified paced socket and gate")
    width, hi = record["clock_width_ns"], record["origin_upper_ns"]
    require(type(width) is int and 0 < width <= 10_000 and type(hi) is int and hi > width and
            hi == record["clock_sample_ns"] - record["clock_go_offset_ns"], "imprecise or inconsistent origin calibration")
    gate = (hi - width, hi)
    clocks = [SYNC.fullmatch(event.body) for event in events if event.kind == "Sync"]
    samples = [(int(match[2]), int(match[3])) for match in clocks if match]
    require(samples and all(0 <= ts - mono <= 1_000_000 or 0 <= mono - ts <= TRACE_FUZZ_NS
                            for ts, mono in samples), "Go sync snapshots disagree with Linux monotonic time")
    marks = {}
    for phase in ("begin", "end", "control-begin", "control-end"):
        pattern = f'Category="{CATEGORY}" Message="{record["tag"]}:{phase}"'
        hits = [event for event in events if event.kind == "Log" and event.body.endswith(pattern)]
        require(len(hits) == 1, "missing or repeated owned runtime trace marker " + phase)
        marks[phase] = hits[0]
    begin, end = marks["begin"], marks["end"]
    require(begin.emitter == end.emitter == marks["control-begin"].emitter == marks["control-end"].emitter > 0 and
            begin.thread == end.thread > 0 and begin.time < end.time < marks["control-begin"].time < marks["control-end"].time,
            "runtime trace markers changed issuer or order")
    tid = begin.thread
    status = dict(line.split(":", 1) for line in record["thread_status"].splitlines() if ":" in line)
    require(int(status["Pid"]) == tid == int(status["NSpid"].split()[-1]) and
            int(status["Tgid"]) == int(status["NStgid"].split()[-1]) == record["pid"] > 0 and
            (not window.get("pid") or window["pid"] == record["pid"]), "raw Linux status differs from the issuing thread")
    require([anchor["phase"] for anchor in record["anchors"]] == ["begin", "end"], "missing begin/end clock brackets")
    for anchor, event in zip(record["anchors"], (begin, end), strict=True):
        k0, k1 = (anchor[key] for key in ("kernel_before_ns", "kernel_after_ns"))
        g0, g1 = (anchor[key] for key in ("go_before_ns", "go_after_ns"))
        require(anchor["tid"] == tid and all(type(v) is int for v in (k0, k1, g0, g1)) and
                0 < k0 <= k1 and g0 <= g1, "invalid clock marker or issuer")
        stamp = intersect((k0, k1), (event.time - TRACE_FUZZ_NS, event.time + TRACE_FUZZ_NS))
        gate = intersect(gate, (stamp[0] - g1, stamp[1] - g0))
    first, last = pace["arrivals"][0], pace["arrivals"][-1]
    require(record["anchors"][0]["go_after_ns"] <= first["dispatch_offset_ns"] and
            last["completion_offset_ns"] <= record["anchors"][1]["go_before_ns"], "trace does not enclose every actual arrival")
    return gate, marks, status["Cpus_allowed_list"].strip()


def cycles(events, issuer):
    parked = ready = None
    for event in events:
        state = STATE.fullmatch(event.body) if event.kind == "StateTransition" else None
        if state is None or int(state[1]) != issuer or state[2] == state[3]:
            continue
        edge = (state[2], state[3])
        if edge == ("Running", "Waiting"):
            parked, ready = (event, state[4]), None
        elif edge == ("Waiting", "Runnable") and parked:
            ready = event
        elif edge == ("Runnable", "Running") and parked and ready:
            yield parked[0], parked[1], ready, event
            parked = ready = None
        else:
            parked = ready = None


def frame_at(stack, function, first, last):
    for line, path in zip(stack, stack[1:]):
        frame, source = FRAME.fullmatch(line), LOCATION.fullmatch(path)
        if frame and source and frame[1].startswith(function) and source[1].endswith("net/http/transport.go") and \
                first <= int(source[2]) <= last:
            return True
    return False


def classify(park, reason, wake):
    stack = park.transition_stack or park.stack
    with_body = any("net/http.(*bodyEOFSignal).Read " in frame for frame in stack)
    if reason == "select" and frame_at(stack, "net/http.(*persistConn).roundTrip", 3090, 3128) and \
            frame_at(wake.stack, "net/http.(*persistConn).readLoop", 2606, 2611):
        return "headers"
    if reason == "chan receive" and with_body and frame_at(stack, "net/http.(*persistConn).readLoop.func", 2585, 2589) and \
            frame_at(wake.stack, "net/http.(*persistConn).readLoop", 2625, 2628):
        return "body_eof"
    if reason == "network" and with_body:
        return "body_socket"
    return None


def overlap(bounds, start, end, gate):
    """Bound one traced interval's intersection with a monotonic application phase."""
    lo, hi = gate
    early_start, late_start = start - TRACE_FUZZ_NS, start + TRACE_FUZZ_NS
    early_end, late_end = end - TRACE_FUZZ_NS, end + TRACE_FUZZ_NS
    phase_start, phase_end = bounds
    return [max(0, min(early_end, phase_end + lo) - max(late_start, phase_start + hi)),
            min(phase_end - phase_start, max(0, min(late_end, phase_end + hi) - max(early_start, phase_start + lo)))]


def phase_fields(phase):
    return ("first_response_byte_ns", "do_return_ns") if phase == "headers" else ("do_return_ns", "readall_return_ns")


def coverage(phase, table, band, samples):
    first, last = phase_fields(phase)
    totals = {i: samples[i][last] - samples[i][first] for i in band}

    def sums(category):
        return [sum(min(totals[i], sum(row[category][bound] for row in table.get(i, []))) for i in band)
                for bound in (0, 1)]

    return {"requests": len(table), "cycles": sum(map(len, table.values())),
            "p95_band_requests": sum(i in table for i in band), "p95_band": len(band),
            "p95_band_phase_ns": sum(totals.values()), "p95_band_blocked_ns_bounds": sums(0),
            "p95_band_runnable_ns_bounds": sums(1)}


def diagnose(path, record, receipt, boot, affinity, go):
    events = decode(path, go)
    gate, marks, mask = bind_clock(record, receipt, events, boot)
    begin, end = marks["begin"], marks["end"]
    issuer = begin.emitter
    require(mask == affinity, "runtime trace issuing thread has a different vCPU affinity")
    waits = list(cycles(events, issuer))
    require(any(marks["control-begin"].time < park.time < wake.time < running.time < marks["control-end"].time
                and reason == "chan receive" and wake.emitter != issuer and
                any(line.startswith("main.handoffControlWake ") for line in wake.stack)
                for park, reason, wake, running in waits), "Go trace did not observe the explicit channel control")
    samples, arrivals = receipt["samples"], receipt["pace"]["arrivals"]
    completions = [row["completion_offset_ns"] for row in arrivals]
    mapped = {phase: {} for phase in PHASES}
    unresolved = 0
    for park, reason, wake, running in waits:
        if not (begin.time <= park.time < wake.time < running.time <= end.time):
            continue
        phase = classify(park, reason, wake)
        if phase is None:
            unresolved += 1
            continue
        midpoint = wake.time - sum(gate) // 2
        index = bisect_left(completions, midpoint)
        if index == len(samples):
            unresolved += 1
            continue
        start = arrivals[index]["dispatch_offset_ns"]
        sample = samples[index]
        first, last = phase_fields(phase)
        bounds = (start + sample[first], start + sample[last])
        if wake.time - TRACE_FUZZ_NS < bounds[0] + gate[1] or running.time + TRACE_FUZZ_NS > bounds[1] + gate[0]:
            unresolved += 1
            continue
        require(running.thread == begin.thread, "traced issuing goroutine changed locked OS thread")
        record_pair = (overlap(bounds, park.time, wake.time, gate), overlap(bounds, wake.time, running.time, gate))
        mapped[phase].setdefault(index, []).append(record_pair)
    rank = sorted(range(len(samples)), key=lambda i: (samples[i]["total_ns"], i))
    band = rank[(94 * len(rank)) // 100:(96 * len(rank)) // 100]
    return {"issuer_go_id": issuer, "issuer_tid": begin.thread, "origin_bounds_ns": gate, "event_fuzz_ns": TRACE_FUZZ_NS,
            "positive_control": True, "calls": len(rank), "unresolved_cycles": unresolved,
            "coverage": {name: coverage(name, table, band, samples) for name, table in mapped.items()}}


def replay(folder):
    plan = read(folder / "plan.json")
    require(plan["http_runtime_handoff"] is True and plan["http_runtime_handoff_slots"] == {str(k): v for k, v in SLOTS.items()}
            and plan["http_runtime_handoff_sources"] == {name: terminal.digest(folder / name) for name in (SOURCE, GUEST)}
            and (folder / SOURCE).read_bytes() == Path(__file__).read_bytes(), "runtime trace sources or selected clients changed")
    helper = (folder / GUEST).read_bytes()
    manifest = HERE / boundaries.polling.products.MANIFEST
    require(terminal.digest(manifest) == TOOLS_SHA, "runtime trace decoder manifest changed")
    tools = read(manifest)["toolchain"]
    go = Path(tools["path"])
    require(plan["http_client_boundary_toolchain"] == tools and terminal.digest(go) == tools["sha256"],
            "runtime trace decoder toolchain changed")
    base_read = boundaries.response_phases.TraceCollector.read_wire
    traces, controls = {}, {}

    def capture(collector, path, tag):
        rows = base_read(collector, path, tag)
        match = DENSE.fullmatch(tag)
        if match:
            block, arm = int(match[1]), match[2]
            for slot in SLOTS.values():
                receipt = rows[slot]["receipt"]
                if block in SLOTS and slot == SLOTS[block]:
                    traces[tag_for(block, arm)] = receipt
                samples = sorted(sample["total_ns"] for sample in receipt["samples"])
                controls[f"{tag}.{slot}"] = {"traced": SLOTS.get(block) == slot,
                                            "post_dispatch_p95_ns": samples[(95 * len(samples) + 99) // 100 - 1]}
        return rows

    with patch.object(boundaries, "probe_source", lambda source: probe_source(source, helper)), \
            patch.object(boundaries.response_phases.TraceCollector, "read_wire", capture):
        workload = boundaries.replay(folder)
    wanted = {tag_for(block, arm) for block in SLOTS for arm in "AB"}
    require(set(traces) == wanted and {p.name for p in folder.glob("*.runtime.*")} == {
        trace_path(folder, tag, ext).name for tag in wanted for ext in ("trace", "json")}, "missing or unexpected trace streams")
    inventories = read(folder / "grouped-inventory.json")
    diagnostics = {}
    for tag in sorted(wanted):
        wave, text_slot = tag.rsplit(".", 1)
        arm, slot = wave[-1], int(text_slot)
        record = trace_receipt(folder, tag)
        receipt = traces[tag]
        require(slot == receipt["pace"]["slot"], "runtime trace selected the wrong paced offer stream")
        job = inventories[arm]["jobs"][32 + slot]
        diagnostics[tag] = {"client_id": job["id"], "trace_sha256": record["sha256"], "raw_bytes": record["bytes"],
                            **diagnose(trace_path(folder, tag, "trace"), record, receipt, workload["boot_ids"][arm], job["mask"], go)}
    return {"diagnostic_only": True, "archive": folder.name, "worker": workload["worker"],
            "boot_ids": workload["boot_ids"], "completed_offers": workload["completed_offers"],
            "stock_build_jobs": workload["stock_build_jobs"], "traces": diagnostics,
            "selected_clients_with_and_without_tracing": controls,
            "boundary_aggregate": workload["aggregate"], "raw_http_sha256": workload["raw_http_sha256"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    live = commands.add_parser("run")
    live.add_argument("--worker", choices=boundaries.PRODUCTS, default="log-notify")
    live.add_argument("--seed", type=int, default=SEED)
    live.add_argument("--quiet-source", type=Path, default=boundaries.DEFAULT_SOURCE)
    live.add_argument("--image-archive", type=Path, default=boundaries.ARCHIVE)
    live.add_argument("--page-kernel-pair", type=Path, default=boundaries.kernel.STOCK_KERNEL)
    live.add_argument("--ipvlan-kernel", type=Path, default=boundaries.kernel.IPVLAN_KERNEL)
    offline = commands.add_parser("replay")
    offline.add_argument("folder", type=Path)
    args = parser.parse_args()
    if args.command == "run":
        run(args)
    else:
        print(json.dumps(replay(args.folder.resolve()), indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
