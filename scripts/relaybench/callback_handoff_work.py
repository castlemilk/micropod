"""Measure fixed work until a queued fresh handoff enters the four-worker relay owner."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RELAY = ROOT / "Sources/CPublishedTCP"
FIXTURE = HERE / "callback_handoff_work.c"
FLAGS = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-fblocks"]
ORDER = (128, 24, 24, 128)
POSITIONS = [1, 16, 24, 25, 31]


def main():
    passes = []
    with tempfile.TemporaryDirectory(prefix="micropod-owner-handoff-") as path:
        for budget in (128, 24):
            subprocess.run(["clang", *FLAGS, f"-DMICROPOD_BENCH_FIXED_RELAY_BUDGET={int(budget == 128)}",
                            "-I", str(RELAY / "include"), str(FIXTURE), "-o", str(Path(path) / str(budget))],
                           check=True)
        for budget in ORDER:
            output = subprocess.check_output([str(Path(path) / str(budget))], text=True, timeout=30)
            rows = [json.loads(line) for line in output.splitlines()]
            if [r["enqueue_after_write"] for r in rows] != POSITIONS or any(
                r["budget"] != budget or r["bulk_bytes"] != 8 * 2**20 or r["bulk_writes"] != 32 for r in rows
            ):
                raise ValueError("incomplete fixture work")
            passes.append(rows)
    if passes[0] != passes[3] or passes[1] != passes[2]:
        raise ValueError("fixed-work trials differed by run order")
    files = [Path(__file__).resolve(), FIXTURE, HERE / "filter_work.c",
             RELAY / "PublishedTCP.c", RELAY / "include/PublishedTCP.h"]
    print(json.dumps({
        "date": "2026-11-24", "issue": 230, "stable_id": "230.03", "experiment": "callback-handoff-work",
        "revision": "2ccda8507355b8220258db2ce8160f3113d3e1ff",
        "source_sha256": {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest() for f in files},
        "tier": "Local Darwin host-only fixed-work fixture using anonymous UNIX stream socketpairs.",
        "toolchain": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
        "system": [platform.machine(), platform.release()],
        "build_flags": FLAGS, "arm_order": ORDER, "positions": POSITIONS,
        "method": "One data owner in the four-worker configuration serving eight established downloads. "
                  "The 128-event control and the ordinary 24-event arm use the same relay revision, 24-event "
                  "polls and 256 KiB cap. On the selected successful bulk write the fixture queues a handoff "
                  "on that owner's actual serial dispatch queue. At entry it stages a fresh connected socketpair "
                  "flow and writes its one-byte reply. Measure bytes relayed after enqueue up to entry and "
                  "up to forwarding the reply. The fixture explicitly submits follow-on drain callbacks.",
        "guardrails": "Every trial validates 8 MiB of per-flow ordered bulk, one fresh byte, forward FIN, "
                      "reverse marker/FIN and retirement of all nine streams. No clocks, TCP, guest, per-process "
                      "CPU or scheduled-arrival percentiles. Results are deterministic fixed-work counts for "
                      "the five chosen injection positions, not a sampled arrival distribution.",
        "verdict": "The shorter drain permits earlier entry at three of five positions. It removes "
                   "2 MiB before handoff entry in each case, and saves zero bulk bytes before the actual "
                   "fresh reply at every position. Both repeated arm orders agree.",
        "next_check": "Retain 128 events in the worker-count comparison. In a separately admitted callback "
                      "trial, distinguish enqueue-to-adopt from adopt-to-first-byte before crediting earlier "
                      "handoff entry with any reduction in scheduled-arrival latency.",
        "raw_passes": passes,
    }, indent=2))


if __name__ == "__main__":
    main()
