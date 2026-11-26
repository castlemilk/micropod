"""Stage and replay an isolated scheduler trace of one or two paced CI clients."""

import argparse
import gzip
import hashlib
import json
import re
import shutil
from collections import Counter
from pathlib import Path

from qualify import ROOT, require, terminal
import sibling_client_slice
import sibling_paced
import sibling_sched
import sibling_trace


TAG = "grouped-0-all-A"
WORK = "dispatch-trace"
SOURCE = "sibling_dispatch_trace_linux.go"
DRIVER = "sibling_dispatch_trace.py"
BASE = ROOT / ".build/sibling-fixture-freezes/native-client-slice/ea18c03353d0"
SLICES = {"hrtick": 2_100_000, "hrtick-125us": 125_000}
RATE = 64_000


def issuing_name(owner, slot):
    return f"mpd{hashlib.blake2s(owner.encode(), digest_size=4).hexdigest()}{slot:02d}"


def replace_once(source, before, after):
    require(source.count(before) == 1, "pinned dispatch trace source marker differs")
    return source.replace(before, after, 1)


def probe_source(original):
    require(hashlib.sha256(original).hexdigest() == sibling_client_slice.PROBE_SHA256,
            "dispatch trace requires the frozen paced HTTP source")
    source = sibling_client_slice.rewrite_probe(original)
    fields = b'''\tTraceIssuer *traceIssuer `json:"trace_issuer,omitempty"`
\tClockSampleNS int64 `json:"clock_sample_ns,omitempty"`
\tOriginFromBracketStartNS int64 `json:"origin_from_bracket_start_ns,omitempty"`
\tKernelOriginUpperNS int64 `json:"kernel_origin_upper_ns,omitempty"`
'''
    sidecar = b'''\t\t\tif gate.dispatchTrace != "" {
\t\t\t\tns, err := os.Readlink("/proc/self/ns/pid")
\t\t\t\tif err != nil || result.Pace.IssuingTID <= 0 {
\t\t\t\t\tw.Error = fmt.Sprintf("dispatch issuer namespace: %v", err)
\t\t\t\t\treturn result
\t\t\t\t}
\t\t\t\tif err := nameTraceIssuer(gate.dispatchTrace); err != nil {
\t\t\t\t\tw.Error = fmt.Sprintf("name dispatch issuer: %v", err)
\t\t\t\t\treturn result
\t\t\t\t}
\t\t\t\tresult.Pace.TraceIssuer = &traceIssuer{PID: os.Getpid(), TID: result.Pace.IssuingTID, PIDNS: ns, Comm: gate.dispatchTrace}
\t\t\t\tdata, err := json.Marshal(result.Pace.TraceIssuer)
\t\t\t\tif err == nil {
\t\t\t\t\terr = os.WriteFile(gate.ready+".issuer", data, 0600)
\t\t\t\t}
\t\t\t\tif err != nil {
\t\t\t\t\tw.Error = fmt.Sprintf("publish dispatch issuer: %v", err)
\t\t\t\t\treturn result
\t\t\t\t}
\t\t\t}
'''
    kernel = b'\t\t\tc.kernelOrigin = clock[0]*int64(time.Second) + clock[1] + c.origin.Sub(before).Nanoseconds()\n'
    compiled_clock = kernel + b'''\t\t\tif log.TraceIssuer != nil {
\t\t\t\tlog.ClockSampleNS = clock[0]*int64(time.Second) + clock[1]
\t\t\t\tlog.OriginFromBracketStartNS = c.origin.Sub(before).Nanoseconds()
\t\t\t\tlog.KernelOriginUpperNS = c.kernelOrigin
\t\t\t}
'''
    for before, after in (
        (b"type schedule struct {\n", b"type schedule struct {\n\tdispatchTrace string\n"),
        (b"type paceLog struct {\n", b'''type traceIssuer struct {
\tPID int `json:"pid"`
\tTID int `json:"tid"`
\tPIDNS string `json:"pidns"`
\tComm string `json:"comm"`
}

func nameTraceIssuer(comm string) error {
\tvar prctl uintptr
\tswitch runtime.GOARCH {
\tcase "arm64":
\t\tprctl = 167
\tcase "amd64":
\t\tprctl = 157
\tdefault:
\t\treturn fmt.Errorf("unsupported dispatch observer architecture %s", runtime.GOARCH)
\t}
\tif runtime.GOOS != "linux" || len(comm) != 13 || !strings.HasPrefix(comm, "mpd") {
\t\treturn fmt.Errorf("invalid Linux issuing thread name %q", comm)
\t}
\tvar name [16]byte
\tcopy(name[:], comm)
\tconst prSetName = 15
\t_, _, errno := syscall.Syscall6(prctl, prSetName, uintptr(unsafe.Pointer(&name[0])), 0, 0, 0, 0)
\tif errno != 0 {
\t\treturn errno
\t}
\treturn nil
}

type paceLog struct {
''' + fields),
        (kernel, compiled_clock),
        (b"\t\t\tif err := w.readGate(ctx, gate.ready, gate.start); err != nil {\n",
         sidecar + b"\t\t\tif err := w.readGate(ctx, gate.ready, gate.start); err != nil {\n"),
        (b'\tflag.Parse()\n', b'\tdispatchTrace := flag.String("dispatch-trace", "", "trace name for the locked issuing thread")\n\tflag.Parse()\n'),
        (b"\t\tready: *ready, start: *start, threadProbe:", b"\t\tdispatchTrace: *dispatchTrace, ready: *ready, start: *start, threadProbe:"),
    ):
        source = replace_once(source, before, after)
    return source


