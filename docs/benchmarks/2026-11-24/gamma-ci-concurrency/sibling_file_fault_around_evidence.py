"""Stage and verify file fault-around build-tree and guest VM readbacks."""

import json
import os
from pathlib import Path
import re
import shutil
import time

import sibling_build_tail_results as tail
from sibling_flat_holdout_build_results import SOURCES as STOCK_SOURCES
from qualify import ROOT, require, terminal


USAGE_SOURCE = "sibling_file_fault_around_usage_linux.go"
MMAP_SOURCE = "sibling_file_fault_around_mmap_linux.go"
USAGE = "file-fault-around-usage"
MMAP = "file-fault-around-mmap"
PAIR = "file-fault-around-build-pair.sh"
DISPATCH = "file-fault-around-dispatch.sh"
MEMORY = "file-fault-around-memory.sh"
CALIBRATION = "file-fault-around-mmap.json"
BUILD_SUFFIX = '''sh /mpcheck/job.sh "$revision-a"
sh /mpcheck/job.sh "$revision-b"
echo "end $(date +%s%N) $nice_value"
'''
COLLECT = 'cat -- "$1"; rm -- "$1"'
CHILD_COUNTERS = ("user_usec", "system_usec", "minor_faults", "major_faults", "voluntary_switches",
                  "involuntary_switches", "input_blocks", "output_blocks", "max_rss_kib")
PUBLISH_NS = 5_000_000_000
MEM_PROBE = r'''
set -eu
printf 'value begin_ns %s\n' "$(date +%s%N)"
printf 'value boot %s\n' "$(cat /proc/sys/kernel/random/boot_id)"
printf 'value page_bytes %s\n' "$(getconf PAGESIZE)"
awk '$1 ~ /^(MemAvailable|PageTables|SecPageTables|Cached|Shmem):$/ {
     print "kib", substr($1,1,length($1)-1), $2
}' /proc/meminfo
awk '$1 ~ /^(pgfault|pgmajfault|pgpgin|pgpgout|workingset_refault_file|nr_file_pages|nr_page_table_pages)$/ {
     print "vmstat", $1, $2
}' /proc/vmstat
printf 'value end_ns %s\n' "$(date +%s%N)"
'''


def scripts(stock):
    require(stock.endswith(BUILD_SUFFIX) and stock.count(BUILD_SUFFIX) == 1, "wrong stock build dispatcher")
    invocation = f'exec /mpcheck/{USAGE} "$gate" "$slot" "$revision" "$nice_value"\n'
    return {PAIR: "set -eu\nrevision=$1\nnice_value=$2\n" + BUILD_SUFFIX,
            DISPATCH: stock.removesuffix(BUILD_SUFFIX) + invocation, MEMORY: MEM_PROBE}


def stage_probes(work, folder):
    probe = work / "probe"
    env = {**os.environ, "GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0", "GOPROXY": "off"}
    hashes = {}
    for name, output in ((USAGE_SOURCE, USAGE), (MMAP_SOURCE, MMAP)):
        archive = folder / name
        shutil.copyfile(Path(__file__).with_name(name), archive)
        terminal.invoke("go", "-C", ROOT / "guest/runner", "build", "-trimpath", "-buildvcs=false",
                        "-o", probe / output, archive, env=env, timeout=120)
        hashes[name] = terminal.digest(archive)
        hashes[output] = terminal.digest(probe / output)
    shutil.copyfile(__file__, folder / Path(__file__).name)
    hashes[Path(__file__).name] = terminal.digest(folder / Path(__file__).name)
    return hashes


def stage_dispatch(folder, work):
    require(all(terminal.digest(folder / name) == digest for name, digest in STOCK_SOURCES.items())
            and (work / "probe/job.sh").read_bytes() == (folder / "job.sh").read_bytes(),
            "file fault-around measurement requires the stock job.sh")
    generated = scripts((folder / "go-dispatch.sh").read_text())
    for name, content in generated.items():
        (folder / name).write_text(content)
        staged = "go-dispatch.sh" if name == DISPATCH else name
        (work / "probe" / staged).write_text(content)
    return {name: terminal.digest(folder / name) for name in generated}


def check_sources(folder, plan):
    actual = scripts((folder / "go-dispatch.sh").read_text())
    probe_hashes = plan["file_fault_around_probes"]
    require(all(terminal.digest(folder / name) == digest for name, digest in STOCK_SOURCES.items())
            and all((folder / name).read_text() == contents for name, contents in actual.items())
            and plan["file_fault_around_dispatch_sources"] == {name: terminal.digest(folder / name) for name in actual}
            and all(terminal.digest(folder / name) == probe_hashes[name]
                    for name in (USAGE_SOURCE, MMAP_SOURCE, Path(__file__).name))
            and all(re.fullmatch(r"[0-9a-f]{64}", probe_hashes[name]) for name in (USAGE, MMAP)),
            "file fault-around workload or probe source changed")


def build_argv(tag, slot, cid):
    source = f"/dev/shm/mp-file-fault-around.{tag}.{slot}.json"
    return ["exec", cid, "/bin/sh", "-ec", COLLECT, "collect", source]


def collect_builds(cohort, folder, tag, parallel):
    jobs = cohort.jobs[cohort.count:cohort.count + cohort.builders]

    def collect(row):
        slot, job = row
        argv = build_argv(tag, slot, job["id"])
        return {"id": job["id"], "argv": argv, "usage": json.loads(cohort.cmd(*argv, timeout=12))}

    terminal.save(folder / f"file-fault-around-{tag}-builds.json", parallel(8, collect, enumerate(jobs)))


