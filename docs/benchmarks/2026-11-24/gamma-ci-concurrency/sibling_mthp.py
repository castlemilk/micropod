"""Observe the 64 KiB anonymous THP comparison at build and wave boundaries."""

import gzip
import json
import re
import shutil
from pathlib import Path

import build_mthp16
import sibling_build
from qualify import cli, fanout, require, terminal


DISPATCH = "mthp64-dispatch.sh"
DRIVER = "mthp64-observer.py"
ORDERS_KIB = tuple(16 << order for order in range(2, 12))
FAULT_COUNTERS = ("anon_fault_alloc", "anon_fault_fallback", "anon_fault_fallback_charge")
MEMINFO = ("AnonHugePages", "AnonPages", "MemAvailable", "PageTables", "Slab")
BOOT_ID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"

SAMPLE_DISPATCHER = '''mp_mthp_stat() {
    IFS= read -r mp_mthp_record < "/proc/$$/stat"
    # Drop pid and the parenthesized comm. Put each self counter beside
    # its waited-for children counter, in fault then CPU order.
    set -- ${mp_mthp_record##*) }
    [ "$#" -ge 20 ]
    mp_mthp_values="$$ ${20} $8 $9 ${10} ${11} ${12} ${14} ${13} ${15}"
}
mp_mthp_stat
mp_mthp_before=$mp_mthp_values
'''
SAVE_DISPATCHER = '''mp_mthp_stat
set -C
printf '%s\\n' "$mp_mthp_before" "$mp_mthp_values" > "/gate/$gate.mthp64.$slot.stat"
'''
SNAPSHOT = '''
printf 'value begin_ns %s\\n' "$(date +%s%N)"
IFS= read -r boot < /proc/sys/kernel/random/boot_id
printf 'value boot %s\\n' "$boot"
printf 'value page_bytes %s\\n' "$(getconf PAGESIZE)"
printf 'value ticks_per_second %s\\n' "$(getconf CLK_TCK)"
if [ "$1" = A ]; then
    IFS= read -r cmdline < /proc/cmdline
    printf 'value cmdline %s\\n' "$cmdline"
    thp=/sys/kernel/mm/transparent_hugepage
    for name in enabled defrag shmem_enabled hpage_pmd_size; do
        IFS= read -r value < "$thp/$name"
        printf 'policy %s %s\\n' "$name" "$value"
    done
    for size in "$thp"/hugepages-*kB; do
        [ -r "$size/enabled" ] || continue
        order=${size##*/hugepages-}
        order=${order%kB}
        IFS= read -r value < "$size/enabled"
        printf 'order %s %s\\n' "$order" "$value"
        for stat in anon_fault_alloc anon_fault_fallback anon_fault_fallback_charge; do
            IFS= read -r value < "$size/stats/$stat"
            printf 'fault %s:%s %s\\n' "$order" "$stat" "$value"
        done
    done
    for stat in nr_anon collapse_alloc; do
        IFS= read -r value < "$thp/hugepages-64kB/stats/$stat"
        printf 'mthp64 %s %s\\n' "$stat" "$value"
    done
    awk '$1 ~ /^(AnonHugePages|AnonPages|MemAvailable|PageTables|Slab):$/ {
        print "memory", substr($1,1,length($1)-1), $2
    }' /proc/meminfo
fi
printf 'value end_ns %s\\n' "$(date +%s%N)"
'''


def check_cmdline(cmdline, policy):
    actual = tuple(token for token in cmdline.split() if token.startswith(("thp_", "transparent_hugepage")))
    require(actual == build_mthp16.kernel_args(policy), "wrong live anonymous THP kernel arguments")


def check_boot(facts, policy):
    cmdline, = [line.removeprefix("cmdline=") for line in facts.read_text().splitlines()
                if line.startswith("cmdline=")]
    check_cmdline(cmdline, policy)


def dispatch_file(build_policy):
    return sibling_build.POLICY_DISPATCH_FILE if build_policy is not None else "go-dispatch.sh"


def accounted_dispatch(stock):
    start = 'date +%s%N > "/gate/$gate.go.$slot.tmp"\n'
    end = 'echo "end $(date +%s%N) $nice_value"\n'
    require(stock.count(start) == stock.count(end) == 1 and stock.index(start) < stock.index(end),
            "unexpected Go dispatch timing markers")
    return stock.replace(start, SAMPLE_DISPATCHER + start, 1).replace(end, end + SAVE_DISPATCHER, 1)


def stage_dispatch(folder, work, build_policy=None):
    name = dispatch_file(build_policy)
    staged = work / "probe" / name
    stock = (folder / name).read_text()
    require(staged.read_text() == stock, "staged Go dispatcher differs from its archived source")
    amended = accounted_dispatch(stock)
    (folder / DISPATCH).write_text(amended)
    staged.write_text(amended)
    shutil.copy2(Path(__file__), folder / DRIVER)
    return {"mthp64_dispatch_sha256": terminal.digest(folder / DISPATCH),
            "mthp64_observer_sha256": terminal.digest(folder / DRIVER)}