def stage(oci, work, folder, env, source, target, slots):
    original = source.read_bytes()
    target.write_bytes(probe_source(original))
    (folder / "quiet-http-base.go").write_bytes(original)
    here = Path(__file__).parent
    for name in (DRIVER, SOURCE):
        shutil.copyfile(here / name, folder / name)
    binary = work / "probe/sibling-dispatch-trace"
    terminal.invoke("go", "build", "-trimpath", "-buildvcs=false", "-o", binary, here / SOURCE, env=env)
    (work / WORK).mkdir(mode=0o700)
    with (oci / "runner/fixture-facts.sh").open("a") as hook:
        hook.write('''
dispatch_trace="$MICROPOD_ENGINE_WORKSPACE/dispatch-trace"
"$MICROPOD_ENGINE_WORKSPACE/probe/sibling-dispatch-trace" -dir "$dispatch_trace" >"$dispatch_trace/helper.log" 2>&1 </dev/null &
''')
    return {"dispatch_trace_slots": slots, "dispatch_trace_driver_sha256": terminal.digest(folder / DRIVER),
            "dispatch_trace_guest_source_sha256": terminal.digest(folder / SOURCE),
            "dispatch_trace_guest_sha256": terminal.digest(binary)}


def start(work, folder, tag, slots, jobs, owner):
    require(tag == TAG, "dispatch trace can only arm on the first native paced wave")
    directory = work / WORK
    sibling_trace.wait(directory, "ready", 3)
    targets = []
    for slot in slots:
        identity = json.loads((work / "gate" / f"{tag}.{slot}.issuer").read_bytes())
        require(set(identity) == {"pid", "tid", "pidns", "comm"} and identity["comm"] == issuing_name(owner, slot) and
                all(type(identity[k]) is int and identity[k] > 0 for k in ("pid", "tid")) and
                re.fullmatch(r"pid:\[[0-9]+\]", identity["pidns"]), f"bad issuing identity for slot {slot}")
        targets.append({**identity, "slot": slot, "mask": jobs[32 + slot]["mask"]})
    terminal.save(folder / "dispatch-trace-targets.json", targets)
    temporary = directory / "command.tmp"
    terminal.save(temporary, targets)
    temporary.replace(directory / "command")
    require(len(sibling_trace.wait(directory, "armed", 7)) == len(targets), "wrong issuing thread count")


