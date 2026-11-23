"""Pair the stock and candidate CRI log decoders on the same local Go toolchain."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path("guest/runner/output_linux.go")
TEST = ROOT / "guest/runner/cri_output_linux_test.go"
BASE = "04d4899a20c352f4022185f1cf616ab4fa1401e1"
ROW = re.compile(r"^BenchmarkCRIDrain/(\S+)\s+32\s+([\d.]+) ns/op\s+([\d.]+) MB/s\s+(\d+) B/op\s+(\d+) allocs/op$", re.M)
CASES = {size + "/" + sink for size in ("one", "ci", "oversized") for sink in ("streams", "json")}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def prepare(work, go):
    env = dict(os.environ, GO111MODULE="off", GOWORK="off", GOPROXY="off", GOTOOLCHAIN="local",
               CGO_ENABLED="0", GOMAXPROCS="1", GOTELEMETRY="off", GOCACHE=str(work / "cache"))
    env.pop("GOROOT", None)
    stock = subprocess.check_output(["git", "show", f"{BASE}:{SOURCE}"], cwd=ROOT)
    sources = {"stock": stock, "candidate": (ROOT / SOURCE).read_bytes()}
    report = {"base": BASE, "go": subprocess.check_output([go, "version"], text=True, env=env).strip(),
              "host": platform.platform(), "source_sha256": {k: digest(v) for k, v in sources.items()},
              "fixture_sha256": digest(TEST.read_bytes()), "driver_sha256": digest(Path(__file__).read_bytes())}
    for arm, data in sources.items():
        body = data[data.index(b"type outputSink "):data.index(b"func (n node) follow(")]
        folder = work / arm
        folder.mkdir()
        # Compile the exact platform-independent production functions on this host.
        (folder / "cri.go").write_bytes(b'package main\nimport ("bufio"; "bytes"; "encoding/json"; "errors"; "io")\n' + body)
        (folder / "cri_test.go").write_bytes(TEST.read_bytes())
        subprocess.run([go, "test", "-c", "-p=1", "-trimpath", "-o", "cri.test"], cwd=folder,
                       env=env, check=True)
        subprocess.run([folder / "cri.test", "-test.run", "^TestCRIOutput", "-test.v"], env=env,
                       check=True, stdout=subprocess.DEVNULL)
    return env, report


def measure(work, env, report):
    rng = random.Random(34117)
    orders = [["stock", "candidate"], ["candidate", "stock"]] * 6
    rng.shuffle(orders)
    blocks = []
    for number, order in enumerate([["stock", "candidate"], *orders]):
        block = {"order": order}
        for arm in order:
            raw = subprocess.check_output([work / arm / "cri.test", "-test.run", "^$", "-test.cpu", "1",
                                           "-test.bench", "^BenchmarkCRIDrain$", "-test.benchtime", "32x"],
                                          text=True, env=env)
            rows = {name: [float(ns), float(mbps), int(size), int(allocs)]
                    for name, ns, mbps, size, allocs in ROW.findall(raw)}
            if set(rows) != CASES:
                raise ValueError(raw)
            block[arm] = rows
        if number:
            blocks.append(block)
    summary = {}
    for name in sorted(CASES):
        ratios = [b["stock"][name][0] / b["candidate"][name][0] for b in blocks]
        boot = sorted(statistics.median(rng.choices(ratios, k=len(blocks))) for _ in range(10000))
        arms = {arm: [statistics.median(col) for col in zip(*(b[arm][name] for b in blocks))]
                for arm in ("stock", "candidate")}
        summary[name] = dict(**arms, paired_speedup=statistics.median(ratios),
                             bootstrap_95=[boot[249], boot[9749]], wins=sum(x > 1 for x in ratios))
    return dict(**report, completed_utc=datetime.now(timezone.utc).isoformat(),
                method="32 decodes per arm per case, one warmup block, 12 randomized balanced paired blocks. "
                       "Each decode reads an identical private file section through the production 32 KiB reader, "
                       "writes all stdout/stderr bytes or the production JSON wire stream and verifies exact output. "
                       "Includes cached file reads, parsing, writing to preallocated memory and bytes comparison. "
                       "Excludes the live guest, CRI status polling, container log generation and network delivery.",
                units=["ns/op", "decimal input MB/s", "B/op", "allocs/op"], summary=summary, blocks=blocks)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go", default="go")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        env, report = prepare(work, args.go)
        print(json.dumps(measure(work, env, report), indent=2))
