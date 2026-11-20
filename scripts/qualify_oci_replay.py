#!/usr/bin/env python3
"""Record the offline job contract with stock Docker and replay it on Micropod's OCI path."""

import argparse
import base64
import gzip
import hashlib
import io
import json
import os
import re
import shlex
import subprocess
import tarfile
import tempfile
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from pathlib import Path

from bench_ci_startup import WarmSession, native_client
from bench_fresh_go import GO_ENV, ROOT, Engine, Fixture, execute, require
from ci_benchmark_store import DEFAULT_DB, store

CASES = {
    "streams": "printf 'out-one\\nout-two\\n'; printf 'err-one\\n' >&2",
    "failure": "printf 'before failure\\n'; printf 'diagnostic\\n' >&2; exit 41",
    "arguments": """test "$1" = 'two words' && test "$2" = '--literal' && printf 'argv preserved\\n'""",
    "workspace": """pwd; test ! -e .job-private; umask 077; echo own >.job-private; stat -c '%a' .job-private; cat .job-private""",
    "limits": """cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max; test "$$" = 1""",
    "policy": """grep -E '^(CapEff|CapBnd|NoNewPrivs|Seccomp):' /proc/self/status; test ! -S /var/run/docker.sock; test ! -e /opt/ci/template.json""",
    "network": """ls /sys/class/net; cat /sys/class/net/lo/flags; test "$(cat /etc/hostname)" = "$(cat /proc/sys/kernel/hostname)" """,
    "shared-module": """sha256sum "$GOMODCACHE/cache/download/example.test/shared/@v/v1.0.0.zip" """,
    "go-product": """test ! -e app; go build -trimpath -buildvcs=false -o app .; sha256sum app; ./app""",
}
PROOF = r"""
test "$$" = 1; test ! -e .job-private; test ! -e /opt/ci/template.json; test ! -S /var/run/docker.sock
printf '%s' "$HOSTNAME" >.job-private
barrier="$GOMODCACHE/.oci-proof-$1"; mkdir -p "$barrier"; touch "$barrier/$HOSTNAME"
n=0; expected=$2
while :; do
    set -- "$barrier"/*
    [ "$#" -ge "$expected" ] && break
    n=$((n+1)); test "$n" -lt 1200; sleep .05
done
test "$(cat .job-private)" = "$HOSTNAME"
line=$HOSTNAME
for ns in pid mnt net uts ipc cgroup; do line="$line $(readlink "/proc/self/ns/$ns")"; done
inode=$(stat -c '%i' "$GOMODCACHE/cache/download/example.test/shared/@v/v1.0.0.zip")
printf '%s %s\n' "$line" "$inode"
"""


def adapter(path, cmd):
    lines = ["#!/bin/sh", "set -eu", 'case "${1:-}" in']
    for name, shell in CASES.items():
        lines.append(
            name + ") exec " + shlex.join([*cmd, "sh", "-ec", shell, "sh", "two words", "--literal"]) + " ;;"
        )
    lines += ['*) echo "Unknown qualification case" >&2; exit 2 ;;', "esac"]
    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o700)


def cancel_active(session):
    request = {"id": "cancel", "clients": 2, "args": ["sh", "-ec", "echo active; exec sleep 90"]}
    session.proc.stdin.write((json.dumps(request) + "\n").encode())
    session.proc.stdin.flush()
    jobs = set()
    while len(jobs) < 2:
        frame = session.receive()
        require(
            frame["type"] == "stdout" and base64.b64decode(frame["data"]) == b"active\n",
            "Unexpected cancellation probe",
        )
        jobs.add(frame["job"])
    begin = time.monotonic()
    session.close()
    elapsed = time.monotonic() - begin
    require(elapsed < 15, "Cancellation did not terminate active payloads")
    return elapsed


