"""Compare guest Docker spool replay on the host using fixed, byte-verified file sections."""
import argparse
from datetime import datetime, timezone
import hashlib
import itertools
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
BASE = "dc019c8c"
SOURCE = ROOT / "guest/runner/docker_stream_frames.go"
TEST = SOURCE.with_name("docker_stream_frames_test.go")
PATTERN = re.compile(r"^BenchmarkCopyDockerFrames/(\S+)\s+32\s+([\d.]+) ns/op\s+([\d.]+) MB/s\s+(\d+) B/op\s+(\d+) allocs/op$", re.M)


def run(go):
    revision = subprocess.check_output(["git", "rev-parse", BASE + "^{commit}"], cwd=ROOT, text=True).strip()
    old = subprocess.check_output(["git", "show", revision + ":guest/runner/docker_http_linux.go"], cwd=ROOT, text=True)
    start = old.index("func copyFrames(")
    end = old.index("func (s *dockerEngine) images(", start)
    original = 'package main\nimport ("bufio"; "encoding/binary"; "io")\n' + old[start:end]
    candidate = SOURCE.read_text()
    # This third arm has the same complete-frame path and streaming fallback.
    # Remove only the scan for further buffered frames in the same selection.
    begin = candidate.index("\t\t\tfor len(buffer)-end >= headerSize {")
    finish = candidate.index("\t\t\tif emit {", begin)
    single = candidate[:begin] + candidate[finish:]
    sources = {"base": original.encode(), "single": single.encode(), "candidate": candidate.encode()}
    blocks = []
    with tempfile.TemporaryDirectory(prefix="mp-frames-") as work:
        work = Path(work)
        env = dict(os.environ, GOENV="off", GOWORK="off", GO111MODULE="off", GOTOOLCHAIN="local", GOPROXY="off",
                   GOMAXPROCS="1", GOCACHE=str(work / "cache"), GOTELEMETRY="off")
        env.pop("GOROOT", None)
        programs = {}
        for name, code in sources.items():
            src = work / name
            src.mkdir()
            (src / "frames.go").write_bytes(code)
            (src / "frames_test.go").write_bytes(TEST.read_bytes())
            exe = src / "frames.test"
            subprocess.run([go, "test", "-c", "-trimpath", "-o", exe], cwd=src, env=env, check=True)
            subprocess.run([exe, "-test.run", "^TestStreamFrame"], env=env, stdout=subprocess.DEVNULL, check=True)
            if name != "base":
                subprocess.run([exe, "-test.run", "^TestShortFrameWriter$"], env=env, stdout=subprocess.DEVNULL, check=True)
            programs[name] = exe
        permutations = list(itertools.permutations(sources))
        for i in range(13):
            order = list(sources) if not i else permutations[(i - 1) % 6]
            block = {"order": order}
            for arm in order:
                stdout = subprocess.check_output([programs[arm], "-test.run", "^$", "-test.cpu", "1", "-test.bench",
                                                  "^BenchmarkCopyDockerFrames$", "-test.benchtime", "32x"],
                                                 env=env, text=True)
                rows = {n: [float(ns), float(mbs), int(size), int(allocs)]
                        for n, ns, mbs, size, allocs in PATTERN.findall(stdout)}
                if len(rows) != 7:
                    raise ValueError(stdout)
                block[arm] = rows
            if i:
                blocks.append(block)
        version = subprocess.check_output([go, "version"], text=True, env=env).strip()
    summary = {}
    for name in blocks[0]["base"]:
        outcomes = {arm: [block[arm][name] for block in blocks] for arm in sources}
        summary[name] = {arm: [round(statistics.median(column), 3) for column in zip(*rows)]
                         for arm, rows in outcomes.items()}
        for control in ("base", "single"):
            ratios = [b[0] / c[0] for b, c in zip(outcomes[control], outcomes["candidate"])]
            rng = random.Random(790)
            draws = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
            summary[name][f"grouped_vs_{control}"] = dict(median_paired_rate_ratio=round(statistics.median(ratios), 4),
                                                         bootstrap_95=[round(draws[249], 4), round(draws[9749], 4)],
                                                         faster_blocks=sum(r > 1 for r in ratios))
    sha = lambda data: hashlib.sha256(data).hexdigest()
    return {"base_commit": revision, "go": version, "host": platform.platform(), "completed_utc": datetime.now(timezone.utc).isoformat(),
            "source_sha256": {arm: sha(data) for arm, data in sources.items()}, "fixture_sha256": sha(TEST.read_bytes()),
            "driver_sha256": sha(Path(__file__).read_bytes()),
            "method": "One unscored warmup per arm, then twelve blocks with all six orders twice, Go on one CPU. Each cell reads "
                      "32 identical private file sections through a 4096-byte bufio.Reader, forwards selected "
                      "Docker frames to a buffered bytes.Buffer, flushes and compares every byte. 3:1 stdout/stderr "
                      "frames. MB/s counts selected wire bytes. Measurements include cached file I/O, memory writes "
                      "and byte comparison. The fixture excludes guest, HTTP transport, log production and scheduling.",
            "row_units": ["ns/op", "selected decimal MB/s", "B/op", "allocs/op"], "summary": summary, "blocks": blocks}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go", default="go")
    print(json.dumps(run(parser.parse_args().go), indent=2))
