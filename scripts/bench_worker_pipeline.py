#!/usr/bin/env python3
"""Pair two worker-pipeline revisions on real code edits and immediate same-revision repeats."""

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

from ci_benchmark_store import DEFAULT_DB, store

ROOT = Path(__file__).resolve().parents[1]


def run(command, **kw):
    return subprocess.run(
        command, text=True, capture_output=True, timeout=600, check=True, **kw
    ).stdout


def run_phase(path, endpoint, tag, variant, mode, round_no, trace):
    start = time.time_ns()
    clock = time.perf_counter()
    result = subprocess.run(
        ["bash", str(path / "ci/worker-pipeline.sh"), "all", endpoint],
        env=dict(
            os.environ,
            BUILDKIT_PROGRESS="plain",
            MICROPOD_CI_STAGE_TIMINGS=str(trace),
            MICROPOD_CI_SAMPLE_IMAGE=tag,
        ),
        capture_output=True,
        check=False,
        text=True,
        timeout=600,
    )
    seconds = time.perf_counter() - clock
    if result.returncode:
        output = result.stdout + result.stderr
        dns = [line for line in output.splitlines() if "DNS: transient error" in line]
        if dns:
            raise ConnectionError(dns[0], seconds)
        raise RuntimeError(output[-4000:])
    stages = [json.loads(line) for line in trace.read_text().splitlines()]
    expected = {"go-checks", "go-image", "node-image", "node-edit", "postgres"}
    if variant == "candidate":
        expected.update(("go-unit", "node-unit"))
    if (
        {s for s, _, _ in stages} != expected
        or len(stages) != len(expected)
        or any(c for _, _, c in stages)
    ):
        raise ValueError(f"Incomplete pipeline stages: {stages}")
    docker = ["docker", "--host", endpoint]
    until = time.time_ns()
    events = run(
        [
            *docker,
            "events",
            "--since",
            f"{start // 10**9}.{start % 10**9:09d}",
            "--until",
            f"{until // 10**9}.{until % 10**9:09d}",
            "--filter",
            "type=container",
            "--filter",
            "image=postgres:16",
            "--format",
            "{{json .}}",
        ]
    )
    # Ignore unrelated PostgreSQL activity on a shared daemon. Only a single traced test is valid.
    sql = re.search(
        r"verified SQL round trip on the final TCP server ([a-f0-9]{64})", result.stdout
    )
    pg = {}
    for event in map(json.loads, events.splitlines()):
        actor = event["Actor"]
        attrs = actor["Attributes"]
        if (
            not attrs.get("org.testcontainers.sessionId")
            or (sql and actor["ID"] != sql[1])
            or event["Action"] not in {"start", "die", "kill", "destroy"}
        ):
            continue
        pg.setdefault(actor["ID"], []).append(
            {
                "action": event["Action"],
                "ns": event["timeNano"],
                "signal": attrs.get("signal"),
                "exit": attrs.get("exitCode"),
            }
        )
    if len(pg) != 1:
        raise ValueError(f"Expected one PostgreSQL lifecycle, got {pg}")
    life = next(iter(pg.values()))
    if not any(e["action"] == "destroy" for e in life):
        raise ValueError(f"PostgreSQL cleanup incomplete: {life}")
    if variant == "candidate" and (
        not sql
        or not any(e["exit"] == "0" for e in life)
        or any(e["signal"] == "9" for e in life)
        or "--- PASS: TestGreeting" not in result.stdout
        or "greets the world by default" not in result.stdout
    ):
        raise ValueError(
            f"SQL, live race test or graceful shutdown proof missing: {life}"
        )
    sha = run(
        [
            *docker,
            "run",
            "--rm",
            "--network",
            "none",
            "--entrypoint",
            "sha256sum",
            tag + ":go",
            "/app",
        ]
    ).split()[0]
    return {
        "round": round_no,
        "revision": variant,
        "mode": mode,
        "seconds": seconds,
        "stages": {k: v for k, v, _ in stages},
        "product_sha256": sha,
        "postgres": pg,
        "sql": bool(sql),
        "live_node_tests": "greets the world by default" in result.stdout,
        "unit_tests": re.findall(
            r"^--- PASS: (Test(?!Postgres)\w+)", result.stdout, re.MULTILINE
        ),
    }


