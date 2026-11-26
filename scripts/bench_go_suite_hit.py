"""Replay exact prepared-image hits against two host scripts, with offline endpoint and Docker responses."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
from statistics import median
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path("ci/prepare-go-suite.sh")
SUITE = Path("ci/samples/go-app/ci-suite.sh")
SOURCE = "sha256:" + "1" * 64
IMAGE = "sha256:" + "a" * 64

# Only implement the exact label-bearing image inspection used by reuse().
# Every other Docker or micropod operation fails, including starting a compiler.
DOCKER = """#!/bin/sh
set -eu
test "$1" = --host && test "$2" = "unix://$FIXTURE/docker.sock" || exit 3
test "$3 $4 $5" = 'image inspect --format' || exit 3
if [ "$6" != '{{.Id}} {{index .Config.Labels "io.micropod.ci.go-suite"}}' ]; then exit 3; fi
key=${7#micropod-internal/ci-go-suite:}
test "$key" != "$7" && test "${#key}" = 64 || exit 3
if [ "${MISS_ONCE:-}" ] && [ ! -f "$FIXTURE/missed" ]; then
    : > "$FIXTURE/missed"
    exit 1
fi
printf '%s %s\\n' "$IMAGE" "${STORED_KEY:-$key}"
"""
CLI = """#!/bin/sh
test "$*" = 'ci endpoint' || exit 3
echo "unix://$FIXTURE/docker.sock"
"""


def compare(reference):
    revision = subprocess.check_output(["git", "rev-parse", reference + "^{commit}"], cwd=ROOT, text=True).strip()
    original = subprocess.check_output(["git", "show", f"{revision}:{SCRIPT}"], cwd=ROOT)
    suite = (ROOT / SUITE).read_bytes()
    with tempfile.TemporaryDirectory(prefix="mp-go-hit-") as temp:
        root = Path(temp)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name, code in (("docker", DOCKER), ("micropod", CLI)):
            file = bin_dir / name
            file.write_text(code)
            file.chmod(0o755)
        env = {"PATH": str(bin_dir) + os.pathsep + os.defpath + ":/sbin:/usr/sbin",
               "MICROPOD_BIN": str(bin_dir / "micropod"), "FIXTURE": temp, "IMAGE": IMAGE, "LC_ALL": "C"}
        # Use a host-independent fallback PATH without sha256sum to exercise older installations.
        fallback = root / "fallback"
        fallback.mkdir()
        for name in ("docker", "dirname", "cat", "shasum"):
            (fallback / name).symlink_to(shutil.which(name, path=env["PATH"]))
        candidate = (ROOT / SCRIPT).read_bytes()
        scripts = {}
        for arm, code in (("baseline", original), ("candidate", candidate)):
            script = root / arm / SCRIPT
            copy = root / arm / SUITE
            copy.parent.mkdir(parents=True)
            copy.write_bytes(suite)
            script.write_bytes(code)
            scripts[arm] = script

        def hit(arm, args, extra=None):
            start = time.perf_counter_ns()
            p = subprocess.run(["/bin/bash", scripts[arm], *args], capture_output=True, text=True,
                               env={**env, **(extra or {})}, timeout=5)
            elapsed = time.perf_counter_ns() - start
            p.check_returncode()
            event = json.loads(p.stderr)
            assert p.stdout == IMAGE + "\n" and event == {
                "event": "ci.go.suite", "cache": "hit", "key": event["key"], "image": IMAGE, "publication": None}
            return elapsed, event["key"]

        inputs = [SOURCE, "warm-suite", "."]
        keys = []
        for args in (inputs, [SOURCE, "warm-suite-2", "."], [SOURCE, "warm-suite", "./cmd/with spaces"],
                     ["sha256:" + "2" * 64, "warm-suite", "."]):
            _, existing = hit("baseline", args)
            assert hit("candidate", args, {"STORED_KEY": existing})[1] == existing
            assert hit("candidate", args, {"STORED_KEY": existing, "PATH": str(fallback)})[1] == existing
            keys.append(existing)
        assert len(set(keys)) == len(keys)
        assert not (root / "go-preparation-locks").exists()  # Every exact hit bypassed the preparation lock.
        assert hit("candidate", inputs, {"MISS_ONCE": "1", "STORED_KEY": keys[0]})[1] == keys[0]
        assert (root / "missed").exists() and (root / "go-preparation-locks" / keys[0][:3]).exists()
        candidate_suite = root / "candidate" / SUITE
        candidate_suite.write_bytes(suite + b"\n")
        assert hit("candidate", inputs)[1] not in keys
        candidate_suite.write_bytes(suite)
        failed = subprocess.run(["/bin/bash", scripts["candidate"], *inputs], env={**env, "STORED_KEY": keys[1]},
                                capture_output=True, timeout=5)
        assert failed.returncode != 0 and not failed.stdout and b"ci.go.suite" not in failed.stderr

        samples = []
        for i in range(24):
            order = ("baseline", "candidate") if i % 2 == 0 else ("candidate", "baseline")
            row = {"order": list(order)}
            for arm in order:
                elapsed, key = hit(arm, inputs, {"STORED_KEY": keys[0]})
                assert key == keys[0]
                row[arm] = elapsed
            samples.append(row)
        changes = [100 * (row["candidate"] / row["baseline"] - 1) for row in samples]
        rng = random.Random(23820)
        distribution = sorted(median(rng.choices(changes, k=len(changes))) for _ in range(10000))
        return {"base": revision, "host": platform.platform(), "suite_sha256": hashlib.sha256(suite).hexdigest(),
                "preparer_sha256": {arm: hashlib.sha256(p.read_bytes()).hexdigest() for arm, p in scripts.items()},
                "digest_tools": {k: shutil.which(k, path=env["PATH"]) for k in ("shasum", "sha256sum")},
                "method": "24 alternating pairs. Time the entire host bash preparer with a scripted endpoint "
                          "and a fixed label-bearing image-inspect response. No VM, Docker engine or worker timings.",
                "verified": ["existing keys for source, scope and main", "shasum fallback", "changed suite bytes",
                             "exact hit skips lock", "reuse after lock", "wrong label rejects hit"],
                "existing_cache_key": keys[0], "samples_ns": samples,
                "median_ms": {arm: round(median(r[arm] for r in samples) / 1e6, 3) for arm in scripts},
                "median_paired_change_pct": round(median(changes), 2),
                "paired_bootstrap_ci95_pct": [round(distribution[249], 2), round(distribution[9749], 2)]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference")
    print(json.dumps(compare(parser.parse_args().reference), indent=2))