def verify_dispatch(folder, plan):
    stock = (folder / dispatch_file(plan.get("build_policy"))).read_text()
    require((folder / DISPATCH).read_text() == accounted_dispatch(stock)
            and terminal.digest(folder / DISPATCH) == plan["mthp64_dispatch_sha256"]
            and terminal.digest(folder / DRIVER) == plan["mthp64_observer_sha256"],
            "archived THP dispatcher or observer differs")


def parse_snapshot(output):
    fields = {section: {} for section in ("value", "policy", "order", "fault", "mthp64", "memory")}
    for line in output.splitlines():
        section, name, value = line.split(maxsplit=2)
        require(name not in fields[section], "duplicate guest memory counter")
        number = section in ("fault", "mthp64", "memory") or name in ("begin_ns", "end_ns", "ticks_per_second", "page_bytes")
        fields[section][name] = int(value) if number else value
    return {**fields.pop("value"), **fields}


def check_snapshot(record, tag, phase, policy):
    arm = tag.rsplit("-", 1)[1]
    require(arm in ("A", "B") and record["tag"] == tag and record["phase"] == phase
            and re.fullmatch(BOOT_ID, record["boot"]) and re.fullmatch(r"[0-9a-f]{64}", record["container"])
            and 0 < record["begin_ns"] <= record["end_ns"] and record["ticks_per_second"] > 0
            and record["page_bytes"] == (16384 if arm == "A" else 4096), "wrong THP observation source or interval")
    if arm == "B":
        require(not any(record[k] for k in ("policy", "order", "fault", "mthp64", "memory")) and "host_vm" not in record,
                "peer observation contains candidate-only counters")
        return
    check_cmdline(record["cmdline"], policy)
    config = record["policy"]
    require(re.findall(r"\[(\w+)\]", config["enabled"]) == re.findall(r"\[(\w+)\]", config["shmem_enabled"]) == ["never"]
            and re.findall(r"\[(\w+)\]", config["defrag"]) == ["madvise"]
            and config["hpage_pmd_size"] == str(32768 * 1024), "unexpected global THP policy")
    require(record["order"].keys() == {str(kib) for kib in ORDERS_KIB}
            and all(re.findall(r"\[(\w+)\]", record["order"][str(kib)]) == [policy if kib == 64 else "never"]
                    for kib in ORDERS_KIB), "anonymous THP orders differ from the selected policy")
    require(record["fault"].keys() == {f"{kib}:{field}" for kib in ORDERS_KIB for field in FAULT_COUNTERS}
            and record["mthp64"].keys() == {"nr_anon", "collapse_alloc"}
            and record["memory"].keys() == set(MEMINFO)
            and all(min(record[key].values()) >= 0 for key in ("fault", "mthp64", "memory")),
            "guest memory counters differ")
    require(all(record["host_vm"][k] > 0 for k in ("pid", "birth_ticks", "rss_kib")), "invalid host VM RSS snapshot")


def snapshot(folder, cohort, tag, phase, policy, *, vm_probe=None, vm_pid=None):
    """Sample the first build container and the Mac VM immediately outside one dense wave."""
    arm, cid = cohort.arm, cohort.jobs[cohort.count]["id"]
    record = parse_snapshot(cohort.cmd("exec", cid, "sh", "-ec", SNAPSHOT, "sh", arm))
    record.update(tag=tag, phase=phase, container=cid)
    if arm == "A":
        require(vm_probe is not None and vm_pid is not None, "missing host VM RSS probe")
        task, = json.loads(cli([vm_probe], vm_pid))["tasks"]
        require(task["pid"] == vm_pid, "wrong VM process sampled")
        record["host_vm"] = {"pid": vm_pid, "birth_ticks": task["birth_ticks"],
                             "rss_kib": int(cli(["ps"], "-o", "rss=", "-p", vm_pid))}
    require(phase in ("before", "after") and tag.endswith("-" + arm), "invalid THP observation boundary")
    check_snapshot(record, tag, phase, policy)
    terminal.save(folder / f"{tag}-mthp64-{phase}.json", record)


def collect_builds(folder, cohort, tag, block):
    """Archive the dispatchers' stat values once the build execs have exited."""
    require(cohort.builders == 8, "THP accounting requires eight builds")
    ids = [job["id"] for job in cohort.jobs[cohort.count:cohort.count + cohort.builders]]
    builds = []
    for slot, cid in enumerate(ids):
        path = cohort.work / "gate" / f"{tag}.mthp64.{slot}.stat"
        before, after = [list(map(int, line.split())) for line in path.read_text().splitlines()]
        builds.append({"id": cid, "revision": f"sibling-{block}-{slot}", "before": before, "after": after})
    terminal.save(folder / f"{tag}-mthp64-builds.json", builds)


