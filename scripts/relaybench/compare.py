"""Compare Mac kqueue relay handoff policies on 32 connected byte streams."""
import argparse
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
C_SOURCE = "Sources/CPublishedTCP/PublishedTCP.c"
HEADER = "Sources/CPublishedTCP/include/PublishedTCP.h"
SWIFT_SOURCE = "Sources/MicropodRuntime/NativeLoopbackRelay.swift"
FIXTURE = Path(__file__).with_name("main.c")
ARMS = ("baseline2", "candidate2", "candidate4")
ORDERS = ((0, 1, 2), (2, 1, 0), (1, 2, 0), (0, 2, 1), (2, 0, 1), (1, 0, 2))


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def build(directory, revision, legacy, sanitize, *, batch_filters=False, stage_connect=False, fixture=FIXTURE):
    directory.mkdir()
    for name in (C_SOURCE, HEADER):
        content = git("show", f"{revision}:{name}") if revision else (ROOT / name).read_bytes()
        (directory / Path(name).name).write_bytes(content)
    exe = directory / "relay"
    flags = ["-O3", "-Wall", "-Wextra", "-Werror", "-fblocks"]
    if stage_connect:
        flags.append("-DRELAYBENCH_STAGE_CONNECT")
    if batch_filters:
        if b"MICROPOD_BATCH_STREAM_FILTERS" not in (directory / "PublishedTCP.c").read_bytes():
            raise ValueError("source revision does not support batched stream filters")
        flags.append("-DMICROPOD_BATCH_STREAM_FILTERS=1")
    if legacy:
        flags.append("-DLEGACY_HANDOFF")
    if sanitize:
        flags.extend(["-O1", "-g", "-fsanitize=address,undefined", "-fno-sanitize-recover=all"])
    subprocess.run(["clang", *flags, '-DRELAY_SOURCE="PublishedTCP.c"', "-I", directory, fixture, "-o", exe],
                   check=True)
    return exe, dict(binary=sha(exe.read_bytes()), flags=flags,
                     c=sha((directory / "PublishedTCP.c").read_bytes()),
                     header=sha((directory / "PublishedTCP.h").read_bytes()))


def quantile95(values):
    return sorted(values)[math.ceil(len(values) * .95) - 1]


