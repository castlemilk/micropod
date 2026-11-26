"""Reproduce a fixed-work local comparison into a new JSON file."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
REV = "17bcd4355234b11da3a7a1da2ded52f4dc20f5d1"
RELAY = "Sources/CPublishedTCP/PublishedTCP.c"
INCLUDE = "Sources/CPublishedTCP/include/PublishedTCP.h"
SUPPORT = "scripts/relaybench/filter_work.c"

def digest(data):
    return hashlib.sha256(data).hexdigest()

def stock(path):
    return subprocess.check_output(["git", "show", f"{REV}:{path}"], cwd=ROOT)

def resume_policy(source):
    old = b"if (update_stream_filters(r, changes, 2) < 0) retire(p);\n    }\n}\n\nstatic void pump("
    new = old.replace(b"retire(p);", b"retire(p);\n        else pump_ready(src, dst, NULL, OTHER_EVENT);")
    assert source.count(old) == 1
    return source.replace(old, new)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("experiment", choices=["worker_assignment", "resume_read"])
    p.add_argument("output", type=Path)
    opt = p.parse_args()
    if opt.output.exists():
        raise SystemExit("Supply an unused output path")
    control = stock(RELAY)
    candidate = resume_policy(control) if opt.experiment == "resume_read" else control
    source = HERE / (opt.experiment + ".c")
    report = {"revision": REV, "experiment": opt.experiment, "darwin": platform.release(),
              "machine": platform.machine(), "compiler": subprocess.check_output(["clang","--version"], text=True).splitlines()[0],
              "control_sha256": digest(control), "candidate_relay_sha256": digest(candidate),
              "fixture_sha256": digest(source.read_bytes()), "driver_sha256": digest(Path(__file__).read_bytes()),
              "support_sha256": digest(stock(SUPPORT)), "header_sha256": digest(stock(INCLUDE)),
              "attempts": []}
    with tempfile.TemporaryDirectory(prefix="mp-r6-") as tmp:
        work = Path(tmp)
        (work/"filter_work.c").write_bytes(stock(SUPPORT))
        (work/"PublishedTCP.h").write_bytes(stock(INCLUDE))
        for arm, data in (("control",control), ("candidate",candidate)):
            f = work / (arm + ".c")
            f.write_bytes(data)
            subprocess.run(["clang","-std=gnu11","-O2","-Wall","-Wextra","-Werror",
                            f'-DRELAY_SOURCE="{f}"',"-I",str(work),str(source),"-o",str(work/arm)],check=True)
        for arm in ("control","candidate","candidate","control"):
            proc = subprocess.run([str(work/arm),str(int(arm == "candidate"))],
                                  capture_output=True, text=True, timeout=30)
            report["attempts"].append({"arm":arm, "returncode":proc.returncode, "stderr":proc.stderr,
                                       "rows":[json.loads(line) for line in proc.stdout.splitlines()]})
            if proc.returncode: break
    with opt.output.open("x") as f:
        print(json.dumps(report, indent=2), file=f)
    if len(report["attempts"]) != 4 or any(a["returncode"] for a in report["attempts"]):
        raise SystemExit("Incomplete attempt series; inspect saved stdout/stderr")
if __name__ == "__main__":
    main()
