"""Check Darwin kqueue changes with fixed payloads. No timed workload or IP listener."""
import argparse
import json
import platform
import subprocess
import sys
import tempfile
from contextlib import nullcontext
from datetime import datetime, timezone
from pathlib import Path

from compare import FIXTURE as LOAD_FIXTURE, build, git, sha

BASE = "86ca2713a0791d26c137e9a8c6385e1b6bd04ebb"
FIXTURE = Path(__file__).with_name("filter_work.c")


def verify(rows, batched):
    cases = [(row["owner"], row["room_bytes"]) for row in rows]
    if sorted(cases) != [(owner, room) for owner in ("dedicated", "split") for room in (0, 16384)]:
        raise ValueError("missing or duplicate socket-buffer case")
    for row in rows:
        group = batched and row["owner"] == "dedicated"
        for phase, filters in (("connect_complete", 3), ("unblocked_bulk", 0), ("pause_reader", 2), ("resume_reader", 2)):
            expected = dict(syscalls=1 if group and filters else filters, filters=filters)
            if row[phase] != expected:
                raise ValueError(f"{row['owner']} {phase}: {row[phase]} != {expected}")
        sent = row["first_write_bytes"]
        if (row["verified_payload_bytes"] != 4 * 32768 + 3
                or not (0 < sent < 32768 if row["room_bytes"] else sent == 0)):
            raise ValueError("payload coverage or first-write outcome changed")


def run():
    receipt = dict(started_utc=datetime.now(timezone.utc).isoformat(), host=platform.node(),
                   macos=platform.mac_ver()[0], arch=platform.machine(),
                   compiler=subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
                   baseline_revision=BASE, checkout_head=git("rev-parse", "HEAD").decode().strip(),
                   fixture_sha256=sha(FIXTURE.read_bytes()), load_fixture_sha256=sha(LOAD_FIXTURE.read_bytes()),
                   driver_sha256=sha(Path(__file__).read_bytes()), arms={})
    with tempfile.TemporaryDirectory() as tmp:
        for name, revision, batched, sanitize in (
            ("parent", BASE, False, False), ("default", None, False, False),
            ("batched", None, True, False), ("batched_sanitized", None, True, True),
        ):
            arm = receipt["arms"][name] = dict(passed=False)
            try:
                exe, arm["build"] = build(Path(tmp) / name, revision, False, sanitize,
                                          batch_filters=batched, fixture=FIXTURE)
                proc = subprocess.run([exe], capture_output=True, text=True, timeout=8)
                arm.update(exit_code=proc.returncode, stderr=proc.stderr, stdout=proc.stdout)
                proc.check_returncode()
                rows = [json.loads(line) for line in proc.stdout.splitlines()]
                verify(rows, batched)
                arm["cases"] = rows
                del arm["stdout"]
                if name in ("default", "batched"):
                    pilot, arm["pilot_build"] = build(Path(tmp) / (name + "-pilot"), revision, False, False,
                                                      batch_filters=batched, stage_connect=True)
                    smoke = subprocess.run([pilot, "check", "512", "0", "2", "1"], capture_output=True,
                                           text=True, timeout=8)
                    arm["pilot_check"] = dict(exit_code=smoke.returncode, stderr=smoke.stderr, stdout=smoke.stdout)
                    smoke.check_returncode()
                    if json.loads(smoke.stdout) != dict(live_revocation=True, sibling_and_reuse=True, timed_rounds=0):
                        raise ValueError("host pilot did not verify revocation, sibling traffic and reuse")
                arm["passed"] = True
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
                arm["error"] = str(exc)
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, help="new JSON receipt (default stdout)")
    args = parser.parse_args()
    output = args.out.open("x") if args.out else nullcontext(sys.stdout)
    with output as out:
        receipt = run()
        print(json.dumps(receipt, indent=2, allow_nan=False), file=out)
    sys.exit(0 if all(arm["passed"] for arm in receipt["arms"].values()) else 1)
