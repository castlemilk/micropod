"""Collect compiler-affinity evidence outside the timed waves."""

from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import shutil
import time

from qualify import fanout, require, terminal


PAIRS, BUILDERS = 32, 8
VCPUS = ("0", "1", "2", "3")
CG_FIELDS = ("usage_usec", "user_usec", "system_usec", "nr_periods", "nr_throttled", "throttled_usec")
STAT_FIELDS = ("user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal", "guest", "guest_nice")
BOOT = "/proc/sys/kernel/random/boot_id"
SOURCE = Path(__file__).name
PROOF = "sibling_compiler_affinity_proof.sh"
TOOLS = "compiler-affinity-tools.json"
SOURCE_KEYS = {SOURCE: "compiler_affinity_cpu_evidence_sha256", PROOF: "compiler_affinity_tool_proof_sha256"}


def read(folder, filename):
    return json.loads((folder / filename).read_bytes())


def stage(folder):
    for filename in SOURCE_KEYS:
        shutil.copyfile(Path(__file__).with_name(filename), folder / filename)
    return {key: terminal.digest(folder / filename) for filename, key in SOURCE_KEYS.items()}


def verify_sources(folder, plan):
    for filename, key in SOURCE_KEYS.items():
        require(terminal.digest(folder / filename) == plan[key], f"archived compiler evidence source differs: {filename}")


def pairs(jobs):
    require(len(jobs) == PAIRS * 2, "missing compiler cohort containers")
    for slot, (dependency, builder) in enumerate(zip(jobs[:BUILDERS], jobs[PAIRS:PAIRS + BUILDERS], strict=True)):
        home = VCPUS[slot % len(VCPUS)]
        require(dependency["home_cpu"] == builder["home_cpu"] == home and dependency["id"] != builder["id"],
                f"invalid CPU home or identities for compiler slot {slot}")
        yield slot, home, dependency, builder


def read_tool_proof(raw, boot, mask):
    values, files, processes = {}, {}, {}
    threads = {"go": {}, "compile": {}}
    for line in raw.splitlines():
        kind, *args = line.split()
        if kind == "file":
            role, path, sha = args
            require(role not in files and Path(path).is_absolute() and re.fullmatch(r"[a-f0-9]{64}", sha),
                    "invalid executable identity")
            files[role] = {"path": path, "sha256": sha}
        elif kind == "process":
            role, pid, ppid, nice, exe = args
            require(role not in processes and min(int(pid), int(ppid)) > 0 and nice == "0",
                    "invalid Go process identity or priority")
            processes[role] = (int(pid), int(ppid), exe)
        elif kind == "thread":
            role, tid, actual = args
            require(int(tid) > 0 and int(tid) not in threads[role] and actual == mask,
                    f"compiler proof thread {tid} has unexpected affinity {actual}")
            threads[role][int(tid)] = actual
        else:
            value, = args
            require(kind not in values, "duplicate compiler proof field")
            values[kind] = value
    require(values.keys() == {"boot", "requested", "object_bytes"} and values["boot"] == boot
            and values["requested"] == mask and int(values["object_bytes"]) > 0,
            "real Go compiler proof did not complete on the expected guest and mask")
    require(set(files) == {"taskset", "go", "compile"} and processes.keys() == threads.keys(),
            "missing taskset or real Go process proof")
    go_pid = processes["go"][0]
    require(processes["compile"][1] == go_pid and processes["compile"][0] != go_pid
            and all(pid in threads[role] and exe == files[role]["path"] for role, (pid, _, exe) in processes.items()),
            "real compile executable or parent identity differs")
    return files


def verify_tools(folder, plan, inventory, boots):
    mode = plan["compiler_affinity"]
    require(mode in ("home", "pool"), "unknown compiler placement")
    proof = read(folder, TOOLS)
    require(set(proof) == {"A", "B"}, "missing compiler proof engine")
    tools = None
    for arm in "AB":
        for (slot, home, _, builder), row in zip(pairs(inventory[arm]["jobs"]), proof[arm], strict=True):
            require(row["slot"] == slot and row["id"] == builder["id"], f"{arm} compiler proof belongs to another slot")
            identities = read_tool_proof(row["raw"], boots[arm], home if mode == "home" else "0-3")
            if tools is None:
                tools = identities
            require(identities == tools, "executable identities differed among the measured builders")
    return tools


def qualify(folder, cohorts, mode):
    script = (folder / PROOF).read_text()
    records = {}
    for arm, cohort in cohorts.items():
        def probe(item):
            slot, home, _, builder = item
            mask = home if mode == "home" else "0-3"
            raw = cohort.cmd("exec", builder["id"], "/bin/sh", "-ec", script, "sh", mask, timeout=20)
            return {"slot": slot, "id": builder["id"], "raw": raw}

        with ThreadPoolExecutor(max_workers=4) as pool:
            records[arm] = list(pool.map(probe, pairs(cohort.jobs)))
    terminal.save(folder / TOOLS, records)
    boot = {arm: fanout.parse_job(line, 0)["boot"] for arm, line in read(folder, "grouped-prime.json").items()}
    inventory = {arm: {"jobs": cohort.jobs} for arm, cohort in cohorts.items()}
    return verify_tools(folder, {"compiler_affinity": mode}, inventory, boot)


def counters(raw):
    rows = [line.split() for line in raw.splitlines()]
    values = {key: int(value) for key, value in rows}
    require(len(values) == len(rows) and set(CG_FIELDS) <= values.keys() and min(values.values()) >= 0,
            "missing, duplicate, or negative cgroup CPU counters")
    return {name: values[name] for name in CG_FIELDS}


