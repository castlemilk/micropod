"""Run only the private vmnet configuration fixture. No live network, attachment, interface or VM."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
TREE = HERE.parents[3]
BASE = "86ca2713a0791d26c137e9a8c6385e1b6bd04ebb"
FILES = ("Sources/MicropodRuntime/SandboxVM.swift", "Sources/MicropodRuntime/SandboxNetwork.swift")


def run(*cmd, **kwargs):
    return subprocess.check_output(cmd, text=True, **kwargs)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(output):
    output.mkdir(exist_ok=False)
    sdk = Path(run("xcrun", "--sdk", "macosx", "--show-sdk-path").strip())
    framework = sdk / "System/Library/Frameworks/vmnet.framework"
    header = framework / "Headers/vmnet.h"
    stub = framework / "vmnet.tbd"
    with tempfile.TemporaryDirectory() as temp:
        tmp = Path(temp)
        for name in FILES:
            path = tmp / name
            path.parent.mkdir(exist_ok=True, parents=True)
            path.write_bytes(subprocess.check_output(["git", "-C", TREE, "show", f"{BASE}:{name}"]))
        initial = {name: sha(tmp / name) for name in FILES}
        run("patch", "-F", "0", "-p1", "-i", str(HERE / "published-mtu.patch"), cwd=tmp)
        run("xcrun", "swiftc", "-frontend", "-parse", *(str(tmp / name) for name in FILES))
        cli = tmp / "probe"
        run("xcrun", "swiftc", "-module-cache-path", str(tmp / "modules"), "-sdk", str(sdk),
            HERE / "PublishedMTUBenchmark.swift", HERE / "control.swift", "-o", cli)
        proc = subprocess.run([cli], capture_output=True)
        (output / "requests.json").write_bytes(proc.stdout)
        (output / "stderr.txt").write_bytes(proc.stderr)
        proc.check_returncode()
        observations = json.loads(proc.stdout)
        expected = [("host", None, None), ("host", "1500", 1500), ("host", "9000", 9000),
                    ("host", "9001", None), ("shared", "9000", None)]
        assert [(r["mode"], r.get("request"), r.get("acceptedRequest")) for r in observations] == expected
        assert all(r["configCreated"] for r in observations)
        assert [r["outcome"].startswith("rejected:") for r in observations] == [False, False, False, True, True]
        manifest = {"direction": "229.01", "classification": "operator preparation, no experiment count",
                    "tier": "source/fixture", "stock_runtime_revision": BASE,
                    "fixture_checkout": run("git", "-C", TREE, "rev-parse", "HEAD").strip(),
                    "macOS": platform.mac_ver()[0], "SDK": str(sdk), "swift": run("xcrun", "swiftc", "--version").strip(),
                    "framework_header_sha256": sha(header), "framework_abi_stub_sha256": sha(stub),
                    "unmodified_stock_files": initial, "private_patched_files": {f: sha(tmp / f) for f in FILES},
                    "inputs": {n: sha(HERE / n) for n in ("check.py", "published-mtu.patch", "PublishedMTUBenchmark.swift", "control.swift")},
                    "raw_sha256": sha(output / "requests.json"), "executable_sha256": sha(cli),
                    "configuration_only": True, "networks_or_VMs_created": 0, "throughput_MiB_s": None,
                    "DF_or_MSS_verified": False, "executed_pid": os.getpid()}
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("new_output", type=Path)
    check(parser.parse_args().new_output.resolve())
