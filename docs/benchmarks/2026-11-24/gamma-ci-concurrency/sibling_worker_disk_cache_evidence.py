"""Read the ordinary cache mount and virtio device at untimed wave boundaries."""

import json
import re
import shutil
import time
from pathlib import Path

from qualify import fanout, require, terminal


MODES = ("cached", "uncached")
MODE_FILE = "worker-disk-cache.mode"
PROBE_SOURCE = "worker-disk-cache-probe.sh"
DRIVER_SOURCE = "sibling-worker-disk-cache.py"
EVIDENCE_SOURCE = "sibling-worker-disk-cache-evidence.py"
ATTACHMENT_PREFIX = "micropod-bench-worker-disk "
CALIBRATION = "worker-disk-calibration.json"
CAL_BYTES = 1 << 20
STAT_FIELDS = ("reads", "read_merges", "read_sectors", "read_ms",
               "writes", "write_merges", "write_sectors", "write_ms",
               "in_flight", "busy_ms", "queue_ms", "discards", "discard_merges",
               "discard_sectors", "discard_ms", "flushes", "flush_ms")
QUEUE_NAMES = ("logical_block_size", "physical_block_size", "minimum_io_size",
               "optimal_io_size", "max_sectors_kb", "max_hw_sectors_kb", "nr_requests",
               "read_ahead_kb", "rotational", "write_cache", "fua", "scheduler",
               "iostats", "nomerges", "rq_affinity", "wbt_lat_usec",
               "discard_granularity", "discard_max_bytes")
PHASES = ("write", "cold", "warm", "direct")

PROBE = r'''
set -eu
mode=$1
wanted=$2
dev=/sys/block/vdb
emit() { printf '%s\t%s\n' "$1" "$2"; }
stamp() { emit "$1" "$(date +%s%N)"; }
diskstat() { emit "$1" "$(cat "$dev/stat")"; }
stamp started_unix_ns
emit boot "$(cat /proc/sys/kernel/random/boot_id)"
devnum=$(cat "$dev/dev")
emit dev "$devnum"
emit driver "$(basename "$(readlink -f "$dev/device/driver")")"
emit features "$(cat "$dev/device/features")"
mountrow=$(awk '$5=="/cache" {print}' /proc/self/mountinfo)
test "$(printf '%s\n' "$mountrow" | awk -v dev="$devnum" -v root="$wanted" '
    $3==dev && $4==root && $5=="/cache" && $6 ~ /(^|,)rw(,|$)/ {
        for (i=7;i<=NF-2;i++) if ($i=="-" && $(i+1)=="ext4" && $(i+2)=="/dev/vdb") print "valid"
    }')" = valid
emit mount "$mountrow"
emit cache_inode "$(stat -Lc '%d:%i' /cache)"
emit block_bytes "$(stat -f -c %S /cache)"
emit ext4 "$(tr '\n' ' ' < /proc/fs/ext4/vdb/options)"
for key in @QUEUE_NAMES@; do
    if [ -r "$dev/queue/$key" ]; then emit "queue.$key" "$(cat "$dev/queue/$key")"; fi
done
for q in "$dev"/mq/[0-9]*; do
    if [ -d "$q" ]; then
        for key in cpu_list nr_tags nr_reserved_tags; do
            emit "mq.$(basename "$q").$key" "$(cat "$q/$key")"
        done
    fi
done
for where in /proc/pressure/io /sys/fs/cgroup/io.pressure; do
    if [ -r "$where" ]; then
        awk -v path="$where" '{print "pressure." path "." $1 "\t" $NF}' "$where"
    fi
done
case "$mode" in
snapshot)
    diskstat stat
    ;;
calibrate)
    emit tmp_mount "$(awk '$5=="/tmp" {print}' /proc/self/mountinfo)"
    test "$(stat -f -c %T /tmp)" = tmpfs
    tmp=$(mktemp -d /tmp/mp-worker-disk.XXXXXXXX)
    file=
    cleanup() {
        if [ -n "$file" ]; then rm -f -- "$file"; fi
        rm -f -- "$tmp/ref" "$tmp/observed"
        rmdir "$tmp"
    }
    trap cleanup EXIT
    file=$(mktemp /cache/.mp-worker-disk.XXXXXXXX)
    dd if=/dev/urandom of="$tmp/ref" bs=65536 count=16 iflag=fullblock status=none
    emit reference "$(sha256sum < "$tmp/ref" | cut -d ' ' -f 1)"
    diskstat stat
    stamp write.started
    dd if="$tmp/ref" of="$file" bs=65536 count=16 iflag=fullblock conv=fsync status=none
    stamp write.finished
    diskstat write.stat
    emit write.bytes "$(stat -Lc %s "$file")"
    emit file_dev_inode "$(stat -Lc '%d:%i' "$file")"
    # count=0 requests POSIX_FADV_DONTNEED for this file without reading it.
    dd if="$file" of=/dev/null iflag=nocache count=0 status=none
    for read in cold warm direct; do
        flags=fullblock
        if [ "$read" = direct ]; then flags=direct,fullblock; fi
        stamp "$read.started"
        dd if="$file" of="$tmp/observed" bs=65536 count=16 "iflag=$flags" status=none
        stamp "$read.finished"
        diskstat "$read.stat"
        emit "$read.bytes" "$(stat -Lc %s "$tmp/observed")"
        emit "$read.sha256" "$(sha256sum < "$tmp/observed" | cut -d ' ' -f 1)"
    done
    cleanup
    trap - EXIT
    test ! -e "$file" && test ! -e "$tmp"
    emit removed yes
    ;;
*)
    exit 64
    ;;
esac
stamp finished_unix_ns
'''.replace("@QUEUE_NAMES@", " ".join(QUEUE_NAMES))