def pressure(raw):
    if raw is None:
        return {}
    values = {}
    for line in raw.splitlines():
        kind, *fields = line.split()
        total, = [int(field.removeprefix("total=")) for field in fields if field.startswith("total=")]
        require(kind in ("some", "full") and kind not in values and total >= 0, "invalid cgroup CPU pressure")
        values[kind] = total
    require("some" in values, "missing cgroup CPU pressure stall totals")
    return values


def cpu_stat(raw):
    if raw is None:
        return {}
    result = {}
    for line in raw.splitlines():
        name, *fields = line.split()
        cpu = name.removeprefix("cpu")
        require(name.startswith("cpu") and cpu in VCPUS and cpu not in result and 8 <= len(fields) <= 10
                and all(field.isdecimal() for field in fields), "invalid per-vCPU /proc/stat")
        result[cpu] = dict(zip(STAT_FIELDS, map(int, fields)))
    require(set(result) == set(VCPUS), "missing guest vCPU counters")
    return result


def difference(before, after, *, may_decrease=()):
    require(before.keys() == after.keys(), "CPU counter fields changed across the wave")
    delta = {key: after[key] - value for key, value in before.items()}
    require(all(value >= 0 or key in may_decrease for key, value in delta.items()), "CPU counters regressed")
    return delta


def sample(cohort):
    start = time.monotonic_ns()

    def probe(job):
        stats = json.loads(cohort.cmd("exec", job["id"], "/mpcheck/netbench", "-net-info", timeout=12))
        return {"id": job["id"], "boot": stats[BOOT], "cpu.stat": stats["/sys/fs/cgroup/cpu.stat"],
                "cpu.pressure": stats.get("/sys/fs/cgroup/cpu.pressure")}, stats.get("/proc/stat")

    entries = list(pairs(cohort.jobs))
    jobs = [job for _, _, dependency, builder in entries for job in (dependency, builder)]
    with ThreadPoolExecutor(max_workers=8) as pool:
        snapshots = list(pool.map(probe, jobs))
    groups = [{"slot": slot, "home_cpu": home, "dependency": snapshots[slot * 2][0],
               "builder": snapshots[slot * 2 + 1][0]} for slot, home, _, _ in entries]
    raw = snapshots[0][1]
    vcpus = "\n".join(line for line in raw.splitlines() if re.match(r"^cpu\d+\s", line)) if raw is not None else None
    return {"host_start_ns": start, "host_end_ns": time.monotonic_ns(), "groups": groups, "vcpu_stat": vcpus}


def wave_name(block, arm):
    return f"grouped-{block}-all-{arm}-compiler-cpu.json"


def verify_wave(folder, block, arm, jobs, boot):
    receipt = read(folder, wave_name(block, arm))
    require(receipt["round"] == block and receipt["arm"] == arm, "compiler CPU receipt belongs to another wave")
    before, after = receipt["before"], receipt["after"]
    entered, returned = receipt["run_wave_host_ns"]
    require(0 < before["host_start_ns"] <= before["host_end_ns"] <= entered < returned
            <= after["host_start_ns"] <= after["host_end_ns"], "CPU probes overlapped the timed wave hooks")
    deltas = []
    for (slot, home, dependency, builder), start, stop in zip(pairs(jobs), before["groups"], after["groups"], strict=True):
        require(start["slot"] == stop["slot"] == slot and start["home_cpu"] == stop["home_cpu"] == home,
                "compiler CPU counters belong to another group")
        row = {"slot": slot, "home_cpu": home}
        for role, job in (("dependency", dependency), ("builder", builder)):
            one, two = start[role], stop[role]
            require(one["id"] == two["id"] == job["id"] and one["boot"] == two["boot"] == boot,
                    f"{arm} compiler CPU counters for slot {slot} changed container or guest identity")
            row[role] = {**difference(counters(one["cpu.stat"]), counters(two["cpu.stat"])),
                         "psi_usec": difference(pressure(one["cpu.pressure"]), pressure(two["cpu.pressure"]))}
        deltas.append(row)
    old_cpu, new_cpu = cpu_stat(before["vcpu_stat"]), cpu_stat(after["vcpu_stat"])
    require(old_cpu.keys() == new_cpu.keys(), "per-vCPU /proc/stat availability changed")
    # Linux documents that iowait is not reliable and can move backwards.
    vcpus = {cpu: difference(values, new_cpu[cpu], may_decrease=("iowait",)) for cpu, values in old_cpu.items()}
    return {"groups": deltas, "guest_vcpu_delta_ticks": vcpus,
            "host_bracket_ns": after["host_end_ns"] - before["host_start_ns"]}


def observe_wave(original, cohort, folder, block, indices, requests, dense_ms, offered_rps=None):
    if len(indices) != PAIRS or not offered_rps:
        return original(cohort, folder, block, indices, requests, dense_ms, offered_rps)
    require(cohort.layout == "grouped" and cohort.builders == BUILDERS, "wrong compiler measurement cohort")
    before = sample(cohort)
    entered = time.monotonic_ns()
    result = original(cohort, folder, block, indices, requests, dense_ms, offered_rps)
    returned = time.monotonic_ns()
    after = sample(cohort)
    terminal.save(folder / wave_name(block, cohort.arm),
                  {"round": block, "arm": cohort.arm, "before": before, "after": after,
                   "run_wave_host_ns": [entered, returned]})
    boot = before["groups"][0]["builder"]["boot"]
    verify_wave(folder, block, cohort.arm, cohort.jobs, boot)
    return result