def build_stat_delta(sample):
    before, after = sample["before"], sample["after"]
    require(len(before) == len(after) == 10 and min(before) >= 0 and before[:2] == after[:2]
            and min(before[:2]) > 0, "build dispatcher changed identity")
    deltas = [b - a for a, b in zip(before[2:], after[2:], strict=True)]
    require(min(deltas) >= 0 and sum(deltas[4:]) > 0, "invalid build dispatcher stat delta")
    # The shell waits for each Go revision's shell, which waits for its own
    # commands. Include those descendant counters plus the dispatcher's self time.
    return dict(zip(("minor_faults", "major_faults", "user_ticks", "system_ticks"),
                    (deltas[i] + deltas[i + 1] for i in range(0, 8, 2)), strict=True))


def memory_summary(before, after, policy, expected_vm=None):
    faults = {key: after["fault"][key] - count for key, count in before["fault"].items()}
    require(min(faults.values()) >= 0 and all(count == 0 for key, count in faults.items()
                                            if policy == "never" or not key.startswith("64:"))
            and (policy == "never" or faults["64:anon_fault_alloc"] > 0), "THP fault counts differ from the live policy")
    small_before, small_after = before["mthp64"], after["mthp64"]
    collapse = small_after["collapse_alloc"] - small_before["collapse_alloc"]
    require(collapse >= 0, "64 KiB THP collapse counter reset")
    vm_before, vm_after = before["host_vm"], after["host_vm"]
    observed_vm = (vm_before["pid"], vm_before["birth_ticks"])
    require(observed_vm == (vm_after["pid"], vm_after["birth_ticks"])
            and expected_vm in (None, observed_vm), "host VM RSS does not match the benchmark worker")
    return {**{field + "_64k": faults[f"64:{field}"] for field in FAULT_COUNTERS},
            "collapse_alloc_64k": collapse, "nr_anon_64k_before_folios": small_before["nr_anon"],
            "nr_anon_64k_after_folios": small_after["nr_anon"],
            "vm_rss_before_kib": vm_before["rss_kib"], "vm_rss_after_kib": vm_after["rss_kib"],
            "guest_memory_before_kib": before["memory"], "guest_memory_after_kib": after["memory"]}


def verify_wave(folder, tag, policy, *, expected_boot=None, expected_vm=None):
    """Verify raw receipts and summarize allocation, RSS and build accounting deltas."""
    def load(name):
        return json.loads((folder / f"{tag}-{name}.json").read_bytes())

    before, after = (load(f"mthp64-{phase}") for phase in ("before", "after"))
    for record, phase in ((before, "before"), (after, "after")):
        check_snapshot(record, tag, phase, policy)
    boot = before["boot"]
    require(expected_boot in (None, boot) and all(before[k] == after[k] for k in
            ("boot", "container", "page_bytes", "ticks_per_second", "policy", "order")),
            "guest or THP policy changed during the wave")

    accounts, builds = load("mthp64-builds"), load("go")
    with gzip.open(folder / f"{tag}.json.gz", "rb") as source:
        http = [row["receipt"]["window"] for row in json.load(source)]
    require(len(http) == 32 and len(accounts) == len(builds) == len({b["id"] for b in builds}) == 8
            and before["container"] == builds[0]["id"],
            "missing THP wave build or HTTP contexts")
    stat, build_ends = [], []
    for sample, row in zip(accounts, builds, strict=True):
        a, b, end = row["stdout"].strip().splitlines()
        label, end_ns, _ = end.split()
        require(row["code"] == 0 and label == "end" and int(end_ns) > row["started_unix_ns"]
                and all(sample[k] == row[k] for k in ("id", "revision"))
                and all(fanout.parse_job(line, 0)["boot"] == boot for line in (a, b)),
                "build accounting differs from the actual dispatch or guest")
        stat.append(build_stat_delta(sample))
        build_ends.append(int(end_ns))
    require(before["end_ns"] <= min(min(w["started_unix_ns"] for w in http), min(b["started_unix_ns"] for b in builds))
            and after["begin_ns"] >= max(max(w["finished_unix_ns"] for w in http), max(build_ends)),
            "THP observations did not enclose the HTTP and build windows")
    summary = {"build_" + key: sum(sample[key] for sample in stat) for key in stat[0]}
    hz = before["ticks_per_second"]
    for key in ("user", "system"):
        summary[f"build_{key}_usec"] = summary.pop(f"build_{key}_ticks") * 1_000_000 / hz

    if tag.endswith("-A"):
        summary.update(memory_summary(before, after, policy, expected_vm))
    return summary
