"""Compile the NET_RX budget fixture and verify each poll count and control."""
import argparse
import csv
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from extract import PINS, extract


HERE = Path(__file__).resolve().parent
REV = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
ARCHIVE = "docs/benchmarks/2026-11-21/gamma-direct-macvlan.json.gz"
ARCHIVE_SHA256 = "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976"
EXCERPT_SHA256 = "dd69657858a50e5b4c3be5f2fa3928a4b5a855da7ce234fe81ae1c9e8e63b001"
REQUESTS = (2000, 4000, 7999, 8000, 8001, 12000)

# (polls at 2 ticks, polls at 3 ticks, time_squeeze, repolls each owner)
CASES = {
    "time_aligned": (8, 12, 1, False),
    "time_late_in_tick": (5, 9, 1, False),
    "packet_bound": (5, 5, 1, True),
    "long_poll": (1, 1, 1, False),
    "one_saturated_owner": (1, 1, 0, True),
    "one_light_owner": (1, 1, 0, False),
}


def run(kernel_source):
    raw = subprocess.check_output(["git", "show", f"{REV}:{ARCHIVE}"], cwd=HERE)
    assert hashlib.sha256(raw).hexdigest() == ARCHIVE_SHA256
    kernel = json.loads(gzip.decompress(raw))["kernels"]
    assert {"CONFIG_HZ_250=y", "CONFIG_HZ=250"}.issubset(kernel["full"]["config"].splitlines())
    excerpt = (HERE / "rx.inc").read_bytes()
    assert hashlib.sha256(excerpt).hexdigest() == EXCERPT_SHA256
    if kernel_source:
        assert extract(kernel_source).encode() == excerpt

    with tempfile.TemporaryDirectory() as work:
        exe = Path(work) / "fixture"
        subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                        str(HERE / "probe.c"), "-o", str(exe)], check=True)
        output = subprocess.check_output([str(exe)], text=True, timeout=10)
    rows = []
    for raw_row in csv.DictReader(output.splitlines(), delimiter=" "):
        row = {k: v if k == "case" else int(v) for k, v in raw_row.items()}
        rows.append(row)
        req = row["requested_us"]
        readback = max(req, 8000)
        ticks = (readback + 3999) // 4000
        assert row["write_result"] == (-22 if req < 8000 else 0)
        assert (row["readback_us"], row["ticks"]) == (readback, ticks)
        stock_polls, treatment_polls, squeeze, repolls = CASES[row["case"]]
        polls = stock_polls if ticks == 2 else treatment_polls
        remaining = row["initial_owners"] - (0 if repolls else polls)
        assert (row["polls"], row["squeeze"]) == (polls, squeeze)
        assert row["work_done"] == polls * row["work_per_poll"]
        assert row["elapsed_us"] == polls * row["poll_us"]
        assert (row["remaining_owners"], row["reraised"]) == (remaining, int(remaining > 0))
    expected = {(request, case) for request in REQUESTS for case in CASES}
    assert len(rows) == len(expected) and {(r["requested_us"], r["case"]) for r in rows} == expected
    return {
        "direction": "231.03",
        "evidence": "Pinned Linux functions compiled in userspace with a deterministic clock and NAPI poll events.",
        "micropod_revision": REV,
        "linux_release": "v7.3.5",
        "archive": ARCHIVE,
        "archive_sha256": ARCHIVE_SHA256,
        "release_image_sha256": kernel["full"]["image_sha256"],
        "kernel_source_archive_sha256": kernel["source_sha256"],
        "upstream_git_blob_ids": PINS,
        "excerpt_sha256": EXCERPT_SHA256,
        "fixture_sha256": hashlib.sha256((HERE / "probe.c").read_bytes()).hexdigest(),
        "hz": 250,
        "packet_budget": 300,
        "stock_time_budget_us": 8000,
        "rows": rows,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel-source", type=Path, help="Check excerpt against the five pinned Linux files.")
    parser.add_argument("output", type=Path, nargs="?", help="Exclusive-create JSON output, default stdout.")
    args = parser.parse_args()
    result = json.dumps(run(args.kernel_source), indent=2) + "\n"
    if args.output:
        with args.output.open("x") as stream:
            stream.write(result)
    else:
        print(result, end="")