def stage(work, folder, mode, driver):
    require(mode in MODES, "unknown worker disk cache mode")
    for directory in (work, folder):
        selector = directory / MODE_FILE
        selector.write_text(mode + "\n")
        selector.chmod(0o600)
    probe = (work / "probe") / PROBE_SOURCE
    probe.write_text(PROBE)
    shutil.copyfile(probe, folder / PROBE_SOURCE)
    shutil.copyfile(driver, folder / DRIVER_SOURCE)
    shutil.copyfile(__file__, folder / EVIDENCE_SOURCE)
    return {"worker_disk_cache": mode, "worker_disk_sync_mode": "fsync",
            "worker_disk_driver_sha256": terminal.digest(folder / DRIVER_SOURCE),
            "worker_disk_evidence_sha256": terminal.digest(folder / EVIDENCE_SOURCE),
            "worker_disk_probe_source_sha256": terminal.digest(folder / PROBE_SOURCE)}


def read(folder, name):
    return json.loads((folder / name).read_bytes())


def boots(folder):
    return {arm: fanout.parse_job(log, 0)["boot"] for arm, log in read(folder, "grouped-prime.json").items()}


def attachment(folder, plan):
    log = folder / "a" / "service.stderr"
    lines = [line.removeprefix(ATTACHMENT_PREFIX) for line in log.read_text().splitlines()
             if line.startswith(ATTACHMENT_PREFIX)]
    require(len(lines) == 1, "missing or ambiguous native VZ disk attestation")
    actual = json.loads(lines[0])
    identity = read(folder, "worker-identity.json")
    expected = {"cache_mode": plan["worker_disk_cache"], "sync_mode": "fsync",
                "disk_path": actual["disk_path"], "read_only": False,
                "device_type": "VZVirtioBlockDeviceConfiguration", "image_format": "raw",
                "vm_id": "ci-" + identity["instance"].lower(), "pid": identity["relay_pid"],
                "storage_device_index": 1}
    require(actual == expected and type(actual["read_only"]) is bool
            and type(actual["pid"]) is type(actual["storage_device_index"]) is int
            and Path(actual["disk_path"]).resolve() == Path(plan["scope"]).resolve() / "a" / "worker.ext4",
            "actual Virtualization attachment differs from the selected worker disk and flush mode")
    return actual


