"""Collect Mac VMM task I/O accounting around the ordinary CI workload and a guest fsync."""
import json
from pathlib import Path
import subprocess
import sys
from unittest.mock import patch

from qualify import require, terminal
import sibling_ci
from sibling_results import read
import sibling_worker_disk_cache_evidence as evidence

FIELDS = ("diskio_bytes_read", "diskio_bytes_written", "logical_writes", "pageins")


def sample(binary, folder, role):
    idle = read(folder, "grouped-idle.json")
    pid = idle["pids"][role]
    birth, = [r["birth_ticks"] for r in idle["before"]["tasks"] if r["pid"] == pid]
    line = subprocess.check_output([binary, str(pid), "1"], text=True, timeout=6).splitlines()
    header, raw = map(json.loads, line)
    expected = set() if role == "micropod_supervisor" else set(range(4))
    require(header["pid"] == pid and raw["birth_ticks"] == birth
            and {t.get("vcpu_index") for t in raw["threads"] if t["group"] == "vcpu"} == expected
            and all(type(raw[k]) is int and raw[k] >= 0 for k in FIELDS),
            f"Mac I/O probe did not identify the same {role} process")
    return {"pid": pid, **{k: raw[k] for k in ("birth_ticks", "monotonic_ns", "epoch_ns", *FIELDS)}}


def delta(start, end):
    require(start["pid"] == end["pid"] and start["birth_ticks"] == end["birth_ticks"]
            and start["monotonic_ns"] < end["monotonic_ns"], "Mac VMM identity or monotonic clock changed")
    values = {k: end[k] - start[k] for k in FIELDS}
    require(min(values.values()) >= 0, "Mac I/O counters regressed")
    return values


def capture(binary, folder, arm, filename, operation):
    role = "micropod_vmm" if arm == "A" else "orbstack_helper"
    first = sample(binary, folder, role)
    if arm == "A":
        supervisor = sample(binary, folder, "micropod_supervisor")
    result = operation()
    extra = {}
    if arm == "A":
        end = sample(binary, folder, "micropod_supervisor")
        extra["supervisor"] = {"before": supervisor, "after": end, "deltas": delta(supervisor, end)}
    last = sample(binary, folder, role)
    terminal.save(folder / filename, {"before": first, "after": last, "deltas": delta(first, last),
                                      **extra,
                                      "sampler_sha256": terminal.digest(binary),
                                      "driver_sha256": terminal.digest(Path(__file__))})
    return result


def run(binary):
    import sibling_worker_disk_cache

    base = sibling_ci.Siblings.run_wave
    original = evidence.calibrate

    def wave(cohort, folder, block, indices, requests, dense_ms, offered_rps=None):
        native_call = lambda: base(cohort, folder, block, indices, requests, dense_ms, offered_rps)
        if len(indices) != 32 or not offered_rps:
            return native_call()
        return capture(binary, folder, cohort.arm, f"host-disk-{block}-{cohort.arm}.json", native_call)

    def calibrate(cohort, folder, boot, expected_device):
        return capture(binary, folder, cohort.arm, "host-disk-calibration.json",
                       lambda: original(cohort, folder, boot, expected_device))

    with patch.object(sibling_ci.Siblings, "run_wave", wave), patch.object(evidence, "calibrate", calibrate):
        sibling_worker_disk_cache.main()


def report(folders):
    fixture = read(Path(__file__).resolve().parent, "sibling-worker-disk-host-probe.json")
    require(fixture["actual"]["diskio_bytes_written"] >= fixture["workload_bytes"] == 8 * 1024**2 and
            fixture["actual"]["diskio_bytes_read"] >= fixture["workload_bytes"], "missing native file control")
    result = []
    for folder in folders:
        plan = read(folder, "plan.json")
        require(read(folder, "status.json") == {"complete": True}, "unqualified worker")
        idle = read(folder, "grouped-idle.json")
        waves = read(folder, "windows.json")
        births = {row["pid"]: row["birth_ticks"] for row in idle["before"]["tasks"]}
        ordered = [(f"{block}-{arm}", arm) for block in range(4)
                   for arm in waves[f"grouped-{block}-all"]["order"]]
        require(len(ordered) == len(set(ordered)) == 8, "missing or duplicated engine window")
        previous_end = 0
        records = {}
        supervisors = {}
        for name, arm in [*ordered, ("calibration", "A")]:
            raw = read(folder, f"host-disk-{name}.json")
            require(raw["sampler_sha256"] == fixture["profiler"]["binary_sha256"]
                    and raw["driver_sha256"] == terminal.digest(Path(__file__)), "Mac disk probe changed")
            before, after = raw["before"], raw["after"]
            pid = idle["pids"]["micropod_vmm" if arm == "A" else "orbstack_helper"]
            require(before["pid"] == pid and before["birth_ticks"] == births[pid]
                    and before["monotonic_ns"] > previous_end and before["epoch_ns"] < after["epoch_ns"],
                    "Mac disk bracket has a different owner or window order")
            previous_end = after["monotonic_ns"]
            if arm == "A":
                extra = raw["supervisor"]
                first, last = extra["before"], extra["after"]
                issuer = read(folder, "worker-identity.json")["relay_pid"]
                require(first["pid"] == issuer == idle["pids"]["micropod_supervisor"]
                        and first["birth_ticks"] == births[issuer] and
                        before["monotonic_ns"] < first["monotonic_ns"] < last["monotonic_ns"] < after["monotonic_ns"]
                        and delta(first, last) == extra["deltas"], "invalid Mac disk attachment owner counters")
                supervisors[name] = extra["deltas"]
            if name == "calibration":
                actual = read(folder, evidence.CALIBRATION)
                require(before["epoch_ns"] <= actual["host_started_unix_ns"] <= actual["host_finished_unix_ns"]
                        <= after["epoch_ns"], "Mac sampler missed the guest calibration")
            elif arm == "A":
                block = int(name.partition("-")[0])
                first = read(folder, evidence.filename(block, "before"))
                last = read(folder, evidence.filename(block, "after"))
                require(first["host_finished_unix_ns"] <= before["epoch_ns"] < after["epoch_ns"]
                        <= last["host_started_unix_ns"], "guest device reads did not enclose the Mac disk samples")
            values = delta(before, after)
            require(values == raw["deltas"], "Mac VMM I/O deltas differ from their source counters")
            values["bracket_seconds"] = (after["monotonic_ns"] - before["monotonic_ns"]) / 1e9
            records[name] = values
        result.append({"archive": folder.name, "seed": plan["seed"], "mode": plan["worker_disk_cache"],
                       "mac_task_io": records, "native_attachment_owner_io": supervisors})
    return {"scope": "The XNU rusage counters cover each VMM and the native process that opens the attachment. Each bracket spans the entire dense wave.",
            "mac_file_control": fixture, "runs": result}


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "replay":
        print(json.dumps(report([Path(v) for v in sys.argv[2:]]), indent=2))
    else:
        executable = Path(sys.argv.pop(1)).resolve(strict=True)
        run(executable)
