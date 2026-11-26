"""Compile the pinned relay and two benchmark-only alternatives, then verify fixed-work cases."""
import argparse
import hashlib
import json
import platform
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
BASE = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
INPUTS = (
    "Sources/CPublishedTCP/PublishedTCP.c",
    "Sources/CPublishedTCP/include/PublishedTCP.h",
    "scripts/relaybench/filter_work.c",
)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(arm, patch, directory, sanitize):
    files = {}
    for source in INPUTS:
        content = subprocess.check_output(["git", "show", f"{BASE}:{source}"], cwd=ROOT)
        (directory / Path(source).name).write_bytes(content)
        files[source] = sha(content)
    if patch:
        subprocess.run(["patch", "-s", "-p1", "-i", str(HERE / patch)], cwd=directory, check=True)
        files[patch] = sha((HERE / patch).read_bytes())
    fixture = (HERE / "write_lowat.c").read_text()
    files["write_lowat.c"] = sha(fixture.encode())
    (directory / "fixture.c").write_text(fixture.replace(
        '"../../../../scripts/relaybench/filter_work.c"', '"filter_work.c"'))
    compiler = ["clang", "-O2", "-Wall", "-Wextra", "-Werror", "-fblocks",
                '-DRELAY_SOURCE="PublishedTCP.c"', "-I.", "fixture.c", "-o", "check"]
    if sanitize:
        compiler[1:1] = ["-fsanitize=address,undefined", "-fno-sanitize-recover=all"]
    subprocess.run(compiler, cwd=directory, check=True)
    rows = [json.loads(line) for line in subprocess.check_output(
        ["./check"], cwd=directory, timeout=12, text=True).splitlines()]
    cases = {(row["requested"], row["payload"], row["prefill"] > 0, row["send_capacity"], row["initial_room"]) for row in rows}
    expected = {(setting, size, pressure, 65536, 0) for setting in (0, 16384)
                for size in (1024, 20480, 32768) for pressure in (False, True)}
    expected.update({(8192, 20480, True, 65536, 0), (0, 32768, True, 8192, 0),
                     (0, 32768, True, 65536, 12288)})
    if len(rows) != len(expected) or cases != expected:
        raise ValueError("missing workload or duplicate observation")
    for row in rows:
        change = (arm == "adaptive_socket" and row["prefill"] and row["send_capacity"] >= 16384
                  and row["initial_pending"] >= 16384 and row["effective"] < 16384)
        if row["while_pending"] != (16384 if change else row["effective"]):
            raise ValueError(f"unexpected effective setting {row}")
        if row["verified_eofs"] != 2 or row["verified_marker"] != 1:
            raise ValueError("incomplete receiver verification")
    return {"inputs_sha256": files, "compiled_c_sha256": sha((directory / "PublishedTCP.c").read_bytes()),
            "flags": compiler[1:], "observations": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    arms = {}
    for arm, patch in (("stock", None), ("per_filter", "suffix-lowat.patch"),
                       ("adaptive_socket", "adaptive-socket.patch")):
        with tempfile.TemporaryDirectory() as directory:
            arms[arm] = run(arm, patch, Path(directory), args.sanitize)
    print(json.dumps({"base": BASE, "macOS": platform.mac_ver()[0], "arch": platform.machine(),
                      "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
                      "arms": arms}, indent=2))


if __name__ == "__main__":
    main()
