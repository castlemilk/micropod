"""Replay service CPU and CI admission measurements used in the Pro research review."""

import hashlib
import json
import math
import statistics
import subprocess
import sys
import tarfile
from pathlib import Path


HERE = Path(__file__).resolve().parent


def read(path):
    return json.loads(path.read_bytes())


def checked_study(summary, key):
    record = read(HERE / summary)[key]
    folder = HERE / record["directory"]
    raw = subprocess.check_output([sys.executable, "-B", str(HERE / "replay.py"), str(folder)])
    if json.loads(raw) != record["result"]:
        raise ValueError(f"Archived study did not reproduce: {folder.name}")
    return folder


def check_launch_sources(folder):
    expected = read(folder / "plan.json")["sources"]
    markers = {
        "qualify.py": ('"GOMAXPROCS=1"', "dst=/mpcheck,readonly"),
        "churn.py": ('while [ ! -f "/mpcheck/$gate" ]; do sleep .1; done',
                     '(probe / j["name"]).touch(exist_ok=False)'),
    }
    with tarfile.open(folder / "sources.tar.gz") as archive:
        for name, needles in markers.items():
            member, = [m for m in archive.getmembers() if m.name.endswith("/gamma-ci-concurrency/" + name)]
            data = archive.extractfile(member).read()
            if hashlib.sha256(data).hexdigest() != expected[member.name] or any(
                needle not in data.decode() for needle in needles
            ):
                raise ValueError(f"Unverified launch or polling behavior in {folder.name}/{name}")


def upper_cpu_rates(folder):
    """The service CPU reads surround the host counters, giving an upper bound on the interior mean."""
    tenants = read(folder / "tenants-A-32.json")["tenants"]
    if len({t["identity"]["cgroup"] for t in tenants}) != 32 or any(
        t["identity"]["cpu"] != "100000 100000" for t in tenants
    ):
        raise ValueError("Unexpected service population or CPU quota")
    cells = {}
    for block, conditions in enumerate(read(folder / "kernel-plan.json")["order"]):
        for period, condition in enumerate(conditions):
            window = read(folder / f"churn-{4 * block + period}-A.json")
            before, after = window["counter_before"], window["counter_after"]
            seconds = (after["host"]["epoch_ns"] - before["host"]["epoch_ns"]) / 1e9
            if seconds < window["client"]["window_s"]:
                raise ValueError("Host interval does not enclose the client scoring window")
            pairs = zip(before["service_cpu_usec"], after["service_cpu_usec"], strict=True)
            rates = [(end - start) / 1e6 / seconds for start, end in pairs]
            if len(rates) != 32 or min(rates) < 0:
                raise ValueError("Invalid service CPU deltas")
            cells.setdefault(condition, []).append((sum(rates), max(rates)))
    return {
        name: {
            "blocks": len(rows),
            "median_total_service_cores_upper": statistics.median(total for total, _ in rows),
            "median_busiest_service_cores_upper": statistics.median(peak for _, peak in rows),
            "highest_busiest_service_cores_upper": max(peak for _, peak in rows),
        }
        for name, rows in cells.items()
    }


def unreleased_jobs(folder):
    """Mean jobs awaiting a host dispatch in the first six seconds after the CI origin."""
    result = {"A": [], "B": []}
    for path in sorted(folder.glob("churn-*-[AB].json")):
        row = read(path)
        starts = [job["submitted_s"] for job in row["jobs"]]
        if len(starts) != 32 or any(not math.isfinite(t) or t < 0 for t in starts):
            raise ValueError("Invalid dispatch timeline")
        job_seconds = sum(min(6.0, t) for t in starts)
        result[row["arm"]].append(job_seconds / 6.0)
    return {arm: {"windows": len(samples), "median_mean_unreleased_jobs": statistics.median(samples)}
            for arm, samples in result.items()}


if __name__ == "__main__":
    original = checked_study("summary.json", "mixed_peer")
    kernel = checked_study("low-level-summary.json", "kernel_delivery")
    file_peer = checked_study("low-level-summary.json", "file_peer")
    for folder in (original, kernel, file_peer):
        check_launch_sources(folder)
    result = {
        "stock_service_cpu": upper_cpu_rates(kernel),
        "unreleased_jobs_first_six_seconds": {f.name: unreleased_jobs(f) for f in (original, file_peer)},
        "iid_probability_240_samples_include_population_p99_or_above": 1 - 0.99**240,
    }
    print(json.dumps(result, indent=2, allow_nan=False))
