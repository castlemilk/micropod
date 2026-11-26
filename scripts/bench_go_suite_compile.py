"""Compare Go suite preparation against a Git revision using disposable offline caches."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SUITE = Path("ci/samples/go-app/ci-suite.sh")
PROFILE = {
    "GOENV": "off", "GOTOOLCHAIN": "local", "GOWORK": "off", "GOFLAGS": "-trimpath -p=2",
    "CGO_ENABLED": "0", "GOMAXPROCS": "2", "GOTELEMETRY": "off", "GOPROXY": "off",
    "GOSUMDB": "off",
}


def prepare(work):
    # Include a module root whose checkout basename differs from its import path.
    work.mkdir()
    (work / "go.mod").write_text("module example.test/suite\n\ngo 1.25\n")
    for i, name in enumerate([".", "cli", "db", "parser", "store", "worker"]):
        directory = work / name
        directory.mkdir(exist_ok=True)
        (directory / "payload").write_text(str(i))
        (directory / "suite_test.go").write_text(
            'package suite_test\nimport ("os"; "testing")\n'
            'func TestPayload(t *testing.T) { data, err := os.ReadFile("payload"); '
            f'if err != nil || string(data) != "{i}" {{ t.Fatal(data, err) }} }}\n'
        )


def run_suite(script, work, out, env):
    out.mkdir()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.perf_counter_ns()
    subprocess.run(["sh", script, "compile", out], cwd=work, env=env, check=True)
    elapsed = time.perf_counter_ns() - start
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
    run = subprocess.check_output(["sh", script, "test", out], cwd=work, env=env, text=True)
    if run.count("--- PASS: TestPayload") != 6:
        raise ValueError("expected six passing package tests")
    hashes = {}
    for file in sorted(out.rglob("*")):
        if file.is_file():
            hashes[str(file.relative_to(out))] = hashlib.sha256(file.read_bytes()).hexdigest()
    shutil.rmtree(out)
    return elapsed, round(cpu, 6), hashes


def compare(revision):
    baseline = subprocess.check_output(["git", "show", f"{revision}:{SUITE}"], cwd=ROOT)
    reference = subprocess.check_output(["git", "rev-parse", revision], cwd=ROOT, text=True).strip()
    with tempfile.TemporaryDirectory(prefix="micropod-go-suite-") as tmp:
        root = Path(tmp)
        work = root / "work tree"
        prepare(work)
        (root / "reference.sh").write_bytes(baseline)
        candidate = (ROOT / SUITE).read_bytes()
        (root / "candidate.sh").write_bytes(candidate)
        scripts = {"reference": root / "reference.sh", "candidate": root / "candidate.sh"}
        env = {**os.environ, **PROFILE, "GOMODCACHE": str(root / "modules")}
        tool = subprocess.check_output(["go", "env", "GOVERSION", "GOOS", "GOARCH"], env=env, text=True).splitlines()
        series = []
        expected = None
        # Each arm gets its own empty action cache before its first timed invocation.
        # Alternate arm order when timing an exact replay into a fresh suite directory.
        for trial in range(2):
            caches = {arm: root / f"cache-{trial}-{arm}" for arm in scripts}
            for iteration in range(4):
                order = list(scripts)
                if (trial + iteration) % 2:
                    order.reverse()
                for arm in order:
                    elapsed, cpu, hashes = run_suite(
                        scripts[arm], work, root / "suite", {**env, "GOCACHE": str(caches[arm])}
                    )
                    if expected is None:
                        expected = hashes
                    if hashes != expected:
                        raise ValueError(f"suite artifacts differ in {arm}")
                    series.append({
                        "trial": trial + 1, "iteration": iteration, "arm": arm,
                        "cache": "empty" if iteration == 0 else "warm", "elapsed_ns": elapsed, "child_cpu_s": cpu,
                    })
            for cache in caches.values():
                shutil.rmtree(cache)
        return {
            "reference": reference, "candidate_script_sha256": hashlib.sha256(candidate).hexdigest(),
            "go": tool, "host": platform.platform(), "profile": PROFILE,
            "method": "Six local test packages, cold then three warm rebuilds per independent arm and trial. "
                      "Elapsed wall time covers the entire suite compile command including vet and discovery. "
                      "Outside the clock, compare all artifact hashes and run each test from its package directory.",
            "samples": series, "output_sha256": expected,
        }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference")
    args = parser.parse_args()
    print(json.dumps(compare(args.reference), indent=2))