def main(args):
    engines = {"micropod": args.micropod_endpoint, "orbstack": args.orbstack_endpoint}
    key = uuid.uuid4().hex
    record = {"passed": False, "run": key, "batches": []}
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        paths = {}
        for variant, tree in [("baseline", args.baseline), ("candidate", ROOT)]:
            path = paths[variant] = work / variant
            shutil.copytree(tree / "ci", path / "ci")
        original = {
            k: (v / "ci/samples/go-app/main.go").read_text() for k, v in paths.items()
        }
        tags = {k: f"micropod-internal/full-ci-{key}-{k}" for k in paths}
        try:
            previous = None
            for i in range(args.rounds + 1):
                marker = f"{key}-{i}"
                for variant, path in paths.items():
                    old = original[variant]
                    line = 'fmt.Fprintln(w, greeting(r.URL.Query().Get("name")))'
                    if old.count(line) != 1:
                        raise ValueError(
                            "Go sample HTTP handler changed; update the source edit"
                        )
                    (path / "ci/samples/go-app/main.go").write_text(
                        old.replace(
                            line,
                            f'w.Header().Set("X-CI-Revision", "{marker}")\n\t{line}',
                        )
                    )
                digests = set()
                for name in list(engines)[:: 1 if i % 2 == 0 else -1]:
                    for variant in list(paths)[
                        :: 1 if (i + (name == "orbstack")) % 2 == 0 else -1
                    ]:
                        for mode in ("edit", "repeat"):
                            trace = work / f"{name}-{variant}-{i}-{mode}.jsonl"
                            args_for_phase = (
                                paths[variant],
                                engines[name],
                                tags[variant],
                                variant,
                                mode,
                                i,
                            )
                            failures = []
                            for attempt in range(3):
                                try:
                                    row = run_phase(
                                        *args_for_phase,
                                        trace.with_suffix(f".{attempt}.jsonl"),
                                    )
                                    break
                                except ConnectionError as err:
                                    failures.append(
                                        {"error": err.args[0], "seconds": err.args[1]}
                                    )
                                    print(
                                        f"{name} {variant} {mode} DNS attempt {attempt + 1} failed",
                                        flush=True,
                                    )
                                    if attempt == 2:
                                        record["failure"] = failures
                                        raise
                            row["previous_attempts"] = failures
                            row["time_to_green_s"] = row["seconds"] + sum(
                                f["seconds"] for f in failures
                            )
                            row.update(engine=name, edit=marker)
                            record["batches"].append(row)
                            digests.add(row["product_sha256"])
                            print(
                                f"{name} {variant} {i} {mode} {row['seconds']:.3f}s",
                                flush=True,
                            )
                if len(digests) != 1 or previous in digests:
                    raise ValueError(
                        f"Source edits and equal executable bytes required: {digests}, previous {previous}"
                    )
                previous = next(iter(digests))
            record["passed"] = True
        except Exception as error:
            record["error"] = str(error)
            raise
        finally:
            for endpoint in engines.values():
                for tag in tags.values():
                    subprocess.run(
                        [
                            "docker",
                            "--host",
                            endpoint,
                            "image",
                            "rm",
                            *[
                                tag + ":" + name
                                for name in ("checks", "go", "node", "node-edited")
                            ],
                        ],
                        check=False,
                        capture_output=True,
                        timeout=60,
                    )
            args.output.write_text(json.dumps(record) + "\n")
            store(args.database, key, "full-ci-pipeline", record)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--baseline", type=Path, required=True)
    p.add_argument(
        "--micropod-endpoint",
        default="unix://" + str(Path.home() / ".micropod/ci/docker.sock"),
    )
    p.add_argument(
        "--orbstack-endpoint",
        default="unix://" + str(Path.home() / ".orbstack/run/docker.sock"),
    )
    p.add_argument("--rounds", type=int, default=3)
    p.add_argument("--database", type=Path, default=DEFAULT_DB)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    if not 1 <= args.rounds <= 30:
        p.error("Use 1–30 measured rounds")
    main(args)
