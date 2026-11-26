"""Measure calibrated vCPU counters inside the shared HTTP and build interval on Gamma."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import shutil
from statistics import median
import sys
import time
from unittest.mock import patch

from qualify import require, terminal
import sibling_build
import sibling_host_vcpu as host
from sibling_compiler_runtime_counters import hardware_counts
from sibling_paced_results import read_wire
from sibling_results import read
import sibling_tmpfs

CPUS = range(4)
SHORT, LONG = 2**20, 2**26
POINTS = (0.30, 1.10)
SOURCE = Path(__file__).name
GUEST_EXE = "/mpcheck/vcpu-instructions"


def calibration(binary, folder, cohort):
    rows = []
    for cpu in CPUS:
        job = cohort.jobs[cohort.count + cpu]
        require(job["mask"] == str(cpu), "calibration job must have its assigned singleton cpuset")
        for n in (SHORT, LONG, LONG, SHORT):
            before = host.sample(binary, folder, cohort.arm)
            line = cohort.cmd("exec", job["id"], GUEST_EXE, str(n), timeout=12)
            after = host.sample(binary, folder, cohort.arm)
            rows.append({"cpu": cpu, "container": job["id"], "iterations": n, "output": line,
                         "before": before, "after": after})
    return rows


def clock_checks(cohort):
    job = cohort.jobs[cohort.count]
    samples = []
    for _ in range(3):
        wall, mono = time.time_ns(), time.monotonic_ns()
        out = cohort.cmd("exec", job["id"], "sh", "-ec", "cat /proc/sys/kernel/random/boot_id; date +%s%N")
        end_mono, end_wall = time.monotonic_ns(), time.time_ns()
        boot, now = out.splitlines()
        samples.append({"host_before": wall, "host_after": end_wall, "mono_before": mono, "mono_after": end_mono,
                        "guest_epoch": int(now), "guest_boot": boot, "container": job["id"]})
    return samples


def middle(binary, wave, began):
    points = []
    for delay in POINTS:
        time.sleep(max(0, began + delay - time.monotonic()))
        wall = time.time_ns()
        sample = host.sample(binary, wave.output.parent, wave.cohort.arm)
        points.append({"host_before": wall, "host_after": time.time_ns(), "sample": sample})
    return points


def run(guest, profiler):
    import sibling_job_parent

    guest_info = read(guest.parent, "product.json")
    require(guest_info["instructions_per_iteration"] == 18 and
            terminal.digest(guest) == guest_info["binary_sha256"] and
            terminal.digest(guest.with_name("disassembly.txt")) == guest_info["disassembly_sha256"] and
            all(terminal.digest(guest.with_name(n)) == h for n, h in guest_info["sources"].items()),
            "guest counter calibration product differs")
    profiler_sha = terminal.digest(profiler)
    base_stage, base_qualify = sibling_build.stage, sibling_tmpfs.qualify
    wave_class = sibling_build.BuildWave
    base_start, base_finish = wave_class.start, wave_class.finish

    def stage(folder, runner, work, engine, archive, **kwargs):
        result = base_stage(folder, runner, work, engine, archive, **kwargs)
        shutil.copy2(guest, work / "probe/vcpu-instructions")
        shutil.copy2(Path(__file__), folder / SOURCE)
        terminal.save(folder / "midwindow-probes.json",
                      {"guest": guest_info, "profiler": str(profiler), "profiler_sha256": profiler_sha,
                       "driver_sha256": terminal.digest(folder / SOURCE)})
        return result

    def qualify(folder, cohorts, mode, phase):
        base_qualify(folder, cohorts, mode, phase)
        terminal.save(folder / f"midwindow-clock-{phase}.json", {
            arm: host.attempt(clock_checks, cohort) for arm, cohort in cohorts.items()
        })
        if phase == "after":
            terminal.save(folder / "midwindow-calibration.json", {
                arm: host.attempt(calibration, profiler, folder, cohort) for arm, cohort in cohorts.items()
            })

    def start(wave):
        last = base_start(wave)
        wave.midwindow = pool.submit(host.attempt, middle, profiler, wave, time.monotonic())
        return last

    def finish(wave):
        rows = base_finish(wave)
        terminal.save(wave.output.parent / f"midwindow-{wave.tag}.json", wave.midwindow.result())
        return rows

    with ThreadPoolExecutor(max_workers=1) as pool, patch.object(sibling_build, "stage", stage), \
         patch.object(sibling_tmpfs, "qualify", qualify), patch.object(wave_class, "start", start), \
         patch.object(wave_class, "finish", finish):
        sibling_job_parent.main()


def calibration_results(rows, jobs, pid, birth):
    deltas = []
    for cpu in CPUS:
        data = rows[4*cpu:4*cpu+4]
        observed = {n: [] for n in (SHORT, LONG)}
        for row, n in zip(data, (SHORT, LONG, LONG, SHORT), strict=True):
            require(row["cpu"] == cpu and row["iterations"] == n and row["container"] == jobs[32+cpu]["id"]
                    and row["output"].split() == [str(cpu), str(n), str(16*n)], "wrong CPU or arithmetic workload")
            first, second = row["before"], row["after"]
            host.deltas(first, second)
            require(first["header"]["pid"] == pid and first["birth_ticks"] == birth
                    and first["header"]["level_names"] == ["Super", "Performance"],
                    "calibration belongs to a different host VM or performance level")
            before = {t["vcpu_index"]: t["level_instructions"] for t in first["threads"]}
            counts = {}
            for t in second["threads"]:
                i = t["vcpu_index"]
                delta = [b - a for a, b in zip(before[i], t["level_instructions"], strict=True)]
                require(len(delta) == 2 and min(delta) >= 0, "calibration counter rolled back")
                counts[str(i)] = sum(delta)
            observed[n].append(counts)
        added = {str(i): median(v[str(i)] for v in observed[LONG]) - median(v[str(i)] for v in observed[SHORT])
                 for i in CPUS}
        fraction = added[str(cpu)] / (18 * (LONG - SHORT))
        qualified = .90 <= fraction <= 1.10 and added[str(cpu)] == max(added.values())
        deltas.append({"cpu": cpu, "observed_over_expected": fraction, "qualified": qualified,
                       "differential_instructions_by_vcpu": added})
    require(len(rows) == 16, "unexpected instruction calibration count")
    return deltas


def interval_bounds(checks, boot, cid):
    rows = []
    for check in checks:
        require(isinstance(check, list) and len(check) == 3, "guest clock measurements unavailable")
        for s in check:
            duration = s["host_after"] - s["host_before"]
            require(s["container"] == cid and s["guest_boot"] == boot and duration > 0
                    and abs(duration - (s["mono_after"]-s["mono_before"])) < 2_000_000,
                    "guest clock identity or host realtime clock changed")
        rows.append(min(check, key=lambda s: s["host_after"] - s["host_before"]))
    first, last = rows
    require(first["host_after"] < last["host_before"] and first["guest_epoch"] < last["guest_epoch"],
            "clock checks are unordered")
    elapsed = last["mono_before"] - first["mono_before"]
    require(abs((last["host_before"]-first["host_before"]) - elapsed) < 5_000_000, "host realtime clock stepped")
    low = min(s["guest_epoch"] - s["host_after"] for s in rows)
    high = max(s["guest_epoch"] - s["host_before"] for s in rows)
    require(high - low < 100_000_000, "guest/host offset checks differ by 100 ms or more")
    return first["host_after"], last["host_before"], low, high


def describe(folder):
    prod = read(folder, "midwindow-probes.json")
    require(terminal.digest(folder / SOURCE) == prod["driver_sha256"]
            and terminal.digest(Path(prod["profiler"])) == prod["profiler_sha256"]
            and terminal.digest(Path(prod["guest"]["elf"])) == prod["guest"]["binary_sha256"],
            "mid-window probe provenance changed")
    idle = read(folder, "grouped-idle.json")
    inventory = read(folder, "grouped-inventory.json")
    primes = read(folder, "grouped-prime.json")
    plan = read(folder, "plan.json")
    require(read(folder, "status.json") == {"complete": True}, "unqualified run")
    checks = [read(folder, f"midwindow-clock-{p}.json") for p in ("before", "after")]
    cal = read(folder, "midwindow-calibration.json")
    engines = {}
    for arm, process in (("A", "micropod_vmm"), ("B", "orbstack_helper")):
        jobs = inventory[arm]["jobs"]
        boot = sibling_build.check_revision(primes[arm], "sib-prime", jobs[32]["name"])["boot"]
        pid = idle["pids"][process]
        birth, = [row["birth_ticks"] for row in idle["before"]["tasks"] if row["pid"] == pid]
        calibration_rows = calibration_results(cal[arm], jobs, pid, birth)
        earliest, latest, low, high = interval_bounds([s[arm] for s in checks], boot, jobs[32]["id"])
        windows = []
        for block in range(plan["rounds"]):
            tag = f"grouped-{block}-all-{arm}"
            start, stop = read(folder, f"midwindow-{tag}.json")
            for p in (start, stop):
                require(earliest < p["host_before"] <= p["sample"]["epoch_ns"] <= p["host_after"] < latest,
                        "sample was outside the host clock bracket")
            launches, finishes = [], []
            for i, (r, job) in enumerate(zip(read(folder, tag+"-go.json"), jobs[32:40], strict=True)):
                require(r["id"] == job["id"] and r["code"] == 0 and job["mask"] == str(i % 4),
                        "last builder identity or affinity differs")
                end = r["stdout"].splitlines()[-1].split()
                require(len(end) == 3 and end[0] == "end" and end[2] == "0", "invalid timed build result")
                launches.append(r["started_unix_ns"])
                finishes.append(int(end[1]))
            raw = read_wire(folder, tag)
            http = [r["receipt"]["window"] for r in raw]
            gate = max(launches) + 35_000_000
            require(len(http) == 32 and {w["scheduled_unix_ns"] for w in http} == {gate}
                    and {w["duration_ns"] for w in http} == {1_500_000_000}
                    and all(r["code"] == 0 and r["receipt"]["complete"] for r in raw),
                    "HTTP readbacks disagree with the common build and offer interval")
            margin_start = start["host_before"] + low - max(w["started_unix_ns"] for w in http)
            common_end = min(gate + 1_500_000_000, min(w["finished_unix_ns"] for w in http), min(finishes))
            margin_end = common_end - (stop["host_after"] + high)
            require(min(margin_start, margin_end) > 0, "host observation not inside the common workload")
            counts = hardware_counts({"before": start["sample"], "after": stop["sample"]}, pid, birth)
            cores = {}
            for cpu, row in counts.items():
                ins, cyc = sum(row["level_instructions"]), sum(row["level_cycles"])
                require(min(ins, cyc, row["cpu_seconds"]) > 0, "empty vCPU counters")
                cores[cpu] = {"instructions": ins, "cycles": cyc, "cpu_seconds": row["cpu_seconds"],
                              "instructions_per_cycle": ins/cyc, "cycles_per_cpu_second": cyc/row["cpu_seconds"]}
            final = str(finishes.index(max(finishes)) % 4)
            ratios = {k: cores[final][k] / median(v[k] for cpu, v in cores.items() if cpu != final)
                      for k in cores[final]}
            windows.append({"block": block, "last_build_cpu": final,
                            "start_margin_ns": margin_start, "end_margin_ns": margin_end,
                            "host_interval_ns": stop["sample"]["monotonic_ns"] - start["sample"]["monotonic_ns"],
                            "vcpu": cores, "last_over_other_three_median": ratios})
        engines[arm] = {"guest_boot": boot, "host_offset_range_ns": [low, high], "calibration": calibration_rows,
                        "all_calibrations_passed": all(r["qualified"] for r in calibration_rows), "windows": windows}
    return {"archive": folder.name, "mode": plan["job_parent"], "seed": plan["seed"], "engines": engines}


def report(archives):
    require(archives and len(set(archives)) == len(archives), "expected distinct completed archives")
    runs = [describe(path) for path in archives]
    require(len({r["engines"]["A"]["guest_boot"] for r in runs}) == len(runs)
            and len({r["engines"]["B"]["guest_boot"] for r in runs}) == 1,
            "expected separate native boots and one peer")
    summaries = {}
    for mode in ("flat", "job"):
        summaries[mode] = {}
        for arm in ("A", "B"):
            engines = [r["engines"][arm] for r in runs if r["mode"] == mode]
            windows = [w for e in engines if e["all_calibrations_passed"] for w in e["windows"]]
            summary = {"calibrated_boots": sum(e["all_calibrations_passed"] for e in engines),
                       "examined_boots": len(engines), "qualified_windows": len(windows)}
            if windows:
                summary["median_host_interval_ns"] = median(w["host_interval_ns"] for w in windows)
                summary["minimum_overlap_margin_ns"] = min(min(w["start_margin_ns"], w["end_margin_ns"]) for w in windows)
                summary["median_last_over_other_three"] = {
                    k: median(w["last_over_other_three_median"][k] for w in windows)
                    for k in windows[0]["last_over_other_three_median"]}
                summary["median_total_instructions_per_second"] = median(
                    sum(v["instructions"] for v in w["vcpu"].values()) * 1e9 / w["host_interval_ns"] for w in windows)
            summaries[mode][arm] = summary
    return {"scope": "Four host vCPU threads during the common scheduled HTTP and build interval.",
            "summary": summaries, "runs": runs}


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "replay":
        archives = [Path(s) for s in sys.argv[2:]]
        print(json.dumps(report(archives), indent=2, allow_nan=False))
    else:
        parser = argparse.ArgumentParser(description=__doc__, add_help=False)
        parser.add_argument("guest", type=Path)
        parser.add_argument("profiler", type=Path)
        opts, remaining = parser.parse_known_args()
        sys.argv[1:] = remaining
        run(opts.guest.resolve(strict=True), opts.profiler.resolve(strict=True))

