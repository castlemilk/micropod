"""Compare counter spacing in the fixed-arrival client's bulk response copy path on macOS."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OFFERED = ROOT / "scripts/netbench/offered"
FILES = ["main.go", "counter_layout_test.go"]
SCENARIOS = [(writers, chunk) for writers in (1, 32) for chunk in (4096, 32768)]
SEED, BLOCKS, RESPONSES = 34227, 16, 64


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sample(binary, env, case, stride):
    writers, chunk = case
    args = [binary, "-test.run=^TestOfferedCounterLayout$", f"-counter-writers={writers}",
            f"-counter-chunk={chunk}", f"-counter-stride={stride}", f"-counter-responses={RESPONSES}"]
    result = subprocess.check_output(args, text=True, env=env, timeout=30)
    rows = [json.loads(line[7:]) for line in result.splitlines() if line.startswith("layout ")]
    if len(rows) != 1:
        raise ValueError(f"missing counter layout sample: {result}")
    row = rows[0]
    expected = dict(writers=writers, chunk_bytes=chunk, stride_bytes=stride,
                    warmup_bytes=writers << 23, scored_bytes=RESPONSES << 23, drain_bytes=writers << 23,
                    scored_counter_writes=(RESPONSES << 23) // chunk)
    if any(row[k] != v for k, v in expected.items()) or min(row["wall_ns"], row["cpu_ns"]) <= 0:
        raise ValueError(f"unexpected fixed work or timings: {row}")
    return {k: row[k] for k in ("base_mod_128", "wall_ns", "cpu_ns")}


def effects(ratios):
    rng = random.Random(SEED)
    med = statistics.median
    boot = sorted(med(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
    return dict(median_change_pct=100*(med(ratios)-1), paired_bootstrap95_pct=[100*(boot[i]-1) for i in (249, 9749)])


def measure(binary, env):
    rng = random.Random(SEED)
    orders, raw = {}, {case: [] for case in SCENARIOS}
    for case in SCENARIOS:
        orders[case] = [(8, 128), (128, 8)] * (BLOCKS // 2)
        rng.shuffle(orders[case])
        for stride in (8, 128):
            sample(binary, env, case, stride)
    for i in range(BLOCKS):
        for case in rng.sample(SCENARIOS, len(SCENARIOS)):
            order = orders[case][i]
            pair = {str(s): sample(binary, env, case, s) for s in order}
            raw[case].append(dict(order=list(order), **pair))
    result = []
    for (writers, chunk), pairs in raw.items():
        speeds = [p["8"]["wall_ns"]/p["128"]["wall_ns"] for p in pairs]
        costs = [p["128"]["cpu_ns"]/p["8"]["cpu_ns"] for p in pairs]
        gib = (RESPONSES << 23) / 2**30
        medians = {
            arm: dict(copy_gib_s=statistics.median(gib*1e9/p[arm]["wall_ns"] for p in pairs),
                      process_cpu_ms_per_gib=statistics.median(p[arm]["cpu_ns"]/1e6/gib for p in pairs))
            for arm in ("8", "128")
        }
        result.append(dict(writers=writers, chunk_bytes=chunk, per_arm_scored_bytes=RESPONSES << 23,
                           per_arm_scored_writes=(RESPONSES << 23)//chunk, throughput=effects(speeds),
                           cpu_per_byte=effects(costs), medians=medians, pairs=pairs))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go", default="go")
    args = parser.parse_args()
    env = dict(os.environ, GO111MODULE="off", GOWORK="off", GOPROXY="off", GOTOOLCHAIN="local", GOTELEMETRY="off",
               GOMAXPROCS="4", CGO_ENABLED="0", GOFLAGS="-trimpath")
    env.pop("GOROOT", None)
    with tempfile.TemporaryDirectory() as tmp:
        binary = Path(tmp) / "layout.test"
        subprocess.run([args.go, "test", "-c", "-p=2", "-trimpath", "-ldflags=-buildid=", "-tags=offeredlayout",
                        "-o", binary, *FILES], cwd=OFFERED, env=env, check=True)
        report = dict(
            scope="Offline client-side in-memory copies into the production byte counter, no network or VM.",
            workload="Each active stream copies complete 8 MiB responses from one shared read-only memory body. "
                     "io.Copy's normal buffer and the prescribed reader cap govern write size. Each sample checks "
                     "the warmup, scored, drain and invocation counts for all 32 slots. Scoring begins after "
                     "the goroutines reach a barrier and includes the response copy, Go allocation and GC.",
            method=f"GOMAXPROCS=4. One warmup pair and {BLOCKS} paired blocks per scenario, balanced randomized "
                   f"arm order, shuffled scenarios per block, seed {SEED}. One binary, new process per sample. "
                   "Throughput is logical copy bytes per wall second. CPU is process user plus system time. "
                   "Relative effects are paired medians with a 10,000-resample block bootstrap.",
            go=subprocess.check_output([args.go, "version"], text=True, env=env).strip(),
            platform=platform.platform(), binary_sha256=sha(binary),
            sources={**{name: sha(OFFERED / name) for name in FILES}, Path(__file__).name: sha(Path(__file__))},
            results=measure(binary, env), completed_utc=datetime.now(timezone.utc).isoformat())
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
