"""Build, measure and replay a one-vCPU HVF notification comparison on Gamma."""

import argparse
import gzip
import hashlib
import io
import json
import random
import subprocess
import sys
import tarfile
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from statistics import median

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
SRC = ROOT / "scripts/relaybench/hvf_notify"
BRIDGE = SRC.parent / "hvf_tx_probe/apple.c"
sys.path[:0] = [
    str(HERE.parent / "gamma-local-peer"),
    str(HERE.parent / "disposable-local-fixture"),
    str(ROOT / "scripts/relaybench"),
]
import local_terminal as terminal
from gamma_contrasts import paired_median_interval
from run import Admission
from score import load, receiver, require

SEED = 34225
BLOCKS = 16
TOTAL = 65537
MODES = (("mmio", 1), ("hvc", 1), ("mmio", 8), ("hvc", 8))


def schedule():
    # Williams design. Every condition occupies each position once per quartet.
    rows = [(0, 1, 3, 2), (1, 2, 0, 3), (2, 3, 1, 0), (3, 0, 2, 1)]
    rng = random.Random(SEED)
    plan = [list(range(4))]
    for _ in range(BLOCKS // 4):
        plan.extend(rng.sample(rows, len(rows)))
    return [
        [{"block": n, "transport": MODES[i][0], "batch": MODES[i][1]} for i in indices]
        for n, indices in enumerate(plan)
    ]


PAYLOAD_SEED = 34226


def payload_schedule():
    rng = random.Random(PAYLOAD_SEED)
    order = ["AB"]
    for _ in range(BLOCKS // 2):
        order.extend(rng.sample(["AB", "BA"], 2))
    return [
        [{"block": n, "transport": "staged" if arm == "A" else "mapped", "batch": 8} for arm in pair]
        for n, pair in enumerate(order)
    ]


def assess(folder):
    status = load(folder / "status.json")
    require(
        status["complete"]
        and status["action"] == "run"
        and status["process_exit"] == 0
        and status["temporary_build_removed"],
        "hardware run incomplete",
    )
    plan = load(folder / "plan.json")
    require(
        plan["vcpus"] == 1 and plan["page_bytes"] == 16384 and plan["hv_support"] == "1", "wrong HVF setup"
    )
    with tarfile.open(folder / "sources.tar.gz") as archive:
        pins = {
            m.name: hashlib.sha256(archive.extractfile(m).read()).hexdigest()
            for m in archive.getmembers()
            if m.isfile()
        }
    require(pins == plan["sources"], "archived source differs from the build plan")
    payload = plan.get("experiment", "notification") == "payload"
    orders = payload_schedule() if payload else schedule()
    require(
        plan["order"] == orders
        and plan["seed"] == (PAYLOAD_SEED if payload else SEED)
        and plan["total"] == (4097 if payload else TOTAL),
        "changed schedule",
    )
    idle = load(folder / "idle.json")
    if plan["load"] == "controlled":
        require(
            idle["idle_gate_passed"]
            and all(s["eligible"] and s["idle_pct"] >= 90 for s in idle["idle_observations"][-2:])
            and len(idle["idle_observations"]) >= 2,
            "host admission failed",
        )
    else:
        require(
            plan["load"] == "ambient"
            and len(idle["idle_observations"]) == 1
            and 0 <= idle["idle_pct"] <= 100,
            "missing natural-load sample",
        )
    raw = (folder / "windows.jsonl").read_bytes()
    require(hashlib.sha256(raw).hexdigest() == status["raw_sha256"], "changed measurements")
    records = [json.loads(line) for line in raw.splitlines()]
    expected = [config for block in orders for config in block]
    require(len(records) == len(expected), "missing first attempt")
    if payload:
        return payload_result(expected, records)
    measured = {}
    for config, r in zip(expected, records, strict=True):
        require(
            all(r[k] == v for k, v in config.items())
            and r["descriptors"] == TOTAL
            and r["data_exits"] == (TOTAL + r["batch"] - 1) // r["batch"]
            and r["completion_exits"] == 1
            and all(type(r[k]) is int and r[k] > 0 for k in ("wall_ns", "thread_cpu_ns", "vcpu_ns")),
            "unverified guest work, exit count or time",
        )
        measured[r["block"], r["transport"], r["batch"]] = r
    result = {}
    for batch in (1, 8):
        pairs = [(measured[n, "mmio", batch], measured[n, "hvc", batch]) for n in range(1, BLOCKS + 1)]
        ratios = [h["wall_ns"] / m["wall_ns"] for m, h in pairs]
        deltas = [(m["wall_ns"] - h["wall_ns"]) / m["data_exits"] for m, h in pairs]
        arm = {}
        for side, name in enumerate(("mmio", "hvc")):
            rows = [p[side] for p in pairs]
            arm[name] = {
                k: median(r[k] / r["data_exits"] for r in rows)
                for k in ("wall_ns", "thread_cpu_ns", "vcpu_ns")
            }
        result[str(batch)] = {
            "blocks": BLOCKS,
            "hvc_faster": sum(r < 1 for r in ratios),
            "ratio": median(ratios),
            "ratio_ci95": paired_median_interval(ratios),
            "wall_ns_saved_per_kick": median(deltas),
            "saving_ci95_ns": paired_median_interval(deltas),
            "ns_per_data_notification": arm,
        }
    return result


def payload_result(expected, records):
    from collections import defaultdict

    samples = defaultdict(dict)
    for cfg, r in zip(expected, records, strict=True):
        require(
            r["block"] == cfg["block"]
            and r["path"] == cfg["transport"]
            and r["verified"] is True
            and r["bytes"] == 4097 * 65536
            and r["frames"] == 4097
            and r["data_exits"] == 513
            and r["completion_exits"] == 1
            and r["sends"] >= r["frames"]
            and all(
                type(r[k]) is int and r[k] > 0
                for k in ("wall_ns", "sender_cpu_ns", "receiver_cpu_ns", "vcpu_ns")
            ),
            "payload, exit count or timer mismatch",
        )
        if r["block"]:
            gib = r["bytes"] / 2**30
            samples[r["path"]][r["block"]] = {
                "mib_s": r["bytes"] / 2**20 / (r["wall_ns"] / 1e9),
                "sender_cpu_s_per_gib": r["sender_cpu_ns"] / 1e9 / gib,
                "combined_cpu_s_per_gib": (r["sender_cpu_ns"] + r["receiver_cpu_ns"]) / 1e9 / gib,
            }
    ratios = {}
    arms = {}
    for key in ("mib_s", "sender_cpu_s_per_gib", "combined_cpu_s_per_gib"):
        changes = [samples["mapped"][i][key] / samples["staged"][i][key] for i in range(1, BLOCKS + 1)]
        ratios[key] = {"median": median(changes), "ci95": paired_median_interval(changes)}
        for name in ("staged", "mapped"):
            arms.setdefault(name, {})[key] = median(s[key] for s in samples[name].values())
    return {
        "blocks": BLOCKS,
        "scored_bytes_per_arm": BLOCKS * 4097 * 65536,
        "mapped_throughput_wins": sum(
            samples["mapped"][i]["mib_s"] > samples["staged"][i]["mib_s"] for i in range(1, BLOCKS + 1)
        ),
        "send_calls_range": [min(r["sends"] for r in records), max(r["sends"] for r in records)],
        "arm_medians": arms,
        "mapped_over_staged": ratios,
    }


def run(folder, check, load_policy, status, payload):
    order = payload_schedule() if payload else schedule()
    if check:
        order = order[:1]
    guest = SRC / ("payload.S" if payload else "guest.S")
    device = SRC / ("payload.c" if payload else "notify.c")
    sources = [HERE / "hardware.py", guest, device, SRC / "vm.c", SRC / "vm.h", BRIDGE]
    pins = {str(p.relative_to(ROOT)): terminal.digest(p) for p in sources}
    compiler = ["xcrun", "clang", "-arch", "arm64", "-O2", "-std=c11", "-Wall", "-Wextra", "-Werror"]
    with tempfile.TemporaryDirectory(prefix="mp-hvf-notify-") as tmp:
        build = Path(tmp)
        exe = build / "notify"
        subprocess.run(
            [*compiler, device, SRC / "vm.c", guest, BRIDGE, "-framework", "Hypervisor", "-o", exe],
            check=True,
        )
        ent = build / "entitlements.plist"
        ent.write_text(
            '<plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>'
        )
        terminal.invoke("codesign", "--force", "--sign", "-", "--entitlements", ent, exe)
        terminal.invoke("codesign", "--verify", "--strict", exe)
        require(
            all(terminal.digest(ROOT / key) == digest for key, digest in pins.items()),
            "source changed during build",
        )
        with (
            (folder / "sources.tar.gz").open("xb") as out,
            gzip.GzipFile(fileobj=out, mode="wb", mtime=0) as gz,
            tarfile.open(fileobj=gz, mode="w") as archive,
        ):
            for p in sources:
                data = p.read_bytes()
                entry = tarfile.TarInfo(str(p.relative_to(ROOT)))
                entry.size = len(data)
                archive.addfile(entry, io.BytesIO(data))
        terminal.save(
            folder / "plan.json",
            {
                "seed": PAYLOAD_SEED if payload else SEED,
                "order": order,
                "total": 4097 if payload else TOTAL,
                "experiment": "payload" if payload else "notification",
                "page_bytes": 16384,
                "vcpus": 1,
                "load": "functional" if check else load_policy,
                "host": terminal.invoke("hostname").stdout.strip(),
                "os": terminal.invoke("sw_vers").stdout.strip(),
                "cpu": terminal.invoke("sysctl", "-n", "machdep.cpu.brand_string").stdout.strip(),
                "hv_support": terminal.invoke("sysctl", "-n", "kern.hv_support").stdout.strip(),
                "sources": pins,
                "compiler": terminal.invoke("xcrun", "clang", "--version").stdout.strip(),
                "flags": compiler,
                "sdk": terminal.invoke("xcrun", "--show-sdk-version").stdout.strip(),
                "binary_sha256": terminal.digest(exe),
            },
        )
        with terminal.terminal_lock():
            admission = Admission(folder)
            admission.check(force=True)
            row = {}
            diagnostic = check or load_policy == "ambient"
            receiver.await_idle(
                row,
                None,
                diagnostic,
                0 if diagnostic else 180,
                receiver.path_pilot.cpu_idle,
                admission.check,
                lambda: terminal.save(folder / "idle.json", row),
            )
            stdin = "".join(
                f"{r['block']} {int(r['transport'] in ('hvc', 'mapped'))} {r['batch']}\n"
                for block in order
                for r in block
            )
            with (folder / "windows.jsonl").open("x") as out, (folder / "stderr.txt").open("x") as err:
                proc = subprocess.run(
                    [exe], input=stdin, text=True, stdout=out, stderr=err, timeout=60, check=False
                )
            status.update(process_exit=proc.returncode, raw_sha256=terminal.digest(folder / "windows.jsonl"))
            require(proc.returncode == 0, "HVF probe failed: " + (folder / "stderr.txt").read_text().strip())
            admission.check(force=True)
    status["temporary_build_removed"] = not build.exists()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true")
    group.add_argument("--run", action="store_true")
    group.add_argument("--replay", type=Path)
    parser.add_argument("--load", choices=("controlled", "ambient"), default="controlled")
    parser.add_argument(
        "--payload", action="store_true", help="use guest-generated 64 KiB frames and a Mac TCP receiver"
    )
    args = parser.parse_args()
    if args.replay:
        print(json.dumps(assess(args.replay), indent=2))
        sys.exit(0)
    action = "check" if args.check else "run"
    study = "tcp" if args.payload else "hvf"
    folder = Path(
        tempfile.mkdtemp(
            prefix=datetime.now(UTC).strftime(f"%Y%m%dT%H%M%SZ-{study}-") + action + "-", dir=HERE
        )
    )
    print(folder, flush=True)
    status = {"action": action, "complete": False, "start": terminal.now()}
    try:
        run(folder, args.check, args.load, status, args.payload)
        status["complete"] = True
    except (Exception, KeyboardInterrupt) as exc:
        status["error"] = str(exc) or type(exc).__name__
        raise
    finally:
        terminal.save(folder / "status.json", dict(status, ended=terminal.now()))
    if not args.check:
        summary = assess(folder)
        terminal.save(folder / "summary.json", summary)
        print(json.dumps(summary, indent=2))