def argv(job, mode):
    require(job["name"].endswith("-c0"), "disk observer is not the first builder")
    volume = "/var/lib/micropod/engine/volumes/" + job["name"].removesuffix("-c0") + "-go"
    return ["exec", job["id"], "/bin/sh", "/mpcheck/" + PROBE_SOURCE, mode, volume]


def capture(cohort, folder, name, boot, mode="snapshot"):
    job = cohort.jobs[cohort.count]
    command = argv(job, mode)
    started, monotonic_started = time.time_ns(), time.monotonic_ns()
    proc = terminal.invoke(*cohort.engine, *command, check=False, timeout=22)
    receipt = {"host_started_unix_ns": started, "host_finished_unix_ns": time.time_ns(),
               "host_started_monotonic_ns": monotonic_started, "host_finished_monotonic_ns": time.monotonic_ns(),
               "argv": command, "code": proc.returncode, "raw": proc.stdout, "stderr": proc.stderr}
    terminal.save(folder / name, receipt)
    return check_receipt(receipt, job, boot, mode)


def fields(raw):
    pairs = [line.split("\t", 1) for line in raw.splitlines()]
    result = dict(pairs)
    require(len(result) == len(pairs), "duplicate guest disk readback")
    return result


def mount_info(raw, destination):
    first, last = raw.split(" - ")
    mount, parent, dev, root, target, flags, *_ = first.split()
    filesystem, source, options = last.split()
    require(str(int(mount)) == mount and str(int(parent)) == parent
            and target == destination and "rw" in flags.split(",") and "rw" in options.split(","),
            f"wrong writable mount at {destination}")
    return {"mount": mount, "parent": parent, "dev": dev, "root": root,
            "target": target, "filesystem": filesystem, "source": source, "options": options}


def stat(raw):
    values = raw.split()
    require(len(values) == len(STAT_FIELDS) and all(re.fullmatch(r"[0-9]+", value) for value in values),
            "virtio-blk stat is not a 17-field readback")
    return list(map(int, values))


def delta(before, after):
    result = {k: new - old for k, old, new in zip(STAT_FIELDS, before, after, strict=True) if k != "in_flight"}
    require(all(value >= 0 for value in result.values()), "virtio-blk cumulative counters reset")
    return result


