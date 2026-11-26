"""Read guest-wide ARM timer, softirq and scheduling counters during the Micropod load window."""
import json
import shlex
import shutil
from pathlib import Path

from qualify import HERE, require, terminal


def stage(oci, work, folder, env, args):
    src = HERE / "sibling_counters_linux.go"
    binary = work / "probe/guest-counters"
    terminal.invoke("go", "build", "-trimpath", "-buildvcs=false", "-o", binary, src, env=env)
    shutil.copyfile(src, folder / src.name)
    (work / "guest-counters").mkdir()
    tags = [f"{layout}-{i}-all-A" for layout in args.layouts for i in range(args.rounds)]
    with (oci / "runner/fixture-facts.sh").open("a") as f:
        f.write('\n"$MICROPOD_ENGINE_WORKSPACE/probe/guest-counters" -workspace "$MICROPOD_ENGINE_WORKSPACE" '
                f'-duration-ms {args.dense_ms} {shlex.join(tags)} '
                '>"$MICROPOD_ENGINE_WORKSPACE/guest-counters/log" 2>&1 </dev/null &\n')
    return {"timer_counters": True, "counter_source_sha256": terminal.digest(src),
            "counter_probe_sha256": terminal.digest(binary)}


def collect(work, folder, tag):
    directory = work / "guest-counters"
    source = directory / (tag + ".json")
    if not source.is_file():
        log = directory / "log"
        raise ValueError(f"guest did not collect {tag}: {log.read_text() if log.exists() else 'observer did not start'}")
    shutil.copyfile(source, folder / (tag + "-counters.json"))


def values(s):
    header = [f"CPU{i}" for i in range(4)]
    irqs = [l.split() for l in s["interrupts"].splitlines()]
    soft = [l.split() for l in s["softirqs"].splitlines()]
    require(irqs[0] == soft[0] == header, "unexpected interrupt CPU layout")
    timer, = [row for row in irqs if row[-1:] == ["arch_timer"]]
    out = {"arch_timer": sum(map(int, timer[1:5]))}
    for name in ("TIMER", "HRTIMER", "SCHED", "NET_RX"):
        row, = [row for row in soft if row[:1] == [name + ":"]]
        require(len(row) == 5, "softirq CPU count differs")
        out[name] = sum(map(int, row[1:]))
    stat = dict((key, list(map(int, vals))) for key, *vals in map(str.split, s["stat"].splitlines()))
    out["switches"], = stat["ctxt"]
    cpu = stat["cpu"][:8]  # user, nice, system, idle, iowait, irq, softirq, steal
    require(len(cpu) == 8 and all(key in stat for key in ("cpu0", "cpu1", "cpu2", "cpu3")) and "cpu4" not in stat,
            "unexpected guest CPU counters")
    out.update(ticks=sum(cpu), userspace=cpu[0]+cpu[1], system=cpu[2]+cpu[5]+cpu[6], idle=cpu[3]+cpu[4])
    return out


def score(path, tag, raw, duration_ns):
    record = json.loads(Path(path).read_bytes())
    start = record["start_ns"]
    require(record["tag"] == tag and record["duration_ns"] == duration_ns and
            {r["receipt"]["window"]["scheduled_unix_ns"] for r in raw} == {start}, "wrong guest counter interval")
    before, after = record["before"], record["after"]
    offsets = [s["end_ns"]-t for s, t in ((before, start), (after, start+duration_ns))]
    require(all(t <= s["begin_ns"] <= s["end_ns"] <= t + duration_ns // 50
                for s,t in ((before, start), (after, start+duration_ns))), "guest counters missed a window boundary")
    seconds = (after["begin_ns"]+after["end_ns"]-before["begin_ns"]-before["end_ns"]) / 2e9
    a, b = values(before), values(after)
    d = {k: b[k]-v for k,v in a.items()}
    require(min(d.values()) >= 0 and min(d["arch_timer"], d["switches"], d["ticks"]) > 0, "invalid guest counter delta")
    n = sum(len(r["receipt"]["samples"]) for r in raw)
    return {"arch_timer_irqs_per_s": d["arch_timer"]/seconds, "switches_per_request": d["switches"]/n,
            "arch_timer_irqs_per_1000_requests": 1000*d["arch_timer"]/n, "switches_per_s": d["switches"]/seconds,
            "timer_softirqs_per_s": d["TIMER"]/seconds, "hrtimer_softirqs_per_s": d["HRTIMER"]/seconds,
            "sched_softirqs_per_s": d["SCHED"]/seconds, "net_rx_softirqs_per_s": d["NET_RX"]/seconds,
            "user_fraction": d["userspace"]/d["ticks"], "system_fraction": d["system"]/d["ticks"],
            "idle_fraction": d["idle"]/d["ticks"], "max_boundary_lag_us": max(offsets)/1000}
