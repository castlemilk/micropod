"""Build the three checksum-pinned Phase 0 observers from this checkout, fully offline."""
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

import fresh_samples
from gamma_contrasts import ROOT, read_receipt
from gamma_pilot import HASHES
from host_role import CLIENT_SHA256, GUEST_PROBE_SHA256


def build(destination, *, paired_fresh=False):
    if destination.exists():
        raise FileExistsError(f"choose a new tools directory: {destination}")
    archive = ROOT / "docs/benchmarks/2026-11-21/gamma-direct-macvlan.json.gz"
    receipt = read_receipt(archive, "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976")
    expected = {"fixed": fresh_samples.CLIENT_SHA256 if paired_fresh else CLIENT_SHA256, "rusage": HASHES["rusage"], "netbench": GUEST_PROBE_SHA256}
    with tempfile.TemporaryDirectory(dir=destination.parent) as temp:
        work = Path(temp).resolve()
        tools = work / "tools"
        tools.mkdir()
        (work / "host-rusage.c").write_text(receipt["sources"]["host-rusage.c"])
        # The relative C input and output names reproduce the original Mach-O UUID and signing identity.
        subprocess.run(["xcrun", "clang", "-O2", "host-rusage.c", "-o", "host-rusage"], cwd=work, check=True)
        (work / "host-rusage").rename(tools / "rusage")
        env = dict(os.environ, CGO_ENABLED="0", GOARM64="v8.0", GOARCH="arm64", GOFLAGS="-trimpath", GOENV="off",
                   GOTOOLCHAIN="local", GOPROXY="off", GOWORK="off")
        for name, target, source in (("fixed", "darwin", "offered/main.go"), ("netbench", "linux", "main.go")):
            overlay = []
            if name == "fixed" and paired_fresh:
                original = ROOT / "scripts/netbench" / source
                patched = work / "offered-paired.go"
                subprocess.run(["patch", "-s", "-F", "0", "-o", patched, original,
                                ROOT / "scripts/relaybench/fresh_samples.patch"], check=True)
                overlay_file = work / "overlay.json"
                overlay_file.write_text(json.dumps({"Replace": {str(original): str(patched)}}))
                overlay = ["-overlay", str(overlay_file)]
            subprocess.run(["go", "build", *overlay, "-p", "2", "-trimpath", "-buildvcs=false", "-ldflags=-buildid=",
                            "-o", tools / name, "scripts/netbench/" + source], cwd=ROOT,
                           env=dict(env, GOOS=target), check=True)
        for name, checksum in expected.items():
            observed = hashlib.sha256((tools / name).read_bytes()).hexdigest()
            if observed != checksum:
                raise ValueError(f"{name}: got {observed}, expected {checksum}. Check the compiler versions.")
        tools.rename(destination)
    return expected


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--paired-fresh", action="store_true",
                        help="build the read-size diagnostic that retains timing and outcome for every fresh request")
    args = parser.parse_args()
    try:
        print(json.dumps(build(args.destination.resolve(), paired_fresh=args.paired_fresh), indent=2))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Could not prepare host-role tools: {error}\n")
