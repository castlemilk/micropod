"""Compile the pinned Darwin socket setup and retain every first-attempt row."""
import argparse
import hashlib
from pathlib import Path
import random
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
SOURCES = {
    ROOT / "Sources/CPublishedTCP/PublishedTCP.c": "f35e0245ebc1d394f748ea31ef03df180c70ad4a979925037ea063f7a2a08cee",
    ROOT / "Sources/CPublishedTCP/include/PublishedTCP.h": "e1996e8123fe678ae460b2bd18fb5f4a5af7457e022c26731fb426146c60bdb9",
    HERE / "darwin_socket_paths.c": "babc228c7e0105d921ad9861daf640acf5984b98b2765676753fe22fd760406c",
}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=("pending", "reuse"))
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    for path, expected in SOURCES.items():
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"source hash changed in {path.name}")
    order = list("A" * 8 + "B" * 8)
    random.Random({"pending": 23010, "reuse": 23012}[args.case]).shuffle(order)
    with tempfile.TemporaryDirectory() as tmp:
        program = Path(tmp) / "socket_paths"
        src = ROOT / "Sources/CPublishedTCP"
        subprocess.run(["clang", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I", str(src), "-I", str(src / "include"),
                        str(HERE / "darwin_socket_paths.c"), "-o", str(program)], check=True)
        with args.output.open("xb") as out:
            subprocess.run([program, args.case, "".join(order)], stdout=out, check=True)

if __name__ == "__main__":
    main()