def stop(work, folder):
    (work / WORK / "stop").touch(exist_ok=True)
    receipt = sibling_trace.wait(work / WORK, "done", 10)
    terminal.save(folder / "dispatch-trace-kernel.json", receipt)
    shutil.copyfile(work / WORK / "trace.gz", folder / "dispatch-trace.ftrace.gz")
    require(sibling_trace.check_stats(receipt["stats"]) > 2, "trace captured only markers; archived event enable and PID domains")


def cancel(work):
    (work / WORK / "stop").touch(exist_ok=True)


def diagnostic_driver(original):
    source = original.decode()
    edits = (
        ("import sibling_counters\n", "import sibling_counters\nimport sibling_dispatch_trace as dispatch_trace\n"),
        ("def run_wave(self, folder, block, indices, requests, dense_ms, offered_rps=None):",
         "def run_wave(self, folder, block, indices, requests, dense_ms, offered_rps=None, trace_slots=()):"),
        ("        tag = f\"{self.layout}-{block}-{mode}-{self.arm}\"\n",
         "        tag = f\"{self.layout}-{block}-{mode}-{self.arm}\"\n"
         "        traced = tag == dispatch_trace.TAG and rate and trace_slots\n"),
        ("                                     *sibling_paced.client_args(rate, index),\n",
         "                                     *sibling_paced.client_args(rate, index),\n"
         "                                     *(['-dispatch-trace', dispatch_trace.issuing_name(self.owner, index)]\n"
         "                                       if traced and index in trace_slots else []),\n"),
        ("                start = max(int(p.read_text()) for p in ready) + 600_000_000\n",
         "                start = max(int(p.read_text()) for p in ready) + 600_000_000\n"
         "                if traced:\n"
         "                    stack.callback(dispatch_trace.cancel, self.work)\n"
         "                    dispatch_trace.start(self.work, folder, tag, trace_slots, self.jobs, self.owner)\n"),
        ("                    if self.builders:\n                        build_rows = builders.finish()\n",
         "                    if traced:\n"
         "                        require(all(p.is_file() and p.stat().st_size for p in done), 'paced trace wave did not finish')\n"
         "                        dispatch_trace.stop(self.work, folder)\n"
         "                    if self.builders:\n                        build_rows = builders.finish()\n"),
        ("        if native_client_slice:\n            extra.update(sibling_client_slice.stage(quiet_source, source, folder))\n        else:\n            shutil.copyfile(quiet_source, source)\n",
         "        extra.update(dispatch_trace.stage(oci, work, folder, env, quiet_source, source, args.dispatch_trace_slots))\n"),
        ("cohorts[a].run_wave(folder, block, indices, args.requests, args.dense_ms, args.offered_rps)",
         "cohorts[a].run_wave(folder, block, indices, args.requests, args.dense_ms, args.offered_rps, args.dispatch_trace_slots)"),
        ('terminal.save(folder / "windows.json", summary)',
         'terminal.save(folder / "dispatch-trace-workload.json", {\n'
         '                            name: {"order": wave["order"], **{engine: {\n'
         '                                "requests": wave[engine]["requests"], "builds": wave[engine].get("build", {}).get("jobs", 0)\n'
         '                            } for engine in "AB"}} for name, wave in summary.items()\n'
         '                        })'),
        ("    args = parser.parse_args()\n",
         "    parser.add_argument('--dispatch-trace-slots', nargs='+', required=True, type=int)\n"
         "    args = parser.parse_args()\n"
         "    dispatch_trace.check_args(args)\n"),
        ("%Y%m%dT%H%M%SZ-sibling-", "%Y%m%dT%H%M%SZ-dispatch-trace-"),
    )
    for before, after in edits:
        source = replace_once(source, before, after)
    return source.encode()