def measure(exe, seconds, ports, workers, buffer_kib, profile, legacy, fixed_128_progress=None):
    cmd = [exe, str(seconds), str(buffer_kib), str(int(profile)), str(workers), str(ports)]
    if fixed_128_progress is not None:
        cmd.append(fixed_128_progress)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=seconds + 40)
    except subprocess.TimeoutExpired as exc:
        if fixed_128_progress is not None:
            fixed_128_progress.with_suffix(".stdout").write_bytes(exc.stdout or b"")
            fixed_128_progress.with_suffix(".stderr").write_bytes(exc.stderr or b"")
        raise
    if fixed_128_progress is not None:
        fixed_128_progress.with_suffix(".stdout").write_text(proc.stdout)
        fixed_128_progress.with_suffix(".stderr").write_text(proc.stderr)
    if proc.returncode:
        raise RuntimeError(f"relay exit {proc.returncode}, {proc.stderr[-4000:]}")
    sample = json.loads(proc.stdout)
    if not isinstance(sample, dict):
        raise ValueError("relay output must be a sample object")
    for field, requested in (("ports", ports), ("client_buffer_kib", buffer_kib), ("profile", int(profile))):
        observed = sample.get(field)
        if type(observed) is not int or observed != requested:
            raise ValueError(f"relay reported {field}={observed!r}, expected {requested}")
    if type(sample.get("elapsed_ns")) is not int or sample["elapsed_ns"] < seconds * 1_000_000_000:
        raise ValueError("relay elapsed time is shorter than the requested load window")
    expected = [0] * workers
    for i in range(32):
        expected[(i // ports + (0 if legacy else i % ports)) % workers] += 1
    streams, fresh, dispatch = sample["per_stream_bytes"], sample["fresh_ns"], sample["dispatch_ns"]
    if (sample["bulk_flows_per_owner"] != expected or len(streams) != 32 or min(streams) <= 0
            or sum(streams) != sample["bytes"] or len(fresh) != seconds * 40 or len(dispatch) != len(fresh)
            or any(delay < 0 or total < delay or total <= 0 for total, delay in zip(fresh, dispatch))):
        raise ValueError("invalid placement, byte accounting or probe samples")
    return dict(mib_s=sample["bytes"] * 1e9 / (1 << 20) / sample["elapsed_ns"],
                p95_ms=quantile95(fresh) / 1e6, dispatch_p95_ms=quantile95(dispatch) / 1e6,
                cpu_seconds_per_gib=sample["process_cpu_us"] / 1e6 / (sample["bytes"] / (1 << 30)), sample=sample)


def summarize(rows):
    summary = {}
    for ports in (1, 32):
        runs = {arm: {r["round"]: r for r in rows if r["ports"] == ports and r["arm"] == arm and r["ok"]}
                for arm in ARMS}
        table = {}
        for arm, clean in runs.items():
            table[arm] = {"clean": len(clean)}
            if clean:
                for key in ("mib_s", "p95_ms", "dispatch_p95_ms", "cpu_seconds_per_gib"):
                    table[arm][key] = statistics.median(r[key] for r in clean.values())
        for left, right in itertools.combinations(ARMS, 2):
            paired = sorted(runs[left].keys() & runs[right].keys())
            if not paired:
                continue
            ratios = [runs[right][r]["mib_s"] / runs[left][r]["mib_s"] for r in paired]
            rng = random.Random(7317)
            draws = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
            table[f"{right}_vs_{left}"] = dict(
                paired_rounds=paired, wins=sum(r > 1 for r in ratios), throughput_ratio=statistics.median(ratios),
                throughput_ci95=[draws[250], draws[9749]],
                p95_ratio=statistics.median(runs[right][r]["p95_ms"] / runs[left][r]["p95_ms"] for r in paired))
        summary[str(ports)] = table
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="new directory for the recorded runs")
    parser.add_argument("--baseline", default="b97a532a01d866b7b7914acda85e8c07b14cc209")
    parser.add_argument("--rounds", type=int, default=12)
    parser.add_argument("--seconds", type=int, default=6)
    parser.add_argument("--client-buffer-kib", type=int, default=512)
    parser.add_argument("--profile", action="store_true")
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    if args.rounds < 1 or not 1 <= args.seconds <= 60 or not 8 <= args.client_buffer_kib <= 1024:
        parser.error("use positive rounds, 1–60 seconds and an 8–1024 KiB client buffer")
    base = git("rev-parse", "--verify", args.baseline + "^{commit}").decode().strip()
    swift = git("show", f"{base}:{SWIFT_SOURCE}")
    legacy = b"mp_tcp_next_worker" not in swift
    if legacy and (b"private var next = 0" not in swift or b"next = (next + 1) % targets.count" not in swift):
        parser.error("unrecognized baseline handoff policy")
    args.output.mkdir()
    receipt = dict(baseline=base, fixture_sha256=sha(FIXTURE.read_bytes()),
                   driver_sha256=sha(Path(__file__).read_bytes()), baseline_swift_sha256=sha(swift),
                   candidate_swift_sha256=sha((ROOT / SWIFT_SOURCE).read_bytes()),
                   host=platform.node(), macos=platform.mac_ver()[0], arch=platform.machine(),
                   compiler=subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
                   rounds=args.rounds, seconds=args.seconds, client_buffer_kib=args.client_buffer_kib,
                   profile=args.profile, sanitize=args.sanitize, binaries={})
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        executables = {}
        for name, revision in (("baseline", base), ("candidate", None)):
            executables[name], receipt["binaries"][name] = build(Path(tmp) / name, revision, bool(revision and legacy),
                                                                  args.sanitize)
        (args.output / "protocol.json").write_text(json.dumps(receipt, indent=2) + "\n")
        with (args.output / "rounds.jsonl").open("x", buffering=1) as f:
            for n in range(args.rounds):
                for ports in ((1, 32) if n % 2 == 0 else (32, 1)):
                    for pos in ORDERS[(n + (3 if ports == 32 else 0)) % len(ORDERS)]:
                        arm = ARMS[pos]
                        old = arm == "baseline2"
                        row = dict(round=n + 1, arm=arm, ports=ports, started_unix=time.time(),
                                   load_average=os.getloadavg())
                        try:
                            row.update(measure(executables["baseline" if old else "candidate"], args.seconds, ports,
                                               int(arm[-1]), args.client_buffer_kib, args.profile, old and legacy))
                            row["ok"] = True
                        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as e:
                            row.update(ok=False, error=str(e))
                        rows.append(row)
                        print(json.dumps(row, separators=(",", ":")), file=f)
                        print(n + 1, ports, arm, f'{row["mib_s"]:.0f} MiB/s, {row["p95_ms"]:.1f} ms'
                              if row["ok"] else row["error"], flush=True)
    (args.output / "summary.json").write_text(json.dumps(summarize(rows), indent=2) + "\n")
    return int(any(not r["ok"] for r in rows))


if __name__ == "__main__":
    raise SystemExit(main())
