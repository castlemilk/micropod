"""Exercise the stock Darwin kqueue's accept dispatch with anonymous readiness queues."""
import argparse
import json
import platform
import subprocess
import tempfile
from pathlib import Path
from run import HERE, ROOT, STOCK, RELAY, HEADER, HELPER, FLAGS, candidate, digest, git_bytes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    output = parser.parse_args().output
    fixture = HERE / "accept_queue.c"
    stock = git_bytes(RELAY)
    changed = candidate(stock.decode(), "accept_quantum").encode()
    rows = []
    with tempfile.TemporaryDirectory(dir="/tmp", prefix="mp-a5-") as scratch:
        path = Path(scratch)
        (path / "PublishedTCP.h").write_bytes(git_bytes(HEADER))
        (path / "filter_work.c").write_bytes(git_bytes(HELPER))
        for arm, source in (("control", stock), ("candidate", changed)):
            src = path / (arm + ".c")
            src.write_bytes(source)
            subprocess.run(["clang", *FLAGS, f'-DRELAY_SOURCE="{src}"', "-I", scratch, str(fixture),
                            "-o", str(path / arm)], check=True)
        for arm in ("control", "candidate", "candidate", "control"):
            trial = subprocess.run([str(path / arm)], capture_output=True, text=True, timeout=25)
            rows.append({"arm": arm, "status": trial.returncode, "stderr": trial.stderr,
                         "rows": [json.loads(x) for x in trial.stdout.splitlines()]})
            if trial.returncode:
                break
    inputs = {str(p): digest(git_bytes(p)) for p in (HEADER, HELPER)}
    for p in (Path(__file__), HERE / "run.py", fixture):
        inputs[p.name] = digest(p.read_bytes())
    inputs.update(control_source=digest(stock), candidate_source=digest(changed))
    with output.open("x") as f:
        json.dump({"revision": STOCK, "experiment": "accept service quantum with anonymous queue fixture",
                   "system": [platform.system(), platform.release(), platform.machine()],
                   "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
                   "build_flags": FLAGS, "sha256": inputs, "attempts": rows}, f, indent=2)
        f.write("\n")
    if len(rows) != 4 or any(r["status"] or len(r["rows"]) != 6 for r in rows):
        raise SystemExit(f"Check {output} for incomplete fixed-work arms")
    if rows[0]["rows"] != rows[3]["rows"] or rows[1]["rows"] != rows[2]["rows"]:
        print("Fixed-work rows varied across repetitions; report all first attempts.")


if __name__ == "__main__":
    main()