def replay_bundle(args, record):
    """Replay the same checked-in bytes with no Docker engine or recorder installed."""
    import tomllib

    selector = f"bundle:{args.bundle}:{args.scope}"
    record.update(
        bundle=args.bundle, scope=args.scope, corpus_sha256=hashlib.sha256(args.corpus.read_bytes()).hexdigest()
    )
    cases = record["replay"] = {}
    with ExitStack() as stack:
        archive = stack.enter_context(tarfile.open(args.corpus, "r:gz"))
        session = WarmSession(str(args.micropod), selector, args.runtime, stack)
        for name, command in CASES.items():
            expected = {}
            for ext in ("stdout", "stderr", "toml"):
                member = archive.getmember(f"rust/app-cases/{name}.{ext}")
                require(member.isfile() and member.size <= 65536, "Invalid case member")
                expected[ext] = archive.extractfile(member).read()
            status = tomllib.loads(expected["toml"].decode())["status"]["code"]
            result, streams, _ = session.request(1, ["sh", "-ec", command, "sh", "two words", "--literal"])
            cases[name] = {
                "exit": result["exit"],
                "expected_exit": status,
                "stdout_matches": streams[0]["stdout"] == expected["stdout"],
                "stderr_matches": streams[0]["stderr"] == expected["stderr"],
            }
        n = args.isolation_clients
        barrier = record["run"]
        try:
            data, streams, _ = session.request(n, ["sh", "-ec", PROOF, "sh", barrier, str(n)])
            rows = [v["stdout"].decode().split() for v in streams]
            require(data["exit"] == 0 and all(len(row) == 8 for row in rows), "Incomplete namespace proof")
            require(
                all(len({row[i] for row in rows}) == n for i in range(7)), "Jobs shared identity or namespace"
            )
            require(len({row[-1] for row in rows}) == 1, "Jobs used different module archives")
            record["simultaneous"] = rows
        finally:
            done, _, _ = session.request(
                1, ["sh", "-ec", 'rm -r -- "$GOMODCACHE/.oci-proof-$1"', "sh", barrier]
            )
            require(done["exit"] == 0, "Could not retire the qualification barrier")
        record["cancel_s"] = cancel_active(session)
    require(
        all(
            c["stdout_matches"] and c["stderr_matches"] and c["exit"] == c["expected_exit"]
            for c in cases.values()
        ),
        "Recorded Docker results differ",
    )
    record["passed"] = True


