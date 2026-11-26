"""Compare concurrency within each of two retained virtio-vsock workloads."""
import hashlib
import json
import math
from pathlib import Path
from statistics import median

from gamma_contrasts import MIB, ROOT, read_receipt

ARCHIVE = ROOT / "docs/benchmarks/2026-11-21/gamma-vnic.json.gz"
SHA = "2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f"
STREAMS = (1, 4, 12, 24, 32)


def attempt(raw, stem, streams, mode, requests=None, bursts=None):
    status, sample, error = (raw[stem + suffix] for suffix in (".status", ".json", ".err"))
    if type(status) is not int:
        raise ValueError(f"{stem}: missing exit status")
    if status:
        if status != 1 or sample is not None or not error:
            raise ValueError(f"{stem}: incomplete failure evidence")
        lines = error.splitlines()
        if any('Get "' not in s or '/data":' not in s or not s.endswith("read: connection reset by peer")
               for s in lines):
            raise ValueError(f"{stem}: unexpected failure signature")
        return {"record": stem, "status": status, "reset_log_lines": len(lines),
                "stderr_sha256": hashlib.sha256(error.encode()).hexdigest(), "sample": None}
    if error is not None or not isinstance(sample, dict):
        raise ValueError(f"{stem}: incomplete successful observation")
    if mode == "bulk":
        if (sample["mode"] != "bulk" or sample["iterations"] != 3 or sample["streams"] != streams
                or sample["reopened_connections"] != 0 or sample["bytes"] != streams * 3 * 8 * MIB
                or sample["elapsed_s"] <= 0
                or not math.isclose(sample["bytes"] / MIB / sample["elapsed_s"], sample["mib_s"])):
            raise ValueError(f"{stem}: bulk workload or delivered byte count changed")
    else:
        rates = sample["parallel_bursts_mib_s"]
        if (sample["parallel_barrier"] is not True or sample["parallel_streams"] != streams
                or sample["bulk_bytes"] != 64 * MIB or sample["requests"] != requests or len(rates) != bursts
                or any(x <= 0 for x in rates) or sample["parallel_mib_s"] != median(rates)
                or not 0 < sample["fresh_p95_us"] <= sample["fresh_p99_us"]):
            raise ValueError(f"{stem}: barrier workload changed")
    return {"record": stem, "status": status, "sample": sample}


def replay():
    archive = read_receipt(ARCHIVE, SHA)
    raw = archive["raw"]
    for arm in ("vs", "control"):
        limits = raw[arm + ".limits"]
        if (raw[arm + ".boot"]["cpus"] != 4
                or [limits[k] for k in ("cpu.max", "cpuset.cpus.effective", "memory.max", "pids.max")]
                != ["400000 100000", "0-3", "1073741824", "512"]):
            raise ValueError("worker budget mismatch")
    if raw["vs.identity"] != raw["vs.name"]:
        raise ValueError("vsock fixture identity not confirmed")
    if sum(k.startswith("vs-diagnostic/") for k in raw) != 30 or sum(k.startswith("vs-screen/") for k in raw) != 25:
        raise ValueError("unexpected diagnostic or screen population")
    shapes = {mode: [attempt(raw, f"vs-diagnostic/{mode}-{n}", n, mode, requests=4, bursts=1)
                     for n in STREAMS] for mode in ("barrier", "bulk")}
    screen = {arm: [attempt(raw, f"vs-screen/{i}-{arm}", 32, "barrier", requests=160, bursts=3)
                    for i in range(1, 5)] for arm in ("control", "vs")}
    return {
        "direction": "232.04", "archive": ARCHIVE.name, "archive_sha256": SHA,
        "recorded_parent_commit": archive["parent_commit"], "image": archive["image"],
        "vsock_host_binary_sha256": archive["binaries_sha256"]["vsock"],
        "archived_baseline_host_binary_sha256": archive["binaries_sha256"]["baseline"],
        "replay_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "workload": "M5 Max Gamma archive, 4 vCPUs, service quota 4 CPUs and 1 GiB, 8 MiB response. "
                    "Within each vsock diagnostic series the independent variable is the stream count. "
                    "Bulk runs attempted three responses per stream. The separate barrier series used four "
                    "fresh checks, a 64 MiB sequential sampling stage and one synchronized parallel burst. "
                    "The separate original screen attempted 160 fresh checks and three 32-stream bursts per arm.",
        "diagnostic_stream_counts": STREAMS, "diagnostics": shapes, "screen": screen,
        "interpretation": "Concurrency alone cannot explain the failures: the 12-, 24- and 32-stream "
                          "sustained controls all completed their expected bytes without reconnecting, while "
                          "each corresponding synchronized workload exited on a /data read reset with no "
                          "final sample. One and four streams completed in both workloads. The workloads "
                          "also differ in setup and reuse; the archive cannot isolate just the barrier, "
                          "prove credit starvation, locate the failing request within the executable, or "
                          "supply mixed-load p95/p99 for failed runs. One diagnostic per count and shape "
                          "does not identify a reliable concurrency threshold. Keep bulk vsock gated on "
                          "per-stream delivery and backpressure evidence under synchronized first responses."
    }


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2, allow_nan=False))