def check_args(args):
    slots = args.dispatch_trace_slots
    require(1 <= len(slots) <= 2 and slots == sorted(set(slots)) and all(0 <= slot < 32 for slot in slots),
            "trace one or two distinct slot indices in ascending order")
    require(args.cpu_groups and args.layouts in (None, ["grouped"]) and args.pairs == 32 and args.rounds == 1
            and args.builders == 8 and args.build_nice == 0 and args.build_policy == "normal"
            and args.offered_rps == RATE and args.dense_ms == 1500 and args.ipvlan_kernel and args.page_kib == 16
            and args.network_driver == "ipvlan" and args.worker_next_buddy and args.worker_scheduler in SLICES
            and args.guest_fair in (None, "inherit") and all(v is None for v in (
                args.slice_us, args.build_slice_us, args.builder_shares, args.buddy_kernel, args.mthp_kernel,
                args.network_topology, args.ipam_route_product)) and not any((
                    args.trace_sockets, args.timer_counters, args.job_network_smoke)),
            "dispatch trace needs one full grouped ordinary 64k wave on the matched inherited-slice IPvlan profiles")


def freeze():
    inputs = {}
    for line in (BASE / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split("  ", 1)
        require(Path(name).name == name, "unexpected pinned driver member")
        inputs[name] = (BASE / name).read_bytes()
        require(hashlib.sha256(inputs[name]).hexdigest() == digest, f"pinned driver changed: {name}")
    inputs["sibling_ci.py"] = diagnostic_driver(inputs["sibling_ci.py"])
    for name in (DRIVER, SOURCE):
        inputs[name] = Path(__file__).with_name(name).read_bytes()
    manifest = "".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in sorted(inputs.items()))
    folder = BASE.parent.parent / "paced-dispatch-trace" / hashlib.sha256(manifest.encode()).hexdigest()[:12]
    folder.mkdir(parents=True, exist_ok=True)
    for name, data in {**inputs, "SHA256SUMS": manifest.encode()}.items():
        file = folder / name
        if file.is_file():
            require(file.read_bytes() == data, "existing diagnostic snapshot differs")
        else:
            with file.open("xb") as f:
                f.write(data)
            file.chmod(0o444)
    return folder


LINE = re.compile(r"^\s*(.+?)-(\d+)\s+\[(\d+)\].*?\s+(\d+)\.(\d{6,9}):\s+(.+)$")
SWITCH = re.compile(r"\bprev_comm=(.*?) prev_pid=(\d+).*?\bprev_state=(\S+).*?\bnext_comm=(.*?) next_pid=(\d+)\b")
WAKE = re.compile(r"\bcomm=(.*?) pid=(\d+).*?\btarget_cpu=(\d+)\b")
ENTER = re.compile(r"^(?:sys_enter_clock_nanosleep:\s*)?(?:sys_)?clock_nanosleep\((.*)\)$")
EXIT = re.compile(r"^(?:sys_exit_clock_nanosleep:\s*)?(?:sys_)?clock_nanosleep -> (?:0x[0-9a-f]+|-?\d+)$")
STATES = ("on_cpu", "runnable", "sleeping_in_clock_nanosleep", "sleeping_other", "unknown")