def check_receipt(receipt, job, boot, mode):
    require(receipt["argv"] == argv(job, mode) and receipt["code"] == 0 and not receipt["stderr"]
            and 0 < receipt["host_started_unix_ns"] <= receipt["host_finished_unix_ns"]
            and 0 < receipt["host_started_monotonic_ns"] <= receipt["host_finished_monotonic_ns"],
            f"native disk {mode} command failed: {receipt['stderr'][-400:]}")
    row = fields(receipt["raw"])
    start, finish = (int(row[k]) for k in ("started_unix_ns", "finished_unix_ns"))
    mount = mount_info(row["mount"], "/cache")
    opts = sorted(row["ext4"].split())
    queue = {k.removeprefix("queue."): v for k, v in row.items() if k.startswith("queue.")}
    mq = {k.removeprefix("mq."): v for k, v in row.items() if k.startswith("mq.")}
    queue_ids = {k.partition(".")[0] for k in mq}
    features = row["features"]
    require(0 < start <= finish and row["boot"] == boot and row["driver"] == "virtio_blk"
            and mount["dev"] == row["dev"] and re.fullmatch(r"\d+:\d+", row["dev"])
            and mount["source"] == "/dev/vdb" and mount["filesystem"] == "ext4"
            and mount["root"] == receipt["argv"][-1] and row["block_bytes"] == "4096"
            and re.fullmatch(r"\d+:\d+", row["cache_inode"])
            and {"barrier", "data=ordered", "max_batch_time=15000"} <= set(opts),
            "mount or ext4 durability options differ on the native cache volume")
    required_numeric = ("logical_block_size", "physical_block_size", "nr_requests", "read_ahead_kb")
    require(re.fullmatch(r"[01]{64,}", features)
            and all(re.fullmatch(r"[0-9]+", queue.get(key, "")) for key in required_numeric)
            and queue.keys() <= set(QUEUE_NAMES) and queue.get("write_cache") in ("write back", "write through")
            and queue.get("fua", "0") in ("0", "1") and queue.get("iostats") == "1" and queue_ids
            and mq.keys() == {f"{index}.{key}" for index in queue_ids for key in ("cpu_list", "nr_tags", "nr_reserved_tags")}
            and all(index.isdecimal() and int(mq[f"{index}.nr_tags"]) > int(mq[f"{index}.nr_reserved_tags"]) >= 0
                    and re.fullmatch(r"[0-9]+(?:, [0-9]+)*", mq[f"{index}.cpu_list"]) for index in queue_ids),
            "native queue readback is incomplete")
    pressures = {k.removeprefix("pressure."): int(v.removeprefix("total="))
                 for k, v in row.items() if k.startswith("pressure.")}
    return {"started_unix_ns": start, "finished_unix_ns": finish, "stat": stat(row["stat"]),
            "pressure_usec": pressures, "device": {"boot": boot, "dev": row["dev"], "driver": row["driver"],
                "features": features, "mount": mount, "cache_inode": row["cache_inode"],
                "block_bytes": int(row["block_bytes"]), "ext4_options": opts, "queue": queue, "mq": mq}}


def check_window(folder, block, before, after):
    builds = read(folder, f"grouped-{block}-all-A-go.json")
    starts = [row["started_unix_ns"] for row in builds]
    ends = [row["stdout"].splitlines()[-1].split() for row in builds]
    require(all(row[0] == "end" and row[2] == "0" for row in ends), "invalid native build end timestamps")
    require(len(builds) == 8 and before["device"] == after["device"]
            and before["finished_unix_ns"] < min(starts) <= max(int(row[1]) for row in ends) < after["started_unix_ns"],
            f"disk snapshots did not bound native window {block} and all eight builds")
    pressure = before["pressure_usec"]
    require(pressure.keys() == after["pressure_usec"].keys(), "IO pressure readbacks changed")
    stalls = {key: after["pressure_usec"][key] - value for key, value in pressure.items()}
    require(all(value >= 0 for value in stalls.values()), "IO pressure counters reset")
    return {"block": block, "guest_before_unix_ns": before["finished_unix_ns"],
            "guest_after_unix_ns": after["started_unix_ns"], "disk_stat_delta": delta(before["stat"], after["stat"]),
            "io_pressure_delta_usec": stalls}


