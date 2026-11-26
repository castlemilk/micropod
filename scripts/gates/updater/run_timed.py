#!/usr/bin/env python3
"""Run one command and time it from outside.

  run_timed.py PREFIX -- CMD [ARGS...]

stdout goes to PREFIX.out, stderr to PREFIX.err, and PREFIX.time.json gets
{"argv", "startWall", "endWall", "ms", "exit"}. Exits with CMD's status
(128+N for a signal), so a shell can branch on it.
"""

import json
import subprocess
import sys
import time


def main() -> int:
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        print(__doc__, file=sys.stderr)
        return 2
    prefix, cmd = sys.argv[1], sys.argv[3:]
    with open(prefix + ".out", "wb") as out, open(prefix + ".err", "wb") as err:
        start_wall, start = time.time(), time.monotonic()
        proc = subprocess.run(cmd, stdout=out, stderr=err, check=False)
        end, end_wall = time.monotonic(), time.time()
    code = proc.returncode if proc.returncode >= 0 else 128 - proc.returncode
    record = {
        "argv": cmd,
        "startWall": start_wall,
        "endWall": end_wall,
        "ms": round((end - start) * 1000, 1),
        "exit": code,
    }
    with open(prefix + ".time.json", "w", encoding="utf-8") as f:
        json.dump(record, f, indent=2)
    return code


if __name__ == "__main__":
    sys.exit(main())