def state_segments(handle, cpus, stats):
    markers, counts, last, quantum = {}, Counter(), 0, 1
    states = {comm: "unknown" for comm in cpus}
    changes = {comm: [] for comm in cpus}
    sleeping_syscall = set()
    trace_ids, names = {}, {}
    decoded = []

    def identify(comm, tid):
        require(tid > 0 and trace_ids.setdefault(comm, tid) == tid and names.setdefault(tid, comm) == comm,
                "trace PID changed or collided for an issuing thread")

    def update(comm, state, ns):
        if state != states[comm]:
            states[comm] = state
            changes[comm].append((ns, state))

    for line in handle:
        if line.startswith("#") or not line.strip():
            continue
        entry = LINE.fullmatch(line.rstrip())
        require(entry, f"unexpected dispatch trace record: {line[:160]}")
        comm, tid, cpu, sec, fraction, body = entry.groups()
        tid, cpu = int(tid), int(cpu)
        quantum = max(quantum, 10 ** (9 - len(fraction)))
        ns = int(sec) * 10**9 + int(fraction.ljust(9, "0"))
        require(ns >= last, "dispatch trace monotonic clock went backwards")
        last = ns
        switch = SWITCH.search(body) if body.startswith("sched_switch:") else None
        wake = WAKE.search(body) if body.startswith("sched_wakeup:") else None
        if switch:
            for name, actor in ((switch[1], switch[2]), (switch[4], switch[5])):
                if name in cpus:
                    identify(name, int(actor))
        if wake and wake[1] in cpus:
            identify(wake[1], int(wake[2]))
        decoded.append((tid, cpu, ns, body, switch, wake))

    require(trace_ids.keys() == cpus.keys(), "issuer names missing from scheduler event payloads")
    for tid, cpu, ns, body, switch, wake in decoded:
        if body in ("tracing_mark_write: micropod-dispatch-start", "tracing_mark_write: micropod-dispatch-stop"):
            label = body.rsplit("-", 1)[1]
            require(label not in markers, "duplicate capture marker")
            markers[label] = ns
            counts["marker"] += 1
        elif switch:
            before, _, state, after, _ = switch.groups()
            require(before in cpus or after in cpus, "scheduler switch escaped issuer filters")
            if before in cpus:
                require(cpu == cpus[before] and state[0] in "RSDI", "issuer switched out on the wrong CPU or state")
                new = ("runnable" if state.startswith("R") else
                       "sleeping_in_clock_nanosleep" if before in sleeping_syscall else "sleeping_other")
                update(before, new, ns)
            if after in cpus:
                require(cpu == cpus[after], "issuer switched onto the wrong CPU")
                update(after, "on_cpu", ns)
            counts["switch"] += 1
        elif wake:
            actor, _, target_cpu = wake.groups()
            require(actor in cpus and int(target_cpu) == cpus[actor], "scheduler wakeup escaped issuer filters")
            if states[actor] != "on_cpu":
                update(actor, "runnable", ns)
            counts["wake"] += 1
        elif call := ENTER.fullmatch(body):
            arguments = dict(re.findall(r"\b(\w+):\s*(0x[0-9a-f]+|\d+)", call[1]))
            comm = names.get(tid)
            require(comm in cpus and cpus[comm] == cpu and comm not in sleeping_syscall
                    and all(int(arguments.get(k, "0"), 0) == 1 for k in ("which_clock", "flags")),
                    "expected issuer clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME)")
            sleeping_syscall.add(comm)
            counts["nanosleep_enter"] += 1
        elif EXIT.fullmatch(body):
            comm = names.get(tid)
            require(comm in cpus and cpus[comm] == cpu, "nanosleep exit escaped issuer filters")
            sleeping_syscall.discard(comm)
            counts["nanosleep_exit"] += 1
        else:
            raise ValueError(f"unexpected enabled dispatch trace event: {body[:160]}")
    require(sum(counts.values()) == sibling_trace.check_stats(stats) and counts["marker"] == 2
            and markers["start"] < markers["stop"] and counts["switch"] and counts["wake"],
            "incomplete dispatch trace or truncated capture")
    segments = {}
    for tid, transitions in changes.items():
        require(transitions, f"missing issuer scheduling transitions for {tid}")
        clipped = [(markers["start"], "unknown")]
        for when, state in transitions:
            if when <= markers["start"]:
                clipped[0] = (markers["start"], state)
            elif when < markers["stop"]:
                clipped.append((when, state))
        segments[tid] = [(start, end, state) for (start, state), (end, _) in
                         zip(clipped, clipped[1:] + [(markers["stop"], "unknown")], strict=True)]
    return segments, markers, quantum, dict(counts), trace_ids


def attribution(segments, gate, quantum, start, end):
    """Bound overlap of each observed scheduler state with one fresh interval."""
    require(0 <= start <= end, "invalid fresh dispatch interval")
    out = {state: [0, 0] for state in STATES}
    if start == end:
        return out
    lo, hi = gate
    for a, b, state in segments:
        lower = max(0, min(b - quantum, lo + end) - max(a + quantum, hi + start))
        upper = max(0, min(b + quantum, hi + end) - max(a - quantum, lo + start))
        out[state][0] += lower
        out[state][1] += upper
    return {state: [low, min(high, end - start)] for state, (low, high) in out.items()}


