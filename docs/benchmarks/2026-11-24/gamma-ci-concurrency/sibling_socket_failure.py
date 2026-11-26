"""Replay rejected warm-socket waves without calculating benchmark scores."""

import argparse
import gzip
import json
import os
import re
import tempfile
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path

from qualify import BASELINE, HERE, check_baseline, require, terminal

SOCKET_ERROR = "request did not stay on the warmed connection"
CLIENT_SOURCE = "568ec87401b60bda95ae8c51871feddb801ef4d4244d4b3d16be0b5f47a88fbf"
WAIT_THRESHOLD_NS = 49_000_000


def read(folder, name):
    return json.loads((folder / name).read_bytes())


def socket_rejection(status):
    error = status.get("error", "")
    if status["complete"] is False and SOCKET_ERROR in error:
        fail = re.match(r"incomplete ([AB]) client (\d+):", error)
        require(fail is not None, "warm-socket failure lacks a client and engine")
        return fail[1], int(fail[2])


def post_first_byte(sample):
    first = sample["first_response_byte_ns"]
    if first > 0:
        require(sample["total_ns"] >= first, "response arrived after the request completed")
        return sample["total_ns"] - first
    return 0


def phase(index, sample):
    return {"sample_index": index, "total_ns": sample["total_ns"], "first_response_byte_ns": sample["first_response_byte_ns"],
            "post_first_byte_ns": post_first_byte(sample), "got_conn_count": sample["got_conn_count"],
            "dial_starts": sample["dial_starts"], "reused": sample["reused"],
            "same_as_warmup": sample["same_as_warmup"], "error": sample.get("error")}


def failed_client(row):
    samples = row["receipt"]["samples"]
    first_dial = next((i for i, sample in enumerate(samples) if sample["dial_starts"]), None)
    warm_errors = sum(sample.get("error") == SOCKET_ERROR for sample in samples)
    return {"client_index": row["index"], "exit_code": row["code"], "stderr": row["stderr"], "samples": len(samples),
            "warm_socket_assertion_failures": warm_errors,
            "redials": sum(sample["dial_starts"] for sample in samples),
            "replacement_reuses": sum(sample["reused"] and not sample["same_as_warmup"] for sample in samples),
            "first_redial": phase(first_dial, samples[first_dial]) if first_dial is not None else None,
            "preceding_request": phase(first_dial - 1, samples[first_dial - 1]) if first_dial else None}


def replay(folder, baseline_files):
    plan = read(folder, "plan.json")
    status = read(folder, "status.json")
    rejection = socket_rejection(status)
    require(rejection is not None, f"no warm-socket rejection in {folder.name}")
    arm, client = rejection
    require(plan["quiet_source_sha256"] == terminal.digest(folder / "quiet-http.go") == CLIENT_SOURCE,
            "unexpected probe source for the response check and trace interpretation")
    cleanup = read(folder, "cleanup.json")
    scope = Path(plan["scope"])
    require(scope.is_absolute() and cleanup == {"scope": str(scope), "retained": False, "errors": []}
            and not os.path.lexists(scope), f"failed scope remains or cleanup differs in {folder.name}")
    require(plan["baseline_files"] == baseline_files and read(folder, "verification.json") ==
            {"baseline_files": baseline_files, "extra_cleanup_errors": []}, f"baseline receipts differ in {folder.name}")
    scored = read(folder, "windows.json")
    suffix = f"-{arm}.json.gz"
    raw = [path for path in folder.glob("*" + suffix) if path.name.removesuffix(suffix) not in scored]
    require(len(raw) == 1, f"expected one unscored raw wave for arm {arm} in {folder.name}")
    wave, = raw
    _, block, mode = wave.name.removesuffix(suffix).rsplit("-", 2)
    count = plan["healthy_pairs"]
    require(mode in ("one", "all"), f"unknown wave mode in {wave.name}")
    targets = list(range(count)) if mode == "all" else [int(block) % count]
    with gzip.open(wave, "rt") as stream:
        rows = json.load(stream)
    require([row["index"] for row in rows] == targets, f"wrong raw client cohort in {wave.name}")
    failed = [failed_client(row) for row in rows if row["code"] or not row["receipt"]["complete"]]
    require(any(row["client_index"] == client and row["warm_socket_assertion_failures"] for row in failed),
            f"status does not match raw client receipts in {wave.name}")

    samples = [sample for row in rows for sample in row["receipt"]["samples"]]
    warmup_errors = Counter(row["receipt"]["warmup"]["error"] for row in rows if row["receipt"]["warmup"].get("error"))
    errors = Counter(sample["error"] for sample in samples if sample.get("error"))
    warm_only = errors.pop(SOCKET_ERROR, 0)
    # The pinned probe checks the HTTP status and exact body before examining
    # the connection. A warm-socket assertion failure has passed both checks.
    checked = len(samples) - sum(errors.values())
    files = ("plan.json", "status.json", "cleanup.json", "verification.json", "windows.json", "quiet-http.go", wave.name)
    return {"run": folder.name, "seed": plan["seed"], "arm": arm, "wave": wave.name, "eligible_for_scoring": False,
            "saved_paired_windows_before_rejection": len(scored), "raw_clients": len(rows), "raw_samples": len(samples),
            "warm_socket_assertion_failures": warm_only, "samples_passed_status_and_body_checks": checked,
            "warmup_errors": dict(warmup_errors), "other_sample_errors": dict(errors),
            "post_first_byte_waits_at_least_threshold": sum(post_first_byte(sample) >= WAIT_THRESHOLD_NS for sample in samples),
            "failed_clients": failed, "scope": cleanup, "baseline_files": baseline_files,
            "input_sha256": {name: terminal.digest(folder / name) for name in files}}


def discover(seeds):
    rejected = []
    observed = []
    for path in sorted(HERE.glob("*-sibling-*/plan.json")):
        folder = path.parent
        seed = read(folder, path.name)["seed"]
        if seed not in seeds:
            continue
        status = read(folder, "status.json") if (folder / "status.json").is_file() else None
        if status is None:
            state = "pending"
        elif status["complete"]:
            state = "complete"
        elif socket_rejection(status):
            rejected.append(folder.resolve())
            state = "warm-socket rejection"
        else:
            state = "other rejection"
        observed.append({"run": folder.name, "seed": seed, "state": state})
    return rejected, observed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("runs", type=Path, nargs="+")
    parser.add_argument("--include-seed", type=int, action="append", default=[])
    args = parser.parse_args()
    require(not os.path.lexists(args.output), f"receipt already exists: {args.output}")
    discovered, observed = discover(args.include_seed) if args.include_seed else ([], [])
    folders = dict.fromkeys([*(path.resolve() for path in args.runs), *discovered])
    baseline_files = check_baseline()
    result = {"created_utc": datetime.now(UTC).isoformat(), "replay_sha256": terminal.digest(Path(__file__)),
              "baseline_manifest_sha256": terminal.digest(BASELINE), "post_first_byte_threshold_ns": WAIT_THRESHOLD_NS,
              "observed_seed_runs": observed, "rejections": [replay(folder, baseline_files) for folder in folders]}
    with tempfile.NamedTemporaryFile(mode="w", dir=args.output.parent) as temp:
        json.dump(result, temp, indent=2, allow_nan=False)
        temp.write("\n")
        temp.flush()
        os.link(temp.name, args.output)
    print(args.output)


if __name__ == "__main__":
    main()
