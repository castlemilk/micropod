"""Compare only /id marker serialization over one warmed, in-memory HTTP/1.1 connection."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = "4dc985b50bbd1e5942020618df4d8dcc2de47483"
FIXTURE = Path(__file__).with_name("quiet_marker") / "fixture.go.in"
SOURCE = "scripts/netbench/main.go"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def compile_arms(go, source, tmp, env):
    start = source.index("mux := http.NewServeMux()")
    mux = source[start:source.index("server := &http.Server", start)].strip()
    old = "mux.HandleFunc(\"/id\", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, id) })"
    new = "markerBytes := []byte(id)\n\tmux.HandleFunc(\"/id\", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(markerBytes) })"
    if mux.count(old) != 1:
        raise ValueError("unexpected /id implementation")
    template = FIXTURE.read_text()
    binaries, digests = {}, {}
    for arm, handler in [("base", mux), ("candidate", mux.replace(old, new))]:
        dest = tmp / (arm + ".go")
        exe = tmp / arm
        dest.write_text(template.replace("// INSERT_PINNED_MUX", handler))
        subprocess.run([go, "build", "-p=1", "-trimpath", "-o", exe, dest], env=env, check=True)
        binaries[arm] = exe
        digests[arm] = dict(compiled_source=sha(dest.read_bytes()), binary=sha(exe.read_bytes()))
    return binaries, digests


def metric(raw, key):
    if key == "ns_per_request":
        return raw["elapsed_ns"] / raw["complete"]
    durations = sorted(raw["after_warmup_ns"])
    return durations[math.ceil(len(durations)*{"p50_ns":.5, "p95_ns":.95, "p99_ns":.99}[key])-1]


def summarize(blocks):
    result = {}
    for key in ("ns_per_request", "p50_ns", "p95_ns", "p99_ns"):
        base, candidate = ([metric(b["rows"][arm], key) for b in blocks] for arm in ("base", "candidate"))
        ratios = [c / a for a, c in zip(base, candidate)]
        rng = random.Random(2311501)
        draws = sorted(statistics.median(rng.choices(ratios, k=len(ratios))) for _ in range(10000))
        result[key] = dict(base=statistics.median(base), candidate=statistics.median(candidate),
                           median_paired_ratio=statistics.median(ratios), ci95=[draws[249],draws[9749]],
                           faster_pairs=sum(r < 1 for r in ratios))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--go", default="go")
    args = parser.parse_args()
    source = subprocess.check_output(["git", "show", f"{BASE}:{SOURCE}"], cwd=ROOT)
    with tempfile.TemporaryDirectory(prefix="mp-quiet-marker-") as scratch:
        tmp = Path(scratch)
        env = dict(os.environ, GOENV="off", GOWORK="off", GO111MODULE="off", GOTOOLCHAIN="local",
                   GOPROXY="off", GOSUMDB="off", GOTELEMETRY="off", CGO_ENABLED="0", GOMAXPROCS="1",
                   GOCACHE=os.environ.get("GOCACHE", str(tmp/"cache")))
        env.pop("GOROOT", None)
        binaries, digests = compile_arms(args.go, source.decode(), tmp, env)
        orders = [["base", "candidate"], ["candidate", "base"]] * 8
        random.Random(2311501).shuffle(orders)
        blocks = []
        for order in orders:
            rows = {}
            for arm in order:
                proc = subprocess.run([binaries[arm]], env=env, capture_output=True, text=True, timeout=15)
                row = json.loads(proc.stdout)
                row["exit_code"] = proc.returncode
                rows[arm] = row
            blocks.append(dict(order=order, rows=rows))
        clean = all(row["exit_code"] == 0 and row["complete"] == row["attempted"] == 200
                    and len(row["after_warmup_ns"]) == 200 for b in blocks for row in b["rows"].values())
        receipt = dict(stable_id="231.15", control=BASE, source_path=SOURCE,
                       service_sha256=sha(source), compiled=digests, fixture_sha256=sha(FIXTURE.read_bytes()),
                       driver_sha256=sha(Path(__file__).read_bytes()), go=subprocess.check_output(
                           [args.go, "version"], env=env, text=True).strip(), host=platform.platform(),
                       scope="Actual benchmark service mux and net/http server; supplied net.Pipe on native host. "
                             "Fresh process and one warmup, then 200 sequential GET /id on the identical connection. "
                             "Verified HTTP/1.1, status, content type, exact length and marker for every response.",
                       changed="Pre-encode the constant per-listener marker instead of fmt.Fprint for each /id.",
                       design="16 random-order counterbalanced pairs (seed 2311501). GOMAXPROCS=1. Per-arm quantiles "
                              "are nearest rank; paired ratio interval uses a 10,000-resample median bootstrap, same seed.",
                       clean=clean, summary=summarize(blocks) if clean else None, blocks=blocks)
        print(json.dumps(receipt, separators=(",", ":")))
        if not clean:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