def verify_identity(target, before, after):
    def record(row):
        status = dict(line.split(":", 1) for line in row["status"].splitlines() if ":" in line)
        pids, tids = [list(map(int, status[k].split())) for k in ("NStgid", "NSpid")]
        require(pids[0] == row["proc_pid"] and tids[0] == row["proc_tid"]
                and (pids[-1], tids[-1]) == (target["pid"], target["tid"]) and min(len(pids), len(tids)) >= 2
                and row["pidns"] == target["pidns"] and status["Cpus_allowed_list"].strip() == target["mask"]
                and row["comm"] == status["Name"].strip() == target["comm"],
                "issuer PID namespaces or CPU affinity do not match")
        args = row["cmdline"].split("\x00")
        require(args[0] == "/mpcheck/quiet-http" and args[args.index("-ready-file") + 1] == f"/gate/{TAG}.{target['slot']}"
                and args[args.index("-dispatch-trace") + 1] == target["comm"],
                "issuing thread belongs to the wrong paced command")
        stat = row["stat"].rpartition(") ")[2].split()
        return row["proc_pid"], row["proc_tid"], int(stat[19])

    require(record(before) == record(after), "issuer PID or birth time changed during capture")


def issued_call_windows(receipt, target, base_slice, markers, quantum):
    window, pace = receipt["window"], receipt["pace"]
    issuer = {k: target[k] for k in ("pid", "tid", "pidns", "comm")}
    require(receipt["complete"] is True and pace["trace_issuer"] == issuer and pace["issuing_tid"] == issuer["tid"]
            and window["pid"] == issuer["pid"] and pace["wait_clock"] == "linux-clock-monotonic-absolute"
            and pace["slot"] == target["slot"] and pace["offered_rps"] == RATE
            and len(receipt["samples"]) == len(pace["arrivals"]) == receipt["requested"] == 3000,
            "issuing thread or fixed offer proof does not match")
    require(issuer["tid"] in {t["tid"] for t in window["threads"]} and all(
        t["cpus_allowed_list"] == target["mask"] and t["policy"] == t["nice"] == t["priority"] == 0
        and t["slice_ns"] == base_slice for t in window["threads"]), "issuer did not retain the inherited slice")
    bracket, sample, offset, upper = (pace[k] for k in (
        "clock_calibration_ns", "clock_sample_ns", "origin_from_bracket_start_ns", "kernel_origin_upper_ns"))
    require(all(type(v) is int for v in (bracket, sample, offset, upper)) and bracket > 0 and sample > 0
            and upper == sample + offset and pace["timer_slack_ns"] > 0, "invalid raw monotonic clock calibration")
    lower = upper - bracket
    require(markers["start"] + quantum <= lower and
            upper + pace["arrivals"][-1]["completion_offset_ns"] + quantum <= markers["stop"],
            "guest monotonic trace does not cover the complete offered window")
    sibling_paced.check_socket(receipt["warmup"], False, f"slot {target['slot']}")
    intervals, completion = [], 0
    for index, (a, request) in enumerate(zip(pace["arrivals"], receipt["samples"], strict=True)):
        due, begin, finish = (a[k] for k in ("due_offset_ns", "dispatch_offset_ns", "completion_offset_ns"))
        require(due == sibling_paced.due_offset(RATE, target["slot"], index) and max(due, completion) <= begin < finish
                and a["latency_ns"] == finish - due and finish - begin == request["total_ns"], "paced sample changed")
        sibling_paced.check_socket(request, True, f"slot {target['slot']}")
        intervals.append((index, due, completion, begin))
        completion = finish
    require(window["started_unix_ns"] == window["scheduled_unix_ns"] + intervals[0][3] and
            window["finished_unix_ns"] == window["scheduled_unix_ns"] + completion, "raw gate offsets differ")
    return (lower, upper), intervals