def run(args, r, temp):
    cli = str(args.micropod.resolve())
    helper = str(ROOT / "ci/oci-batch.sh")
    status = json.loads(execute([cli, "ci", "status"]).stdout)
    e = Engine("micropod", status["endpoint"], cli, r["run"])
    env = dict(os.environ, **GO_ENV, MICROPOD_BIN=cli, MICROPOD_OCI_RUNTIME=args.runtime)
    # The recorder works in a synthetic project containing only these two known adapters.
    with ExitStack() as stack:
        e.setup(args.image, stack)
        checkout = Fixture(temp, e.lock).workspace("checkout")
        source = execute([cli, "ci", "snapshot", args.image, str(checkout)]).stdout.strip()
        handle = execute([helper, "prepare", source, e.scope], env=env).stdout.strip()
        stack.callback(execute, [helper, "forget", handle], env=env)
        flags = [x for k, v in GO_ENV.items() for x in ("-e", k + "=" + v)]
        docker = [
            cli,
            "ci",
            "run",
            "--cache",
            "go",
            "--cache-scope",
            e.scope,
            "--cpus",
            "1",
            "--memory",
            "1g",
            "--network",
            "none",
            "--pull=never",
            *flags,
            source,
        ]
        candidate = [helper, "run", handle, "1"]
        project = temp / "contract"
        project.mkdir()
        original = project / "docker-reference"
        other = project / "oci-candidate"
        worker_env = [
            "env",
            "MICROPOD_CI_HOME=" + str(Path(status["endpoint"].removeprefix("unix://")).parent),
        ]
        if os.environ.get("MICROPOD_OCI_CLIENT"):
            worker_env.append("MICROPOD_OCI_CLIENT=" + os.environ["MICROPOD_OCI_CLIENT"])
        if os.environ.get("MICROPOD_OCI_POLICY"):
            worker_env.append("MICROPOD_OCI_POLICY=" + os.environ["MICROPOD_OCI_POLICY"])
        adapter(original, [*worker_env, *docker])
        adapter(
            other,
            [
                *worker_env,
                "MICROPOD_BIN=" + cli,
                "MICROPOD_OCI_RUNTIME=" + args.runtime,
                *[k + "=" + v for k, v in GO_ENV.items()],
                *candidate,
            ],
        )
        inputs = temp / "cases.jsonl"
        inputs.write_text("".join(json.dumps({"name": k, "args": [k]}) + "\n" for k in CASES))
        tool = str(args.rust_anything.resolve())
        r.update(
            tool=execute([tool, "--version"]).stdout.strip(),
            tool_sha256=hashlib.sha256(Path(tool).read_bytes()).hexdigest(),
            worker=status,
            source=source,
            reference={},
        )
        corpus = project / "rust/app-cases"
        if args.corpus:
            corpus.mkdir(parents=True)
            with tarfile.open(args.corpus) as archive:
                for member in archive.getmembers():
                    name = Path(member.name).name
                    if member.name != "rust/app-cases/" + name or not member.isfile() or member.size > 65536:
                        raise ValueError("Unexpected recorded case member")
                    (corpus / name).write_bytes(archive.extractfile(member).read())
            require(
                {f.stem for f in corpus.glob("*.toml")} == set(CASES),
                "Archived cases differ",
            )
            r["corpus_sha256"] = hashlib.sha256(args.corpus.read_bytes()).hexdigest()
        else:
            record = execute(
                [
                    tool,
                    "app",
                    "record",
                    str(project),
                    "--no-traps",
                    "--timeout",
                    "30",
                    "--inputs",
                    str(inputs),
                    "--",
                    str(original),
                ],
                env=env,
            )
            r["record_output"] = record.stdout
        r["cases"] = {
            f.name: f.read_text()
            for f in sorted(corpus.iterdir())
            if f.is_file() and f.suffix in (".toml", ".stdin", ".stdout", ".stderr", ".json")
        }
        manifest = json.loads(r["cases"]["rust-anything.json"])
        manifest["run"] = ["./docker-reference"]
        r["cases"]["rust-anything.json"] = json.dumps(manifest, indent=2) + "\n"
        # Retain the actual byte streams and exit codes independent of the recorder's automatic normalization.
        for name in CASES:
            p = subprocess.run(
                [str(original), name],
                env=env,
                capture_output=True,
                timeout=40,
                check=False,
            )
            q = subprocess.run(
                [str(other), name],
                env=env,
                capture_output=True,
                timeout=40,
                check=False,
            )
            require(
                (p.returncode, p.stdout, p.stderr) == (q.returncode, q.stdout, q.stderr),
                "Raw contract difference: " + name + repr((p.stderr, q.stderr)),
            )
            r["reference"][name] = {
                "exit": p.returncode,
                "stdout": p.stdout.decode(),
                "stderr": p.stderr.decode(),
            }
        replay = execute(
            [
                tool,
                "app",
                "replay",
                str(project),
                "--timeout",
                "30",
                "--build",
                str(other),
                "--json",
            ],
            env=env,
        )
        r["replay"] = json.loads(replay.stdout)
        require(
            r["replay"]["passed"] == r["replay"]["total"] == len(CASES) and r["replay"]["skipped"] == 0,
            "Incomplete behavior replay",
        )
        # A deliberately different program must be rejected by the same recorder.
        broken = project / "wrong-exit"
        broken.write_text("#!/bin/sh\nexit 0\n")
        broken.chmod(0o700)
        diff = subprocess.run(
            [
                tool,
                "app",
                "replay",
                str(project),
                "--timeout",
                "30",
                "--build",
                str(broken),
                "--json",
            ],
            env=env,
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
        require(diff.returncode != 0, "Replay accepted a wrong exit and missing output")
        r["negative"] = json.loads(diff.stdout)
        # Check relationships between live jobs, which a single-process byte transcript cannot express.
        clients = args.isolation_clients
        with ThreadPoolExecutor(max_workers=clients) as pool:
            stock = list(
                pool.map(
                    lambda _: execute(
                        [*docker, "sh", "-ec", PROOF, "sh", "docker", str(clients)],
                        env=env,
                    ).stdout.strip(),
                    range(clients),
                )
            )
        fast = execute(
            [
                helper,
                "run",
                handle,
                str(clients),
                "sh",
                "-ec",
                PROOF,
                "sh",
                "oci",
                str(clients),
            ],
            env=env,
        )
        data = {
            k: [v.split() for v in rows] for k, rows in [("docker", stock), ("oci", fast.stdout.splitlines())]
        }
        for rows in data.values():
            require(
                len(rows) == clients and all(len(x) == 8 for x in rows),
                "Malformed namespace evidence",
            )
            require(
                all(len({x[i] for x in rows}) == clients for i in range(7)),
                "Jobs shared a namespace or hostname",
            )
        require(
            len({x[-1] for rows in data.values() for x in rows}) == 1,
            "Go archive was duplicated",
        )
        r["simultaneous"] = data
        session = WarmSession(cli, handle, args.runtime, stack)
        lookup = e.docker + [
            "ps",
            "-q",
            "--no-trunc",
            "--filter",
            "label=io.micropod.oci.handle=" + handle,
        ]
        launcher = execute(lookup).stdout.split()
        socket = str(Path(status["endpoint"].removeprefix("unix://")).with_name("oci.sock"))
        native = not launcher and Path(socket).is_socket()

        def service_status():
            return json.loads(execute([native_client(cli), socket, "status"]).stdout)

        if native:
            r["service_before"] = service_status()
            require(
                r["service_before"]["active_sessions"] == 1,
                "Expected one native session",
            )
            blocked = subprocess.run(
                [helper, "forget", handle], env=env, capture_output=True, timeout=10, check=False
            )
            require(blocked.returncode != 0, "Released live OCI resources")
            if "prepare_hits" in r["service_before"]:
                r["worker_metrics"] = json.loads(execute([cli, "ci", "metrics"]).stdout)
                counts = r["worker_metrics"]["nativeOCI"]
                require(
                    counts["sessionsByScope"].get(e.scope) == 1 and counts["activeSessions"] == 1,
                    "Worker metrics lost the native cache attachment",
                )
            r["active_drain_http"] = execute(
                [
                    "curl",
                    "--silent",
                    "--output",
                    os.devnull,
                    "--write-out",
                    "%{response_code}",
                    "--unix-socket",
                    socket,
                    "--request",
                    "POST",
                    "http://localhost/oci/v1/drain",
                ]
            ).stdout
            require(r["active_drain_http"] == "409", "Worker drained an active session")
        else:
            require(
                len(launcher) == 1,
                "Expected one outer Docker container for this session",
            )
        for name, body in CASES.items():
            done, streams, _ = session.request(1, ["sh", "-ec", body, "sh", "two words", "--literal"])
            ref = r["reference"][name]
            require(
                (done["exit"], streams[0]["stdout"], streams[0]["stderr"])
                == (ref["exit"], ref["stdout"].encode(), ref["stderr"].encode()),
                "Warm session differs on " + name,
            )
        require(
            execute(lookup).stdout.split() == launcher,
            "Docker launcher was replaced between batches",
        )
        r["outer_container"] = None if native else launcher[0]
        if native:
            require(
                service_status() == r["service_before"],
                "Service restarted or opened an extra session",
            )
        r["warm_session_matches"] = len(CASES)
        r["cancel_s"] = cancel_active(session)
        remain = execute(
            e.docker
            + [
                "ps",
                "-a",
                "--filter",
                "label=io.micropod.oci.handle=" + handle,
                "--format",
                "{{.ID}}",
            ]
        ).stdout.strip()
        require(not remain, "Disposable launcher survived session shutdown")
        if native:
            for _ in range(150):
                r["service_after"] = service_status()
                if r["service_after"]["active_sessions"] == 0:
                    break
                time.sleep(0.02)
            require(
                r["service_after"]["active_sessions"] == 0
                and r["service_after"]["pid"] == r["service_before"]["pid"],
                "Native cancellation leaked a session",
            )
        require(
            status == json.loads(execute([cli, "ci", "status"]).stdout),
            "Worker restarted",
        )
    r["passed"] = True


def main():
    p = argparse.ArgumentParser(description=__doc__)
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--image")
    source.add_argument("--bundle", help="Published native OCI bundle containing the recorded fixture")
    p.add_argument("--scope", help="Published cache scope for --bundle")
    p.add_argument("--rust-anything", type=Path)
    p.add_argument("--corpus", type=Path, help="Replay a previously recorded Docker case archive")
    p.add_argument(
        "--isolation-clients",
        type=int,
        choices=range(2, 65),
        metavar="2..64",
        default=4,
    )
    p.add_argument("--runtime", choices=("runc", "crun", "youki"), default="runc")
    p.add_argument("--micropod", type=Path, default=ROOT / ".build/release/micropod")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--database", type=Path, default=DEFAULT_DB)
    args = p.parse_args()
    if args.image and not args.rust_anything:
        p.error("--image needs --rust-anything to run the recorder")
    if args.image and args.runtime == "youki":
        p.error("youki qualification requires --bundle")
    if args.bundle and (
        not args.corpus
        or not re.fullmatch("[0-9a-f]{64}", args.bundle)
        or not re.fullmatch("[a-z0-9][a-z0-9_-]{0,62}", args.scope or "")
    ):
        p.error("--bundle needs an immutable bundle ID, --corpus and --scope")
    r = {"run": uuid.uuid4().hex, "runtime": args.runtime, "passed": False}
    try:
        if args.bundle:
            replay_bundle(args, r)
        else:
            with tempfile.TemporaryDirectory() as d:
                run(args, r, Path(d))
    except BaseException as err:
        r["error"] = str(err)
        raise
    finally:
        args.out.parent.mkdir(exist_ok=True, parents=True)
        args.out.write_bytes(gzip.compress(json.dumps(r).encode(), mtime=0))
        store(args.database, r["run"], "oci-replay", r)
        if r["passed"] and not args.bundle:
            buf = io.BytesIO()
            with tarfile.open(fileobj=buf, mode="w") as tar:
                for name, value in r["cases"].items():
                    data = value.encode()
                    info = tarfile.TarInfo("rust/app-cases/" + name)
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
            args.out.with_name(r["run"] + ".cases.tar.gz").write_bytes(gzip.compress(buf.getvalue(), mtime=0))


if __name__ == "__main__":
    main()
