"""Compile pinned stock and a single change in temporary space. Preserve all fixed-work attempts."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
STOCK = "7d9b565173a901cb18942e00384838da96e0ba98"
RELAY = Path("Sources/CPublishedTCP/PublishedTCP.c")
HEADER = Path("Sources/CPublishedTCP/include/PublishedTCP.h")
HELPER = Path("scripts/relaybench/filter_work.c")
FLAGS = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror"]
SUFFIX_PRIORITY = """bool bulk[DATA_READY_BATCH] = {0};
        bool short_suffix[DATA_READY_BATCH] = {0};"""
SUFFIX_CATEGORY = """bulk[i] = (events[i].filter == EVFILT_READ ? e : opposite(e))->bulk_read;
                short_suffix[i] = bulk[i] && events[i].filter == EVFILT_WRITE &&
                                  e->pending && e->length && e->length <= 4096;"""
SUFFIX_SERVICE = """for (int i = 0; i < n; ++i) if (short_suffix[i]) service_polled_event(&events[i], poll);
        for (int i = 0; i < n; ++i) if (bulk[i] && !short_suffix[i]) service_polled_event(&events[i], poll);"""


def replace(text, before, after):
    if text.count(before) != 1:
        raise ValueError(f"Ambiguous or missing anchor: {before}")
    return text.replace(before, after)


def candidate(control, name):
    if name == "accept_quantum":
        return replace(control, "for (int j = 0; j < 32; ++j)", "for (int j = 0; j < 8; ++j)")
    control = replace(control, "bool bulk[DATA_READY_BATCH] = {0};", SUFFIX_PRIORITY)
    control = replace(control, SUFFIX_CATEGORY.splitlines()[0], SUFFIX_CATEGORY)
    return replace(control, "for (int i = 0; i < n; ++i) if (bulk[i]) service_polled_event(&events[i], poll);", SUFFIX_SERVICE)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git_bytes(path):
    return subprocess.check_output(["git", "show", f"{STOCK}:{path}"], cwd=ROOT)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("name", choices=["accept_quantum", "suffix_ready"])
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    fixture = HERE / f"{a.name}.c"
    control = git_bytes(RELAY)
    changed = candidate(control.decode(), a.name).encode()
    runs = []
    with tempfile.TemporaryDirectory(dir="/tmp", prefix="mp-r5-") as directory:
        local = Path(directory)
        (local / "filter_work.c").write_bytes(git_bytes(HELPER))
        (local / "PublishedTCP.h").write_bytes(git_bytes(HEADER))
        for arm, data in (("control", control), ("candidate", changed)):
            src = local / f"{arm}.c"
            src.write_bytes(data)
            subprocess.run(["clang", *FLAGS, f'-DRELAY_SOURCE="{src}"', "-I", directory,
                            str(fixture), "-o", str(local / arm)], check=True)
        for arm in ("control", "candidate", "candidate", "control"):
            result = subprocess.run([str(local / arm), directory], capture_output=True, timeout=25, text=True)
            runs.append({"arm": arm, "status": result.returncode, "stderr": result.stderr,
                         "rows": [json.loads(x) for x in result.stdout.splitlines()]})
            if result.returncode:
                break
    output = {"revision": STOCK, "experiment": a.name, "system": [platform.system(), platform.release(), platform.machine()],
              "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
              "build_flags": FLAGS, "sha256": {"control_source": digest(control), "candidate_source": digest(changed),
                                               str(HEADER): digest(git_bytes(HEADER)), str(HELPER): digest(git_bytes(HELPER)),
                                               fixture.name: digest(fixture.read_bytes()), "run.py": digest(Path(__file__).read_bytes())},
              "attempts": runs}
    with a.output.open("x") as f:
        f.write(json.dumps(output, indent=2) + "\n")
    if len(runs) != 4 or any(r["status"] or len(r["rows"]) != 6 for r in runs):
        raise SystemExit(f"Check {a.output} for incomplete fixed-work arms")
    if runs[0]["rows"] != runs[3]["rows"] or runs[1]["rows"] != runs[2]["rows"]:
        print("Repeated fixed-work arm differed; retain both and report per-attempt ranges.")


if __name__ == "__main__":
    main()