def replay(folder):
    def read(name):
        return json.loads((folder / name).read_bytes())

    plan = read("plan.json")
    slots = plan["dispatch_trace_slots"]
    scheduler = read("fair-scheduler.json")
    base = SLICES[plan["worker_scheduler"]]
    require(read("status.json") == {"complete": True} and read("verification.json") == {"baseline_files": 24, "extra_cleanup_errors": []}
            and read("cleanup.json") == {"scope": plan["scope"], "retained": False, "errors": []}
            and not Path(plan["scope"]).exists(), "dispatch diagnostic or scoped cleanup incomplete")
    require(0 < len(slots) <= 2 and slots == sorted(set(slots)) and all(0 <= slot < 32 for slot in slots)
            and scheduler["before"] == scheduler["after"] and scheduler["base_slice_ns"] == base
            and scheduler["clocksource"] == "arch_sys_counter" and {"NEXT_BUDDY", "HRTICK"}.issubset(scheduler["after"])
            and not (folder / "windows.json").exists(), "dispatch trace profile or diagnostic isolation differs")
    require(scheduler == sibling_sched.read(folder / "fair-scheduler", plan.get("guest_fair", "inherit"),
                                             plan["worker_scheduler"], True), "dispatch trace scheduler readback changed")
    for path, field in ((DRIVER, "dispatch_trace_driver_sha256"), (SOURCE, "dispatch_trace_guest_source_sha256"),
                        ("sibling-driver.py", "harness_sha256"), ("quiet-http.go", "quiet_source_sha256")):
        require(terminal.digest(folder / path) == plan[field], f"archived dispatch source changed: {path}")
    require((folder / "quiet-http.go").read_bytes() == probe_source((folder / "quiet-http-base.go").read_bytes()),
            "archived dispatch HTTP loop differs from the pinned source")
    workload = read("dispatch-trace-workload.json")["grouped-0-all"]
    require(all(workload[engine] == {"requests": 96_000, "builds": 8} for engine in "AB"), "ordinary paired CI workload incomplete")
    targets, kernel = read("dispatch-trace-targets.json"), read("dispatch-trace-kernel.json")
    require([t["slot"] for t in targets] == slots and "[mono]" in kernel["clock"]
            and all(t["comm"] == issuing_name(Path(plan["scope"]).name, t["slot"]) for t in targets)
            and len(kernel["before"]) == len(kernel["after"]) == len(slots), "wrong scoped trace actors or clock")
    cpus = {}
    for target, before, after in zip(targets, kernel["before"], kernel["after"], strict=True):
        verify_identity(target, before, after)
        cpus[before["comm"]] = int(target["mask"])
    require(len(cpus) == len(slots), "repeated issuer name")
    def match(field):
        return "(" + " || ".join(f'{field} == "{comm}"' for comm in cpus) + ")"

    require(kernel["filters"] == {
        "sched/sched_switch": match("prev_comm") + " || " + match("next_comm"), "sched/sched_wakeup": match("comm"),
        "syscalls/sys_enter_clock_nanosleep": match("COMM"), "syscalls/sys_exit_clock_nanosleep": match("COMM"),
    } and set(kernel["formats"]) == set(kernel["filters"]), "kernel trace filters differ from issuing threads")
    require(all(set(kernel[k]) == set(kernel["filters"]) and all(v.strip() == "1" for v in kernel[k].values())
                for k in ("enable_before", "enable_after")), "kernel trace events were not enabled throughout capture")
    with gzip.open(folder / "dispatch-trace.ftrace.gz", "rt") as raw:
        segments, markers, quantum, counts, trace_ids = state_segments(raw, cpus, kernel["stats"])
    inventory = read("grouped-inventory.json")["A"]["jobs"]
    with gzip.open(folder / (TAG + ".json.gz"), "rt") as raw:
        rows = json.load(raw)
    proof = []
    for target, actor in zip(targets, kernel["before"], strict=True):
        slot, comm = target["slot"], actor["comm"]
        item = rows[slot]
        require(target["mask"] == inventory[32 + slot]["mask"] and item["index"] == slot and item["code"] == 0
                and item["receipt"]["marker"] == inventory[slot]["name"], "trace slot differs from paired inventory")
        gate, calls = issued_call_windows(item["receipt"], target, base, markers, quantum)
        onsets = sorted((c for c in calls[1:] if c[2] <= c[1]), key=lambda c: c[3] - c[1], reverse=True)
        out = []
        for index, due, prior, dispatch in [calls[0], *onsets[:8]]:
            require(any(state == "on_cpu" and a - quantum <= gate[1] + dispatch and b + quantum >= gate[0] + dispatch
                        for a, b, state in segments[comm]), "paced dispatch is outside observed on-CPU bounds")
            fresh = max(due, prior)
            out.append({"index": index, "due_offset_ns": due, "prior_completion_offset_ns": prior,
                        "dispatch_offset_ns": dispatch, "fresh_ns": dispatch - fresh,
                        "observed_scheduler_state_bounds_ns": attribution(segments[comm], gate, quantum, fresh, dispatch)})
        proof.append({"slot": slot, "comm": comm, "container_issuer_tid": target["tid"],
                      "proc_issuer_tid": actor["proc_tid"], "trace_issuer_tid": trace_ids[comm],
                      "cpu": cpus[comm], "gate_bounds_ns": gate,
                      "unbacklogged_nonstartup_calls": len(onsets), "calls_with_carried_backlog": len(calls) - 1 - len(onsets),
                      "startup_and_largest_unbacklogged_dispatches": out})
    facts = (folder / "a/guest-facts.txt").read_text().splitlines()
    boot, = [x.removeprefix("boot=") for x in facts if x.startswith("boot=")]
    worker = read("worker-build.json")
    identity = {k: worker[k] for k in ("worker_executable_sha256", "guest_runner_sha256", "guest_start_sha256")}
    identity.update(service_image=read("images.json")["expected"], go_image=read("go-image.json")["expected"])
    for engine, inherited in (("A", base), ("B", 2_100_000)):
        builds = read(f"grouped-0-all-{engine}-go.json")
        require(len(builds) == 8 and all(row["code"] == 0 and all(
            t["policy"] == t["nice"] == t["priority"] == 0 and t["slice_ns"] == inherited
            for t in (row["policy"]["dispatcher"], row["policy"]["child"])) for row in builds),
            "dispatch trace build cohort lost its inherited ordinary slice")
    return plan, identity, {"run": folder.name, "guest_boot": boot, "base_slice_ns": base,
                            "trace_clock_resolution_ns": quantum, "trace_bounds_ns": markers,
                            "trace_event_counts": counts, "slots": proof}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--freeze", action="store_true", help="create a new immutable diagnostic driver snapshot")
    parser.add_argument("--replay", nargs="+", type=Path, help="check one diagnostic, or a matched 2.1 ms/125 us pair")
    args = parser.parse_args()
    if args.freeze:
        require(args.replay is None, "select freeze or replay")
        print(freeze())
        return
    require(args.replay and len(args.replay) in (1, 2), "replay one diagnostic or a paired diagnostic")
    runs = [replay(folder) for folder in args.replay]
    if len(runs) == 2:
        (a, worker_a, trace_a), (b, worker_b, trace_b) = runs
        fields = {"scope", "worker_scheduler"}
        require({k: v for k, v in a.items() if k not in fields} == {k: v for k, v in b.items() if k not in fields}
                and worker_a == worker_b and {a["worker_scheduler"], b["worker_scheduler"]} == set(SLICES)
                and trace_a["guest_boot"] != trace_b["guest_boot"], "diagnostic boots differ by more than the base-slice profile")
    print(json.dumps({"diagnostic_only": True, "runs": [row[2] for row in runs]}, indent=2))


if __name__ == "__main__":
    main()