def check_calibration(receipt, job, boot, expected_device):
    probe = check_receipt(receipt, job, boot, "calibrate")
    row = fields(receipt["raw"])
    mount = mount_info(row["tmp_mount"], "/tmp")
    digest = row["reference"]
    require(probe["device"] == expected_device and mount["filesystem"] == "tmpfs" and row["removed"] == "yes"
            and re.fullmatch(r"[a-f0-9]{64}", digest) and row["file_dev_inode"].split(":")[0]
            == expected_device["cache_inode"].split(":")[0],
            "calibration used a different cache backing device or left its files")
    previous_end, previous_stat = probe["started_unix_ns"], probe["stat"]
    stages = {}
    for phase in PHASES:
        start, end = (int(row[f"{phase}.{key}"]) for key in ("started", "finished"))
        counters = stat(row[phase + ".stat"])
        require(previous_end <= start < end <= probe["finished_unix_ns"] and int(row[phase + ".bytes"]) == CAL_BYTES
                and (phase == "write" or row[phase + ".sha256"] == digest),
                f"invalid calibrated {phase} timestamps, byte count or checksum")
        stages[phase] = {"elapsed_ns": end - start, "stat_delta": delta(previous_stat, counters)}
        previous_end, previous_stat = end, counters
    write, cold, direct = (stages[phase]["stat_delta"] for phase in ("write", "cold", "direct"))
    require(write["write_sectors"] * 512 >= CAL_BYTES
            and min(cold["read_sectors"], direct["read_sectors"]) * 512 >= CAL_BYTES,
            "calibration failed to witness data writes and cold/direct device reads")
    separate_flush = write["flushes"] > 0
    queue = expected_device["queue"]
    advertised_flush = expected_device["features"][9] == "1"
    advertised_fua = queue.get("fua") == "1"
    if separate_flush:
        witness = "completed_separate_flush"
    elif queue["write_cache"] == "write through":
        witness = "write_through_without_separate_flush"
    elif advertised_fua:
        witness = "fua_capable_without_separate_flush"
    else:
        raise ValueError(f"write-back calibration saw no separate flush (virtio flush={advertised_flush}, FUA unavailable)")
    return {"started_unix_ns": probe["started_unix_ns"], "finished_unix_ns": probe["finished_unix_ns"],
            "bytes": CAL_BYTES, "sha256": digest, "stages": stages, "guest_fsync_succeeded": True,
            "separate_flush_observed": separate_flush, "flush_evidence": witness}


def filename(block, phase):
    return f"worker-disk-{block}-A-{phase}.json"


def calibrate(cohort, folder, boot, expected_device):
    capture(cohort, folder, CALIBRATION, boot, mode="calibrate")
    return check_calibration(read(folder, CALIBRATION), cohort.jobs[cohort.count], boot, expected_device)


def verify(folder, plan, inventories, guest_boots):
    mode = plan["worker_disk_cache"]
    require(mode in MODES and plan["worker_disk_sync_mode"] == "fsync"
            and plan["healthy_pairs"] == 32 and plan["builders"] == 8 and plan["rounds"] == 4
            and plan["offered_rps"] == 64_000 and plan["dense_ms"] == 1500
            and plan["build_scratch"] == "tmpfs" and plan["worker_scheduler"] == "hrtick-250us"
            and plan["worker_next_buddy"] is True and "guest_fair" not in plan
            and (folder / MODE_FILE).read_text() == mode + "\n"
            and (folder / PROBE_SOURCE).read_text() == PROBE
            and all(terminal.digest(folder / name) == plan[key] for name, key in (
                (DRIVER_SOURCE, "worker_disk_driver_sha256"), (EVIDENCE_SOURCE, "worker_disk_evidence_sha256"),
                (PROBE_SOURCE, "worker_disk_probe_source_sha256"))),
            "disk experiment source or selector differs")
    job, boot = inventories["A"]["jobs"][32], guest_boots["A"]
    require(boot != guest_boots["B"] and all(
        "io.micropod.bench.ci.job-cgroup" not in row["docker_inspect"]["Config"]["Labels"]
        for cohort in inventories.values() for row in cohort["jobs"]), "disk trial departed from flat placement")
    stable, previous, windows = None, 0, []
    for block in range(4):
        before, after = (check_receipt(read(folder, filename(block, phase)), job, boot, "snapshot")
                         for phase in ("before", "after"))
        if stable is None:
            stable = before["device"]
        require(before["device"] == stable and previous < before["started_unix_ns"],
                "disk counter windows overlapped or changed device")
        windows.append(check_window(folder, block, before, after))
        previous = after["finished_unix_ns"]
    calibration = check_calibration(read(folder, CALIBRATION), job, boot, stable)
    require(previous < calibration["started_unix_ns"], "disk calibration overlapped the scored windows")
    return {"attachment": attachment(folder, plan), "device": stable, "windows": windows, "calibration": calibration}
