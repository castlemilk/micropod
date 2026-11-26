"""Compare individual Micropod relay settings on the Gamma host."""
import argparse
import json
import os
import platform
import struct
import subprocess
import tempfile
from pathlib import Path

from compare import FIXTURE, build, git, measure, sha
from gamma_contrasts import percentile
from gamma_pilot import plan, require, save

REVISION = "2ee6f14375781702107dafc43322334fabf49e73"
WORKER_REVISION = "5b8ea1a6a79d1741e521c080f968fcf04c591e68"


def configurations(factor):
    # Both arms compile the very same transport. Only the fixture's listener
    # cursor differs for placement. The workers comparison uses one executable.
    return {"A": (2, factor == "distribution"), "B": (4 if factor == "workers" else 2, False)}


def verify_worker_controls(sample, workers, read_kib=256):
    for field, expected in (("workers", workers), ("drain_workers", workers), ("callback_events", 128),
                            ("read_bytes", read_kib * 1024)):
        require(type(sample.get(field)) is int and sample[field] == expected, f"worker comparison changed {field}")


def run(args, orders, *, check_only=False):
    read_size = args.factor == "read-size"
    native_controls = args.factor == "workers" or read_size
    require(not check_only or native_controls, "controls-only check requires the worker or read-size comparison")
    args.out.mkdir()
    revision = WORKER_REVISION if args.factor == "workers" else REVISION
    if args.factor == "filters" or read_size:
        revision = git("rev-parse", "HEAD").decode().strip()
    receipt = dict(host=platform.node(), macos=platform.mac_ver()[0], revision=revision,
                   factor=args.factor, ports=args.ports, seed=args.seed, order=orders,
                   action="check" if check_only else "run",
                   callback_events=128, seconds=6, fixture_sha256=sha(FIXTURE.read_bytes()))
    caps = {"A": 256, "B": 512 if read_size else 256}
    environments = {a: dict(os.environ, MICROPOD_BENCH_RELAY_READ_KIB=str(kib)) for a, kib in caps.items()} if read_size else {}
    if read_size:
        receipt["relay_read_kib"] = caps
    save(args.out / "plan.json", receipt)
    require(platform.node().split(".")[0] == "Gamma-128GB", "run only on the original Gamma Mac")
    arms = configurations(args.factor)
    with tempfile.TemporaryDirectory() as temp:
        binaries = {}
        arm_binaries = {}
        for arm, (_, legacy) in arms.items():
            batched = args.factor == "filters" and arm == "B"
            key = "batched" if batched else str(legacy)
            if key not in binaries:
                binaries[key] = build(Path(temp) / arm, revision, legacy, False, batch_filters=batched,
                                      stage_connect=args.factor == "filters" or read_size,
                                      fixed_worker_budget=True if native_controls else None, selectable_reads=read_size)
            arm_binaries[arm] = key
        receipt["arm_binaries"] = arm_binaries
        receipt["binaries"] = {key: binary[1] for key, binary in binaries.items()}
        save(args.out / "plan.json", receipt)
        if native_controls:
            checked = {}
            for arm, (workers, _) in arms.items():
                exe = binaries[arm_binaries[arm]][0]
                sample = json.loads(subprocess.check_output(
                    [exe, "check", "512", "0", str(workers), str(args.ports)], text=True, timeout=15,
                    env=environments.get(arm)))
                checked[arm] = sample
                save(args.out / "worker-controls.json", checked)
                verify_worker_controls(sample, workers, caps[arm])
                require(sample["live_revocation"] is True and sample["sibling_and_reuse"] is True and
                        sample["timed_rounds"] == 0, "worker lifecycle check failed")
            if check_only:
                return
        scored = {}
        for phase, pairs in orders.items():
            for n, order in enumerate(pairs, 1):
                for arm in order:
                    workers, legacy = arms[arm]
                    path = args.out / f"{phase}-{n}-{arm}.progress"
                    path.write_bytes(bytes(8))
                    row = dict(phase=phase, pair=n, arm=arm, workers=workers, clean=False, fresh_offered=240)
                    try:
                        exe = binaries[arm_binaries[arm]][0]
                        result = measure(exe, 6, args.ports, workers, 512, False, legacy, path, env=environments.get(arm))
                        s = result["sample"]
                        if native_controls:
                            verify_worker_controls(s, workers, caps[arm])
                        require(s["callback_events"] == 128, "callback budget changed")
                        per_tick = s["tick_numer"] / s["tick_denom"] / s["elapsed_ns"]
                        row.update(mib_s=result["mib_s"], p95_ms=result["p95_ms"],
                                   p99_ms=percentile(s["fresh_ns"], .99) / 1e6,
                                   cpu_s_per_gib=result["cpu_seconds_per_gib"],
                                   runnable_s_per_s=s["runnable_ticks"] * per_tick,
                                   wait_s_per_s=(s["runnable_ticks"] - s["cpu_ticks"]) * per_tick)
                        row["clean"] = True
                    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as exc:
                        row["error"] = str(exc)
                    submitted, completed = struct.unpack("=II", path.read_bytes())
                    row.update(submitted=submitted, completed=completed, never_submitted=240-submitted,
                               submitted_without_reply=submitted-completed)
                    row["clean"] = row["clean"] and submitted == completed == 240
                    save(path.with_suffix(".json"), row)
                    require(phase != "warmup" or row["clean"], "warmup failed")
                    if phase == "scored" and row["clean"]:
                        scored[n, arm] = row["mib_s"]
        ratios = {n: scored[n, "B"] / scored[n, "A"] for n in range(1, len(orders["scored"]) + 1)
                  if (n, "A") in scored and (n, "B") in scored}
        save(args.out / "complete.json", dict(candidate_over_control=ratios))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("factor", choices=("distribution", "workers", "filters", "read-size"))
    parser.add_argument("--ports", type=int, choices=(1, 32), required=True)
    parser.add_argument("--seed", type=int, default=34199)
    parser.add_argument("--out", type=Path, help="a new output directory")
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--run", action="store_true")
    action.add_argument("--check", action="store_true", help="build and verify the worker or read-size arms without timing")
    parser.add_argument("--pairs", type=int, default=2, help="balanced scored pairs (even, at least two)")
    args = parser.parse_args()
    if args.check and args.factor not in ("workers", "read-size"):
        parser.error("--check applies to the controlled worker and read-size comparisons")
    if args.pairs < 2 or args.pairs % 2:
        parser.error("--pairs must be even and at least two")
    orders = plan(args.seed, args.pairs)
    if args.run or args.check:
        if not args.out:
            parser.error("--run and --check need a new --out directory")
        try:
            run(args, orders, check_only=args.check)
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            parser.exit(1, f"Stopped: {exc}\n")
    else:
        print(json.dumps(dict(factor=args.factor, ports=args.ports, order=orders, seed=args.seed)))
