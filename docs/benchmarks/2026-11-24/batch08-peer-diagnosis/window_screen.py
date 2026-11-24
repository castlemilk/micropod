"""Recover first-attempt delivery under two fixed guest-socket receive-window requests."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "scripts/relaybench"))
from darwin_ack_policy import ARCHIVE_SHA, BASE_REV, FIXTURE, FIXTURE_SHA
from gamma_contrasts import IMAGE, VM, clean_client, host_units, process_delta, read_receipt

ARMS = ("fix-window-512", "fix-window-1024")
PHASE = "larger-windows"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def attempt(record, pids):
    c = record["client"]
    assert c["streams"] == len(c["per_stream_bytes"]) == 32 and c["arrivals"] == 240
    assert c["period_us"] == 25000 and c["window_s"] >= 6 and sum(c["per_stream_bytes"]) == c["bytes"]
    assert math.isclose(c["bytes"] / 2**20 / c["window_s"], c["mib_s"])
    errors = c["errors"] or []
    identities = sum('/id"' in e for e in errors)
    transfer = sum('/data"' in e or e.startswith("stream ") for e in errors)
    assert identities + transfer == len(errors) and clean_client(c) == record["clean"]
    if min(c["per_stream_bytes"]) > 0:
        fresh_failed = identities
    else:
        # An identity is issued once per bulk stream before it can transfer any body.
        # The only other identity calls are the 240 scheduled fresh arrivals.
        assert c["bytes"] == 0 and identities == 32 + 240 and transfer == 0
        fresh_failed = 240
    assert clean_client(c) == (fresh_failed == 0 and len(errors) == 0 and c["reopened"] == 0)
    costs = {}
    for role, pid in pids.items():
        delta = process_delta(record["before"], record["after"], pid)
        costs[role] = {**delta, **(host_units(delta, c["bytes"]) if c["bytes"] else {})}
    return dict(clean=record["clean"], meets_75ms=record["clean"] and c["fresh_p95_us"] <= 75000,
                window_s=c["window_s"], bytes=c["bytes"], mib_s=c["mib_s"], offered=c["arrivals"],
                fresh_failed=fresh_failed, setup_identity_failed=identities - fresh_failed,
                bulk_errors=transfer, reopens=c["reopened"], p95_ms=c["fresh_p95_us"] / 1000,
                p99_ms=c["fresh_p99_us"] / 1000, process=costs)


def study(owner):
    source = read_receipt(VM, ARCHIVE_SHA)
    proof = json.loads((HERE / "window-launch.json").read_text())
    build = read_receipt(FIXTURE, FIXTURE_SHA)["build-window.py"]
    assert 'setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &window, sizeof(window)) < 0' in build
    assert hashlib.sha256(build.encode()).hexdigest() == proof["source_sha256"]["build-window.py"]
    assert BASE_REV.startswith(source["baseline_commit"])
    if owner:
        for name, digest in proof["source_sha256"].items():
            assert sha(owner / name) == digest, name
        assert sha(owner / "window-pack/micropod") == proof["binary_sha256"]
        assert sha(owner / "fixed") == source["binaries"]["client"]
    phase = source["phases"][PHASE]
    jobs = proof["jobs"]
    assert len(phase["orders"]) == 5
    for field in ("program_args_sha256", "normalized_remaining_env_sha256", "process_type"):
        assert jobs[ARMS[0]][field] == jobs[ARMS[1]][field]
    rows = []
    for i, order in enumerate(phase["orders"], 1):
        sequence = order.split()
        assert len(sequence) == len(set(sequence)) == 4 and set(ARMS) <= set(sequence)
        row = {"block": i, "order": sequence}
        for name, requested in zip(ARMS, (524288, 1048576)):
            record, scope, job = phase["runs"][name][str(i)], source["scopes"][name], jobs[name]
            assert job["rcvbuf_request"] == requested and job["process_type"] == "Interactive"
            assert scope["host_sha256"] == proof["binary_sha256"] and scope["controller"] == "reno"
            assert scope["image"] == IMAGE and scope["vm"] == '4 4116488192 "7.3.5-micropod" "micropod"'
            assert [scope["state"][k] for k in ("cpu.max", "cpuset.cpus.effective", "memory.max", "pids.max")] == [
                "400000 100000", "0-3", "1073741824", "512"]
            assert 'spawn type = interactive' in scope["role"]
            if owner:
                directory = owner / "data" / PHASE
                assert sha(owner / "data" / name / "job.plist") == job["plist_sha256"]
                prefix = directory / f"{i}-{name}"
                assert Path(str(prefix)+".done").is_file()
                for ext, field in (("json", "client"), ("before", "before"), ("after", "after")):
                    assert json.loads(Path(str(prefix)+"."+ext).read_bytes()) == record[field]
                assert (directory / f"{i}.order").read_text().split() == sequence
            row[name] = attempt(record, job["pids"])
        rows.append(row)
    assert source["scopes"][ARMS[0]]["boot.json"]["boot"] != source["scopes"][ARMS[1]]["boot.json"]["boot"]
    return dict(direction="230.10", phase=PHASE, evidence="archived VM, offline first-attempt replay",
                date="2026-11-24", source_revision=BASE_REV, micropod_replay_base="ad9d174eda5eb499e0e15675829e21a00d836f84",
                archive_sha256=ARCHIVE_SHA, client_sha256=source["binaries"]["client"], option_source=FIXTURE.name,
                option_source_sha256=FIXTURE_SHA, launch_proof_sha256=sha(HERE/"window-launch.json"),
                replay_sha256=sha(Path(__file__)), fixture_image=IMAGE, rows=rows)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--owner-root", type=Path, help="Verify all original owner files while replaying")
    args = parser.parse_args()
    print(json.dumps(study(args.owner_root), indent=2, allow_nan=False))
