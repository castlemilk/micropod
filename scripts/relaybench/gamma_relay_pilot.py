"""Isolate listener distribution, worker count or kqueue filter batching on Gamma's host relay."""
import argparse
import json
import platform
import struct
import subprocess
import tempfile
from pathlib import Path

from compare import FIXTURE, build, git, measure, sha
from gamma_contrasts import percentile
from gamma_pilot import plan, require, save

REVISION = "2ee6f14375781702107dafc43322334fabf49e73"


def configurations(factor):
    # Both arms compile the very same transport. Only the fixture's listener
    # cursor differs for placement. The workers comparison uses one executable.
    return {"A": (2, factor == "distribution"), "B": (4 if factor == "workers" else 2, False)}


def run(args, orders):
    args.out.mkdir()
    revision = git("rev-parse", "HEAD").decode().strip() if args.factor == "filters" else REVISION
    receipt = dict(host=platform.node(), macos=platform.mac_ver()[0], revision=revision,
                   factor=args.factor, ports=args.ports, seed=args.seed, order=orders,
                   callback_events=128, seconds=6, fixture_sha256=sha(FIXTURE.read_bytes()))
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
                                      stage_connect=args.factor == "filters")
            arm_binaries[arm] = key
        receipt["arm_binaries"] = arm_binaries
        receipt["binaries"] = {key: binary[1] for key, binary in binaries.items()}
        save(args.out / "plan.json", receipt)
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
                        result = measure(exe, 6, args.ports, workers, 512, False, legacy, path)
                        s = result["sample"]
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
    parser.add_argument("factor", choices=("distribution", "workers", "filters"))
    parser.add_argument("--ports", type=int, choices=(1, 32), required=True)
    parser.add_argument("--seed", type=int, default=34199)
    parser.add_argument("--out", type=Path, help="a new output directory")
    parser.add_argument("--run", action="store_true")
    args = parser.parse_args()
    orders = plan(args.seed)
    if args.run:
        if not args.out:
            parser.error("--run needs --out")
        try:
            run(args, orders)
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            parser.exit(1, f"Stopped: {exc}\n")
    else:
        print(json.dumps(dict(factor=args.factor, ports=args.ports, order=orders, seed=args.seed)))