def snapshot_name(tag, phase):
    return f"file-fault-around-{tag}-{phase}.json"


def capture_memory(cohort, folder, tag, phase):
    job = cohort.jobs[cohort.count]
    argv = ["exec", job["id"], "/bin/sh", "/mpcheck/" + MEMORY]
    start = time.time_ns()
    raw = cohort.cmd(*argv, timeout=12)
    terminal.save(folder / snapshot_name(tag, phase), {
        "id": job["id"], "argv": argv, "raw": raw, "host_started_unix_ns": start,
        "host_finished_unix_ns": time.time_ns()})


def check_memory(receipt, arm, job, boot):
    cid = job["id"]
    require(receipt["id"] == cid and receipt["argv"] == ["exec", cid, "/bin/sh", "/mpcheck/" + MEMORY]
            and 0 < receipt["host_started_unix_ns"] <= receipt["host_finished_unix_ns"], "wrong memory snapshot source")
    sections = {name: {} for name in ("value", "kib", "vmstat")}
    for line in receipt["raw"].splitlines():
        section, field, value = line.split(maxsplit=2)
        require(field not in sections[section], "duplicate guest memory counter")
        sections[section][field] = value if field == "boot" else int(value)
    value, kib, vm = (sections[key] for key in ("value", "kib", "vmstat"))
    require(value["boot"] == boot and value["page_bytes"] == {"A": 16_384, "B": 4096}[arm]
            and 0 < value["begin_ns"] <= value["end_ns"] and {"MemAvailable", "PageTables"} <= kib.keys()
            and {"pgfault", "pgmajfault"} <= vm.keys() and all(n >= 0 for n in (*kib.values(), *vm.values())),
            "wrong guest memory counters or clock bounds")
    return {**value, "kib": kib, "vmstat": vm}


def check_build(record, job, original, timed, boot, tag, gate, http_end):
    usage = record["usage"]
    slot, revision = timed["slot"], original["revision"]
    require(record["id"] == job["id"] == original["id"] and record["argv"] == build_argv(tag, slot, job["id"])
            and (usage["tag"], usage["slot"], usage["revision"], usage["boot"], usage["container"], usage["cgroup"])
            == (tag, slot, revision, boot, job["name"], "0::/")
            and usage["argv"] == ["/bin/sh", "/mpcheck/" + PAIR, revision, "0"]
            and type(usage["child_pid"]) is int and usage["child_pid"] > 1
            and usage["child_pid"] != job["affinity"]["pid"]
            and all(type(usage[key]) is int and usage[key] == 0 for key in ("exit_code", "wait_status"))
            and original["code"] == 0,
            "build resource receipt does not identify one successful stock child tree")
    start, child, done, publish, elapsed = (usage[key] for key in (
        "started_unix_ns", "child_started_unix_ns", "finished_unix_ns", "publish_started_unix_ns", "elapsed_ns"))
    require(all(type(x) is int for x in (start, child, done, publish, elapsed))
            and timed["start"] <= start <= child < gate <= http_end <= timed["end"] <= done <= publish
            and publish - start >= PUBLISH_NS - 1_000_000 and abs(done - start - elapsed) < 1_000_000
            and all(type(usage[k]) is int and usage[k] >= 0 for k in CHILD_COUNTERS)
            and usage["max_rss_kib"] > 0 and usage["minor_faults"] > 0
            and usage["user_usec"] + usage["system_usec"] > 0,
            f"build child, HTTP interval, or post-wave resource output disagrees at {tag} slot {slot}")
    return usage


def check_wave(folder, block, arm, jobs, boot, http=None):
    tag = f"grouped-{block}-all-{arm}"
    if http is None:
        http = tail.read(folder, "windows.json")[f"grouped-{block}-all"][arm]
    raw = tail.read(folder, tag + "-go.json")
    builds = tail.build_rows(raw, jobs, arm, block, boot, 0)
    gate = max(row["start"] for row in builds) + 35_000_000
    http_end = gate + http["last_completion_offset_ns"]
    rows = tail.read(folder, f"file-fault-around-{tag}-builds.json")
    children = [check_build(row, job, source, timed, boot, tag, gate, http_end)
                for row, job, source, timed in zip(rows, jobs, raw, builds, strict=True)]
    require(min(r["publish_started_unix_ns"] for r in children) >= max(r["finished_unix_ns"] for r in children),
            "a build resource sidecar was written while another build tree was alive")
    before, after = (check_memory(tail.read(folder, snapshot_name(tag, phase)), arm, jobs[0], boot)
                     for phase in ("before", "after"))
    require(before["end_ns"] < min(row["start"] for row in builds)
            and max(row["publish_started_unix_ns"] for row in children) < after["begin_ns"]
            and before["vmstat"].keys() == after["vmstat"].keys() and before["kib"].keys() == after["kib"].keys(),
            "guest memory snapshot did not bracket the scored wave")
    vm_delta = {k: after["vmstat"][k] - v for k, v in before["vmstat"].items()}
    require(all(v >= 0 for k, v in vm_delta.items() if not k.startswith("nr_")), "guest VM event counters reset")
    return {"gate_unix_ns": gate, "last_completion_unix_ns": http_end, "children": children,
            "memory_before": before, "memory_after": after, "vmstat_delta": vm_delta}
