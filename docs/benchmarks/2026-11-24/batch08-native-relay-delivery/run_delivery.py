"""Run the unchanged published loopback TCP relay with one explicit consumer decision."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import random
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
SOURCE = Path("Sources/CPublishedTCP/PublishedTCP.c")
HEADER = Path("Sources/CPublishedTCP/include/PublishedTCP.h")
BASE = "7bec8a7246f30e1a275f5d2c8568c53566d91490"
SEED = 2300724


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(output):
    order = [["consume", "pause"], ["pause", "consume"]] * 2
    random.Random(SEED).shuffle(order)
    identities = {}
    for path in [SOURCE, HEADER]:
        pinned = subprocess.check_output(["git", "show", f"{BASE}:{path}"], cwd=ROOT)
        current = (ROOT / path).read_bytes()
        if pinned != current:
            raise SystemExit(f"source differs from {BASE}:{path}")
        identities[str(path)] = digest(current)
    for name in ["delivery.c", "run_delivery.py"]:
        identities[name] = digest((HERE / name).read_bytes())
    record = dict(direction="230.07", evidence_tier="local/host-only", date="2026-11-24",
                  source_revision=BASE, sha256=identities, host=platform.uname().system,
                  kernel=platform.release(), arch=platform.machine(),
                  compiler=subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
                  ordering_seed=SEED, arm_order_by_pair=order, attempts=[])
    with tempfile.TemporaryDirectory() as tmp:
        binary = Path(tmp) / "delivery"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I", str((ROOT / HEADER).parent), str(ROOT / SOURCE), str(HERE / "delivery.c"),
                        "-o", str(binary)], check=True)
        record["executable_sha256"] = digest(binary.read_bytes())
        with output.open("x") as raw:
            def persist():
                raw.seek(0)
                json.dump(record, raw, indent=2)
                raw.write("\n")
                raw.truncate()
                raw.flush()
            persist()
            for pair, policies in enumerate(order, 1):
                for policy in policies:
                    proc = subprocess.run([str(binary), policy, str(pair)], capture_output=True, text=True)
                    row = dict(pair=pair, policy=policy, exit=proc.returncode,
                               stdout=proc.stdout, stderr=proc.stderr)
                    record["attempts"].append(row)
                    persist()
                    if proc.returncode:
                        raise SystemExit(f"stopped at first failed attempt ({proc.returncode}): {proc.stderr}")
                    row["observation"] = json.loads(proc.stdout)
                    persist()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path, help="new raw receipt path")
    run(parser.parse_args().output)
