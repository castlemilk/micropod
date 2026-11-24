"""Observe the effect of an explicit serial queue QoS on two completion paths."""
import argparse
from hashlib import sha256
import json
from pathlib import Path
import random
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
PIN = "c0185aea5c04fcd4d1cfe9359e0066a380835403"
FILES = ["Sources/Containerization/VZVirtualMachineInstance.swift",
         "Sources/Containerization/VZVirtualMachine+Helpers.swift"]


def main(checkout):
    sources = [subprocess.check_output(["git", "-C", checkout, "show", f"{PIN}:{name}"])
               for name in FILES]
    assert b'self.queue = DispatchQueue(label: "com.apple.containerization.vzvm.' in sources[0]
    assert b'queue.sync {\n                self.start { result in' in sources[1]
    rng = random.Random(22802)
    arms = []
    for qos in [17, 25]:  # Darwin utility and userInitiated
        orders = [["unspecified", "explicit"]] * 4 + [["explicit", "unspecified"]] * 4
        rng.shuffle(orders)
        for pair, order in enumerate(orders, 1):
            arms.extend(f"{pair},{arm},{qos}" for arm in order)
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        stub, exe = work / "probe.o", work / "queue"
        subprocess.run(["clang", "-O2", "-Wall", "-Wextra", "-Werror", "-c",
                        HERE / "queue_probe.c", "-o", stub], check=True)
        subprocess.run(["swiftc", "-O", "-swift-version", "5", "-import-objc-header", HERE / "queue_probe.h",
                        HERE / "queue_handoff.swift", stub, "-o", exe], check=True)
        run = subprocess.run([exe, *arms], check=True, stdout=subprocess.PIPE, text=True)
    rows = [json.loads(line) for line in run.stdout.splitlines()]
    assert len(rows) == len(arms)
    print(json.dumps({"dependency": PIN, "dependency_files": dict(zip(FILES, [sha256(s).hexdigest() for s in sources])),
                      "fixture_sha256": {p: sha256((HERE / p).read_bytes()).hexdigest() for p in
                                       ["queue_probe.c", "queue_probe.h", "queue_handoff.swift", "queue_handoff.py"]},
                      "swift": subprocess.check_output(["swiftc", "--version"], text=True).strip(),
                      "attempts": rows}, indent=2))


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("containerization_checkout")
    main(p.parse_args().containerization_checkout)
