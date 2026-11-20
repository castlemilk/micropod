#!/usr/bin/env python3
"""Measure 20 real Go CI jobs sharing one toolchain and two Linux cache volumes."""

import argparse
import json
import os
import re
import subprocess
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from pathlib import Path

JOB = r"""
set -eu
umask 022
tmp=${TMPDIR:-/tmp}
export EXPECTED_REVISION=$1
printf 'package main\nconst revision = "%s"\n' "$1" > revision.go
mark() { awk '$1=="usage_usec" {print $2}' /sys/fs/cgroup/cpu.stat; }
before=$(mark)
go vet -x ./... 2> "$tmp"/vet.trace || { tail -40 "$tmp"/vet.trace >&2; exit 1; }
go test -x -count=1 -v ./... > "$tmp"/results 2> "$tmp"/test.trace || { cat "$tmp"/results >&2; tail -40 "$tmp"/test.trace >&2; exit 1; }
go build -x -trimpath -buildvcs=false -o "$tmp"/product . 2> "$tmp"/build.trace || { tail -40 "$tmp"/build.trace >&2; exit 1; }
test "$("$tmp"/product ci-revision)" = "$1"
tests=$(grep -c '^--- PASS: Test' "$tmp"/results)
test "$tests" = 8
toolcounts=$(awk '/\/compile["\047]?[[:space:]]+-o / {c++} /\/vet["\047]?[[:space:]]/ && $NF ~ /\/vet\.cfg["\047]?$/ {v++}
                  /\/link["\047]?[[:space:]]+-o / {l++} END {print c+0,v+0,l+0}' "$tmp"/*.trace)
after=$(mark)
mod="$GOMODCACHE/cache/download/github.com/opencontainers/runtime-spec/@v/v1.3.0.zip"
archive=$(go list -export -f '{{.Export}}' github.com/opencontainers/runtime-spec/specs-go)
printf '%s %s %s %s %s %s %s %s %s %s %s %s\n' "$1" "${MP_RAW_ID:-$(hostname)}" "$tests" "$before" "$after" "$toolcounts" "$(sha256sum "$tmp"/product | cut -d' ' -f1)" "$(stat -c '%d:%i' "$mod")" "$(stat -c '%d:%i' "$archive")" "$(cat /proc/sys/kernel/random/boot_id)" "$(stat -c '%i' "$(command -v go)")" "$(basename "$archive")"
"""


def call(cmd, *, timeout=360):
    proc = subprocess.run(
        cmd, capture_output=True, text=True, timeout=timeout, check=False
    )
    if proc.returncode:
        raise RuntimeError(
            f"{cmd[0]} exited {proc.returncode}: {proc.stderr[-3400:]} {proc.stdout[-600:]}"
        )
    return proc.stdout.strip()


# All Go compilation and verification happen in Linux. SSH setup is outside the raw clock.
RAW = r"""
set -euo pipefail
root=$1; scope=$2; n=$3; same=$4; job=$5; prime=$6
export GOCACHE="$root/cache/$scope/build" GOMODCACHE="$root/cache/$scope/mod"
export PATH="/usr/local/go/bin:$PATH" GOPROXY="file://$root/source/proxy"
export GOENV=off GOTOOLCHAIN=local GOWORK=off GOFLAGS="-trimpath -p=2" CGO_ENABLED=0 GOMAXPROCS=2 GOTELEMETRY=off GOSUMDB=off
mkdir -p "$GOCACHE" "$GOMODCACHE"
wave=$(mktemp -d); trap 'rm -rf "$wave"' EXIT
start=$(date +%s%N)
if ((prime)); then (cd "$root/source"; go test -c -o /dev/null ./... >/dev/null; go vet ./...); fi
primed=$(date +%s%N)
pids=()
for ((i=0; i<n; i++)); do
    (
        begin=$(date +%s%N)
        export MP_RAW_ID="work-$i" TMPDIR="$wave/tmp-$i"
        work="$wave/$MP_RAW_ID"; mkdir "$work" "$TMPDIR"
        tar -C "$root/source" --exclude=./proxy -cf - . | tar -C "$work" -xf -
        cd "$work"; printf -v revision 'r%02d' "$((same ? 0 : i))"
        sh -ec "$job" sh "$revision"; cd /
        rm -rf "$work" "$TMPDIR"; echo "$(( $(date +%s%N) - begin ))"
    ) > "$wave/j$i" & pids+=("$!")
done
failed=0; for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
end=$(date +%s%N); (( ! failed )) || exit 1
echo "$start $primed $end"
for ((i=0; i<n; i++)); do cat "$wave/j$i"; done
du -sB1 "$GOCACHE" "$GOMODCACHE"; du -sb "$GOCACHE" "$GOMODCACHE"
"""


