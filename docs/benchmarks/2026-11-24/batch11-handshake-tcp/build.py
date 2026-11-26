"""Build both arms against the exact same two-owner Darwin relay source."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

here = Path(__file__).resolve().parent
repo = here.parents[3]
revision = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def build(dest, shared):
    dest.mkdir(exist_ok=False)
    files = ["Sources/CPublishedTCP/PublishedTCP.c", "Sources/CPublishedTCP/include/PublishedTCP.h",
             "Sources/MicropodRuntime/NativeLoopbackRelay.swift"]
    for filename in files:
        source = subprocess.check_output(["git", "-C", repo, "show", revision + ":" + filename])
        (dest / Path(filename).name).write_bytes(source)
    (dest / "module.modulemap").write_text('module CPublishedTCP { header "PublishedTCP.h" export * }\n')
    shutil.copy2(here / "TCPRelayProbe.swift", dest)
    for name in ["suite.py", "fixed", "server", "meter.dylib"]:
        shutil.copy2(shared / name, dest / name)
    fingerprint = json.loads((here.parent / "batch11-host-hot-wait/diagnostic-first/receipt.json").read_text())["file_sha256"]
    for name in ["suite.py", "fixed", "server", "meter.dylib"]:
        if sha(dest/name) != fingerprint[name]:
            raise ValueError("shared fixture differs: " + name)
    commands = []
    for arm in [0, 1]:
        commands.extend([
            ["xcrun", "clang", "-O3", "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-I.", "-c",
              f"-DMICROPOD_BENCH_DEFER_HANDSHAKE_READS={arm}", "PublishedTCP.c", "-o", f"relay-{arm}.o"],
            ["xcrun", "swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(dest / "modules"),
              "-I.", "NativeLoopbackRelay.swift", "TCPRelayProbe.swift", f"relay-{arm}.o", "-o", f"relay-{arm}"]])
    for command in commands:
        subprocess.run(command, cwd=dest, check=True)
    return {"revision": revision, "commands": commands, "files": {p.name:sha(p) for p in dest.iterdir() if p.is_file()}}
if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("new_build",type=Path)
    parser.add_argument("shared", type=Path, help="compiled batch11-host-hot-wait fixture directory")
    args=parser.parse_args()
    print(json.dumps(build(args.new_build.resolve(),args.shared.resolve()),indent=2))
