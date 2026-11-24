"""Run a functional native TCP comparison and preserve all first attempts."""
import hashlib
import json
from pathlib import Path
import platform
import random
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
BASE = "7bec8a7246f30e1a275f5d2c8568c53566d91490"
SRC = ROOT / "Sources/CPublishedTCP"
PINS = {
    SRC / "PublishedTCP.c": "f35e0245ebc1d394f748ea31ef03df180c70ad4a979925037ea063f7a2a08cee",
    SRC / "include/PublishedTCP.h": "e1996e8123fe678ae460b2bd18fb5f4a5af7457e022c26731fb426146c60bdb9",
}

def main():
    target = Path(sys.argv[1])
    for path, expected in PINS.items():
        assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, path
    order = list("AAAABBBB")
    random.Random(2301064).shuffle(order)
    order = "".join(order)
    with tempfile.TemporaryDirectory() as tmp:
        binary = Path(tmp) / "admission"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I", str(SRC), "-I", str(SRC / "include"),
                        str(HERE / "admission.c"), "-o", str(binary)], check=True)
        with target.open("xb") as raw:
            meta = dict(event="design", seed=2301064, order=order, micropod_base=BASE,
                        machine=platform.machine(), darwin=platform.release(), budget_bytes=65536,
                        compiler=subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
                        hashes={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in [*PINS, HERE / "admission.c", Path(__file__)]})
            raw.write((json.dumps(meta) + "\n").encode())
            raw.flush()
            run = subprocess.run([binary, order], stdout=raw, stderr=subprocess.PIPE)
            status = dict(event="exit", status=run.returncode, stderr=run.stderr.decode())
            raw.write((json.dumps(status) + "\n").encode())
            run.check_returncode()

if __name__ == "__main__":
    main()