def parse_job(output, seconds, *, raw=False):
    (
        rev,
        host,
        passed,
        before,
        after,
        comp,
        vet,
        link,
        sha,
        mod,
        archive,
        boot,
        tool,
        action,
    ) = output.split()
    return {
        "revision": rev,
        "container": host,
        "tests": int(passed),
        "seconds": seconds,
        "cpu_s": None if raw else (int(after) - int(before)) / 1e6,
        "compile": int(comp),
        "vet": int(vet),
        "link": int(link),
        "product": sha,
        "module_inode": mod,
        "dependency_inode": archive,
        "boot": boot,
        "toolchain_inode": tool,
        "dependency": action,
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    runtime = p.add_mutually_exclusive_group(required=True)
    runtime.add_argument("--endpoint", help="Docker Unix socket URI")
    runtime.add_argument(
        "--bundle", help="Published 64-hex OCI bundle ID on the native guest"
    )
    runtime.add_argument(
        "--ubuntu", help="Lima instance with the identical Linux Go toolchain"
    )
    p.add_argument(
        "--workspace",
        help="Ubuntu directory containing the unpacked fixture under source/",
    )
    p.add_argument("--image", help="Immutable Docker fixture ID")
    p.add_argument("--scope", required=True)
    p.add_argument(
        "--runtime",
        choices=("runc", "crun", "youki"),
        default="runc",
        help="Executable selected for a native session",
    )
    p.add_argument("--clients", type=int, default=20)
    p.add_argument(
        "--active",
        type=int,
        help="Limit simultaneous Docker jobs while keeping the same total count",
    )
    p.add_argument("--same", action="store_true")
    p.add_argument(
        "--handle",
        help="Use a prepared Micropod native session for an identical-revision batch",
    )
    p.add_argument(
        "--warm-cli", help="Include a call to this Micropod CLI's warm-go in the clock"
    )
    p.add_argument(
        "--prime",
        action="store_true",
        help="Include equivalent compile-only test and vet priming on a peer",
    )
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    if not (
        1 <= args.clients <= 64 and re.fullmatch("[a-z0-9][a-z0-9_-]{0,62}", args.scope)
    ):
        p.error("Expected 1–64 clients and a valid cache scope")
    if args.active and (
        args.ubuntu
        or args.handle
        or args.bundle
        or not 1 <= args.active <= args.clients
    ):
        p.error("--active requires Docker and a limit within the batch size")
    if args.handle and (not args.endpoint or not args.same):
        p.error("--handle requires a worker --endpoint and --same")
    if args.bundle and (
        not re.fullmatch("[a-f0-9]{64}", args.bundle) or not args.same or args.warm_cli
    ):
        p.error("--bundle requires a valid ID and --same")
    if args.runtime != "runc" and not (args.bundle or args.handle):
        p.error("--runtime selects the OCI executable for --bundle or --handle")
    if (
        (args.warm_cli and (args.ubuntu or args.prime))
        or (args.endpoint and not args.image)
        or (args.ubuntu and not args.workspace)
    ):
        p.error(
            "Select one priming mode and supply the matching image or Ubuntu workspace"
        )
    n = args.clients
    warm = []
    if args.ubuntu:
        lines = call(
            [
                "limactl",
                "shell",
                "--workdir",
                "/",
                "--",
                args.ubuntu,
                "sudo",
                "-n",
                "bash",
                "-c",
                RAW,
                "bash",
                args.workspace,
                args.scope,
                str(n),
                str(int(args.same)),
                JOB,
                str(int(args.prime)),
            ]
        ).splitlines()
        start, primed, stop = [int(v) / 1e9 for v in lines[0].split()]
        jobs = [
            parse_job(lines[1 + 2 * i], int(lines[2 + 2 * i]) / 1e9, raw=True)
            for i in range(n)
        ]
        usage = lines[1 + 2 * n :]
        session_s = None
    else:
        engine = ["docker", "--host", args.endpoint]
        mounts = []
        for store, env in [("gomod", "GOMODCACHE"), ("gobuild", "GOCACHE")]:
            volume = f"micropod-ci-scoped-{args.scope}-{store}"
            mounts += [
                "--mount",
                f"type=volume,src={volume},dst=/cache/{store},volume-nocopy",
                "-e",
                f"{env}=/cache/{store}",
            ]
        label = "io.micropod.bench.go-fanout=" + uuid.uuid4().hex
        base = [
            *engine,
            "run",
            "--rm",
            "--network",
            "none",
            "--pull=never",
            "--label",
            label,
        ]
        image = [*mounts, "--entrypoint", "/bin/sh", args.image, "-ec"]

        def job(i):
            begin = time.monotonic()
            output = call(
                [
                    *base,
                    "--cpus",
                    "1",
                    "--memory",
                    "1g",
                    *image,
                    JOB,
                    "sh",
                    f"r{0 if args.same else i:02}",
                ]
            )
            return parse_job(output, time.monotonic() - begin)

        session_s = None
        with ExitStack() as stack:
            if args.handle or args.bundle:
                from bench_ci_startup import WarmSession

                begin = time.monotonic()
                handle = args.handle or f"bundle:{args.bundle}:{args.scope}"
                session = WarmSession(
                    os.environ.get("MICROPOD_BIN", "micropod"),
                    handle,
                    args.runtime,
                    stack,
                )
                session_s = time.monotonic() - begin
            start = time.monotonic()
            if args.warm_cli:
                out = call(
                    [
                        args.warm_cli,
                        "ci",
                        "warm-go",
                        "--cache-scope",
                        args.scope,
                        "--offline",
                        "--trace-tools",
                        args.image,
                    ]
                )
                warm = [json.loads(line) for line in out.splitlines()]
            elif args.prime:
                prime = "go test -c -o /dev/null ./... >/dev/null && go vet ./..."
                if args.bundle:
                    data, streams, _ = session.request(1, ["sh", "-ec", prime])
                    if data["exit"]:
                        raise RuntimeError(
                            str((data["results"], streams[0]["stderr"][-500:]))
                        )
                else:
                    call([*base, *image, prime])
            primed = time.monotonic()
            if args.handle or args.bundle:
                result, streams, _ = session.request(n, ["sh", "-ec", JOB, "sh", "r00"])
                if result["exit"] or len(result["results"]) != n:
                    raise RuntimeError(
                        str(
                            (
                                result["results"][:3],
                                [s["stderr"][-400:] for s in streams][:3],
                            )
                        )
                    )
                jobs = [parse_job(s["stdout"].decode(), None) for s in streams]
                for job, lifecycle in zip(jobs, result["results"], strict=True):
                    if (
                        not lifecycle["id"].startswith(job["container"])
                        or lifecycle["exit"]
                    ):
                        raise ValueError("Native job did not match its OCI lifecycle")
                    job["lifecycle"] = lifecycle
            else:
                try:
                    with ThreadPoolExecutor(max_workers=args.active or n) as executor:
                        jobs = list(executor.map(job, range(n)))
                except (RuntimeError, subprocess.TimeoutExpired) as failure:
                    # A disconnected Docker client can leave an attached job running.
                    try:
                        ids = call(
                            [*engine, "ps", "-aq", "--filter", "label=" + label],
                            timeout=5,
                        ).split()
                        if ids:
                            call([*engine, "rm", "-fv", *ids], timeout=15)
                    except (RuntimeError, subprocess.TimeoutExpired) as cleanup:
                        failure.add_note(
                            f"Could not retire benchmark group {label}: {cleanup}"
                        )
                    raise
            stop = time.monotonic()
            accounting = (
                'du -sB1 "$GOCACHE" "$GOMODCACHE"; du -sb "$GOCACHE" "$GOMODCACHE"'
            )
            if args.bundle:
                data, streams, _ = session.request(1, ["sh", "-ec", accounting])
                if data["exit"]:
                    raise RuntimeError(str(data["results"]))
                usage = streams[0]["stdout"].decode().splitlines()
            else:
                usage = call([*base, *image, accounting]).splitlines()

    for field, expected in (
        ("product", 1 if args.same else n),
        ("container", n),
        ("module_inode", 1),
        ("dependency_inode", 1),
        ("dependency", 1),
        ("boot", 1),
    ):
        if len({j[field] for j in jobs}) != expected:
            raise ValueError(f"Unexpected number of distinct {field} values")
    record = {
        "image": args.image,
        "endpoint": args.endpoint,
        "ubuntu": args.ubuntu,
        "scope": args.scope,
        "clients": n,
        "same": args.same,
        "active": args.active or n,
        "session_s": session_s,
        "warm": warm,
        "warm_s": primed - start,
        "jobs_s": stop - primed,
        "seconds": stop - start,
        "usage": usage,
        "jobs": jobs,
    }
    if args.bundle or args.handle:
        record.update(bundle=args.bundle, runtime=args.runtime)
    args.output.write_text(json.dumps(record, indent=2) + "\n")
    print(
        json.dumps(
            {
                "seconds": record["seconds"],
                "compile": sum(j["compile"] for j in jobs),
                "vet": sum(j["vet"] for j in jobs),
                "link": sum(j["link"] for j in jobs),
                "usage": usage,
            }
        )
    )


if __name__ == "__main__":
    main()
