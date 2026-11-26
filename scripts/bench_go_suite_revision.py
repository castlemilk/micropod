#!/usr/bin/env python3
"""Time the first CI fan-out on a changed checkout, including publication, OCI preparation and dispatch."""

import argparse
import json
import os
import shutil
import subprocess
import tempfile
import time
import uuid
from contextlib import ExitStack
from pathlib import Path

from bench_ci_startup import WarmSession, export_timeline
from bench_go_suite import call, native_batch
from ci_benchmark_store import DEFAULT_DB, store

ROOT = Path(__file__).resolve().parents[1]


def measure(fn, *args, **kwargs):
    start = time.monotonic()
    value = fn(*args, **kwargs)
    return value, time.monotonic() - start


def compare(args, result, checkout):
    script = ROOT / "ci/oci-batch.sh"
    main = checkout / "main.go"
    before = main.read_text()
    if before.count("switch cmd {") != 1:
        raise ValueError("Expected the Micropod guest Go fixture")
    previous = set()
    for n in args.clients:
        for rep in range(args.rounds):
            # The change is live code in the actual executable. An unused constant could be eliminated.
            token = f"ci-{result['run']}-{n}-{rep}"
            main.write_text(
                before.replace(
                    "switch cmd {",
                    f'switch cmd {{\n\tcase "ci-revision":\n\t\t_, err := fmt.Fprintln(stdout, "{token}")\n\t\treturn err',
                )
            )
            digest = None
            handles = []
            tags = []
            try:
                for mode in (
                    ("source", "suite") if rep % 2 == 0 else ("suite", "source")
                ):
                    start = time.monotonic()
                    source, snapshot = measure(
                        call, [args.cli, "ci", "snapshot", args.base, str(checkout)]
                    )
                    source = source.strip()
                    image, prep = source, 0
                    publication = None
                    if mode == "suite":
                        p, prep = measure(
                            subprocess.run,
                            [str(ROOT / "ci/prepare-go-suite.sh"), source, args.scope],
                            text=True,
                            check=True,
                            capture_output=True,
                            timeout=180,
                        )
                        events = [
                            json.loads(line)
                            for line in p.stderr.splitlines()
                            if line.startswith('{"event":')
                        ]
                        if len(events) != 1 or events[0]["cache"] != "miss":
                            raise ValueError(
                                f"Expected one new revision preparation: {events}"
                            )
                        image = p.stdout.strip()
                        publication = events[0].get("publication") or {"method": "buildkit"}
                        tags.append("micropod-internal/ci-go-suite:" + events[0]["key"])
                        if publication["method"] == "buildkit":
                            tags.append("micropod-internal/ci-workspace:" + source.removeprefix("sha256:"))
                    handle, handle_s = measure(
                        call, [str(script), "prepare", image, args.scope]
                    )
                    handle = handle.strip()
                    handles.append(handle)
                    with ExitStack() as stack:
                        session, opened = measure(
                            WarmSession, args.cli, handle, "runc", stack
                        )
                        wall, jobs = native_batch(session, mode, n)
                        total = time.monotonic() - start
                        # Keep post-run evidence outside the submission-to-result clock.
                        if mode == "suite":
                            proof = call(
                                [
                                    args.cli,
                                    "ci",
                                    "run",
                                    "--network",
                                    "none",
                                    "--entrypoint",
                                    "/micropod-ci-suite/product",
                                    image,
                                    "ci-revision",
                                ]
                            ).strip()
                            if proof != token:
                                raise ValueError("Stale Go output after a real edit")
                        sha = {j["sha256"] for j in jobs}
                        if (
                            len(sha) != 1
                            or (digest and sha != {digest})
                            or sha & previous
                        ):
                            raise ValueError(
                                "Expected new, identical executables in every job"
                            )
                        digest = sha.pop()
                        result["batches"].append(
                            {
                                "round": rep + 1,
                                "clients": n,
                                "mode": mode,
                                "source": source,
                                "product_sha256": digest,
                                "seconds": total,
                                "snapshot_s": snapshot,
                                "prepare_s": prep,
                                "publication": publication,
                                "handle_s": handle_s,
                                "session_s": opened,
                                "jobs_s": wall,
                            }
                        )
                        print(
                            f"first revision {n} x {mode} {rep + 1}: {total:.3f}s",
                            flush=True,
                        )
                        if (
                            args.trace
                            and n == max(args.clients)
                            and rep + 1 == args.rounds
                        ):
                            seconds, traced = native_batch(session, mode, n, trace=True)
                            result["traces"].append(
                                {
                                    "clients": n,
                                    "mode": mode,
                                    "engine": "Micropod " + mode,
                                    "round": rep + 1,
                                    "seconds": seconds,
                                    "jobs": traced,
                                }
                            )
                previous.add(digest)
            finally:
                for handle in handles:
                    call([str(script), "forget", handle])
                if tags:
                    call([args.cli, "ci", "docker", "image", "rm", *tags])


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cli", default=os.getenv("MICROPOD_BIN", "micropod"))
    p.add_argument("--base", required=True)
    p.add_argument(
        "--checkout",
        type=Path,
        required=True,
        help="The offline, vendored guest module",
    )
    p.add_argument("--scope", required=True)
    p.add_argument("--rounds", type=int, default=2)
    p.add_argument("--clients", type=int, nargs="+", default=[1, 16, 32])
    p.add_argument("--trace", action="store_true")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--database", type=Path, default=DEFAULT_DB)
    args = p.parse_args()
    os.environ.update(MICROPOD_BIN=args.cli, MICROPOD_OCI_BACKEND="native")
    if (
        not 2 <= args.rounds <= 30
        or len(set(args.clients)) != len(args.clients)
        or any(n < 1 or n > 64 for n in args.clients)
    ):
        p.error("Use 2–30 rounds and distinct client counts from 1–64")
    receipt = {"run": uuid.uuid4().hex, "passed": False, "batches": [], "traces": []}
    try:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "checkout"
            shutil.copytree(args.checkout, path)
            compare(args, receipt, path)
        if args.trace:
            export_timeline(
                {"batches": receipt["traces"]},
                args.output.with_suffix(".trace.json.gz"),
            )
        receipt["passed"] = True
    except Exception as error:
        receipt["error"] = str(error)
        raise
    finally:
        args.output.write_text(json.dumps(receipt) + "\n")
        store(args.database, receipt["run"], "go-ci-first-revision", receipt)
