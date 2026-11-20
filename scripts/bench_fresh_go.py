#!/usr/bin/env python3
"""Time single-use Docker containers, checkout preparation and native Go tool invocations."""

import argparse
import gzip
import hashlib
import json
import os
import platform
import statistics
import subprocess
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from pathlib import Path

from bench_live_kernel import image_config_digest
from bench_package_caches import TOKEN, Fixture
from ci_benchmark_store import DEFAULT_DB, store
from ci_profile_guest import go_tools

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = (ROOT / "scripts/bench_package_caches.py").read_text()
GO_ENV = {
    "GOENV": "off",
    "GOTOOLCHAIN": "local",
    "GOWORK": "off",
    "GOFLAGS": "-trimpath -p=2",
    "GOMAXPROCS": "2",
    "CGO_ENABLED": "0",
    "GOTELEMETRY": "off",
    "GOPROXY": "off",
    "GOSUMDB": "off",
}
IDENTITY = """IFS= read -r boot < /proc/sys/kernel/random/boot_id
IFS= read -r host < /etc/hostname
printf '%s %s\\n' "$boot" "$host"
"""
BUILD = "go build -x -trimpath -buildvcs=false"
BUILD_RUN = BUILD + " -o app .\nexec ./app"
MAKE_SOURCE = """mkdir /tmp/checkout
cd /tmp/checkout
printf '%s' "$1" > go.mod
printf '%s' "$2" > go.sum
printf '%s' "$3" > main.go
"""
RAW = """
n=$1
dir=$(mktemp -d)
i=0
while [ "$i" -lt "$n" ]; do
    mkdir "$dir/$i"
    cp /workspace/go.mod /workspace/go.sum /workspace/main.go "$dir/$i"
    i=$((i+1))
done
begin=$(date +%s%N)
pids=""
i=0
while [ "$i" -lt "$n" ]; do
    (cd "$dir/$i" && go build -x -trimpath -buildvcs=false -o app . 2>log) &
    pids="$pids $!"
    i=$((i+1))
done
for p in $pids; do wait "$p"; done
end=$(date +%s%N)
echo "$((end-begin))"
i=0
while [ "$i" -lt "$n" ]; do
    "$dir/$i/app"
    cat "$dir/$i/log" >&2
    i=$((i+1))
done
"""
LIMITS = ["--cpus", "1", "--memory", "1g"]


def execute(args, *, env=None, timeout=300):
    p = subprocess.run(args, text=True, capture_output=True, env=env, timeout=timeout, check=False)
    if p.returncode:
        raise RuntimeError(f"{args[0]} returned {p.returncode}: {p.stderr[-2000:]}")
    return p


def timed(func):
    start = time.monotonic()
    result = func()
    return result, time.monotonic() - start


def require(condition, message):
    if not condition:
        raise ValueError(message)


class Engine:
    def __init__(self, name, endpoint, cli, token):
        self.name = name
        self.endpoint = endpoint
        self.docker = ["docker", "--host", endpoint]
        self.runner = [cli, "ci", "run"] if name == "micropod" else self.docker + ["run", "--rm"]
        self.label = "io.micropod.go-series=" + token
        self.scope = "go-series-" + token
        self.volumes = {k: f"micropod-ci-scoped-{self.scope}-{k}" for k in ["npm", "gomod", "gobuild"]}
        self.events = {}
        self.errors = []

    def mounts(self, legacy=False):
        result = []
        for name, var, old in [
            ("gomod", "GOMODCACHE", "go-mod-cache"),
            ("gobuild", "GOCACHE", "go-build-cache"),
            ("npm", "npm_config_cache", "npm-cache"),
        ]:
            if not legacy and name == "npm":
                continue
            path = "/caches/" + old if legacy else "/cache/" + name
            result += [
                "--mount",
                f"type=volume,src={self.volumes[name]},dst={path},volume-nocopy",
                "-e",
                f"{var}={path}",
            ]
        return result

    def run(self, image, cmd, flags=(), *, create=False):
        runner = self.runner
        if create:
            runner = (
                [self.runner[0], "ci", "create"]
                if self.name == "micropod"
                else self.docker + ["create", "--rm"]
            )
        return execute(
            [
                *runner,
                *flags,
                "--pull=never",
                "--network",
                "none",
                "--label",
                self.label,
                image,
                *cmd,
            ]
        )

    def setup(self, image, stack):
        info = json.loads(execute(self.docker + ["info", "--format", "{{json .}}"]).stdout)
        self.info = {
            k: info[k]
            for k in (
                "ID",
                "ServerVersion",
                "KernelVersion",
                "NCPU",
                "MemTotal",
                "DefaultRuntime",
            )
        }
        self.boot = self.run(image, ["cat", "/proc/sys/kernel/random/boot_id"]).stdout.strip()
        self.refs = {"base": image}
        for v in self.volumes.values():
            execute(self.docker + ["volume", "create", "--label", self.label, v])
            stack.callback(execute, self.docker + ["volume", "rm", v])

        def remove_remaining():
            ids = execute(self.docker + ["ps", "-aq", "--filter", "label=" + self.label]).stdout.split()
            if ids:
                execute(self.docker + ["rm", "-f", *ids])

        # An interrupted Docker client may leave a created container holding a fixture volume.
        stack.callback(remove_remaining)
        seed = json.loads(
            self.run(
                image,
                ["python3", "-c", FIXTURE, "container", "seed", "null"],
                self.mounts(True),
            ).stdout
        )
        self.lock = seed["lock"]
        self.seed = seed
        self.run(
            image,
            ["python3", "-c", FIXTURE, "container", "empty", json.dumps(self.lock)],
            ["--tmpfs", "/caches"],
        )
        event = subprocess.Popen(
            self.docker
            + [
                "events",
                "--since",
                str(int(time.time())),
                "--filter",
                "type=container",
                "--filter",
                "label=" + self.label,
                "--format",
                "{{json .}}",
            ],
            stdout=subprocess.PIPE,
            text=True,
        )

        def collect():
            try:
                for line in event.stdout:
                    rec = json.loads(line)
                    key = rec["Actor"]["Attributes"].get("io.micropod.go-job")
                    if key and rec["Action"] in ("create", "start", "die", "destroy"):
                        self.events.setdefault(key, {})[rec["Action"]] = (
                            rec["Actor"]["ID"],
                            rec["timeNano"],
                        )
            except (OSError, ValueError, KeyError, TypeError) as error:
                self.errors.append(str(error))

        thread = threading.Thread(target=collect, daemon=True)
        thread.start()

        def finish():
            event.terminate()
            event.wait(timeout=10)
            thread.join(timeout=5)
            event.stdout.close()

        stack.callback(finish)

    def audit(self):
        return json.loads(
            self.run(
                self.refs["base"],
                ["python3", "-c", FIXTURE, "container", "audit", json.dumps(self.lock)],
                self.mounts(True),
            ).stdout
        )


def transfer(source, peer, tags, directory):
    # Both engines receive the very same checkout and output image, including its OCI config and timestamps.
    with tempfile.TemporaryFile(dir=directory) as archive:
        subprocess.run(
            source.docker + ["image", "save", *tags],
            stdout=archive,
            check=True,
            timeout=300,
        )
        archive.seek(0)
        subprocess.run(
            peer.docker + ["image", "load", "--quiet"],
            stdin=archive,
            stdout=subprocess.DEVNULL,
            check=True,
            timeout=300,
        )


def scene(engine, mode, n, files, key, *, create=False):
    crun = mode.startswith("crun-")
    workload = mode.removeprefix("crun-").removeprefix("group-").removeprefix("staged-")
    flags = ["--label", "io.micropod.go-job=" + key]
    if mode.startswith("group-"):
        flags += [
            "--annotation",
            "io.containerd.runc.v2.group=micropod-ci-" + engine.scope,
        ]
    if crun:
        flags += ["--runtime", "micropod-crun"]
    if workload != "raw":
        flags += LIMITS

    def invoke(image, command, options):
        return engine.run(image, command, options, create=create)

    if workload == "legacy":
        return invoke(
            engine.refs["base"],
            ["python3", "-c", FIXTURE, "container", "go", json.dumps(engine.lock)],
            flags + engine.mounts(True),
        )
    if workload == "launch":
        return invoke(engine.refs["source"], ["sh", "-ec", IDENTITY + "echo launched"], flags)
    env = [v for k, val in GO_ENV.items() for v in ("-e", k + "=" + val)]
    flags += engine.mounts() + env
    if workload == "raw":
        return invoke(engine.refs["source"], ["sh", "-ec", IDENTITY + RAW, "sh", str(n)], flags)
    if workload == "direct":
        return invoke(
            engine.refs["base"],
            ["sh", "-ec", IDENTITY + MAKE_SOURCE + BUILD_RUN, "sh", *files],
            flags,
        )
    image = engine.refs["source" if workload == "source" else "output"]
    return invoke(image, ["sh", "-ec", IDENTITY + BUILD_RUN], flags)


def measure(engine, mode, n, files, rep):
    start = time.monotonic()
    workload = mode.removeprefix("crun-").removeprefix("group-").removeprefix("staged-")

    keys = [uuid.uuid4().hex for _ in range(1 if workload == "raw" else n)]
    created = {}
    prepare_s = 0.0

    def prepare(key):
        reply = scene(engine, mode, n, files, key, create=True)
        created[key] = reply.stdout.strip()

    def one(key):
        begin = time.monotonic()
        if key in created:
            command = [engine.runner[0], "ci", "docker"] if engine.name == "micropod" else engine.docker
            reply = execute([*command, "start", "--attach", created[key]])
        else:
            reply = scene(engine, mode, n, files, key)
        row = {
            "job": key,
            "start_s": begin - start,
            "client_s": time.monotonic() - begin,
        }
        if workload == "legacy":
            data = json.loads(reply.stdout)
            require(
                data["boot"] == engine.boot and data["verified"] == "go",
                "Legacy Go benchmark failed",
            )
            return row
        identity, *lines = reply.stdout.splitlines()
        boot, hostname = identity.split()
        require(boot == engine.boot, "The measured Linux boot changed")
        row["hostname"] = hostname
        if workload == "raw":
            row["go_s"] = int(lines.pop(0)) / 1e9
        expected = ["launched"] if workload == "launch" else [TOKEN] * (n if workload == "raw" else 1)
        require(lines == expected, "Unexpected product or number of jobs")
        tools = go_tools(reply.stderr)
        expected_links = n if workload == "raw" else int(workload in ("direct", "source"))
        require(
            tools == {"compile": 0, "asm": 0, "link": expected_links},
            f"{mode} unexpected Go tools: {tools}",
        )
        return dict(row, **tools)

    try:
        with ThreadPoolExecutor(max_workers=len(keys)) as workers:
            if mode.startswith("staged-"):
                list(workers.map(prepare, keys))
                require(
                    len(set(created.values())) == n,
                    "Expected fresh, unstarted Docker containers",
                )
                prepare_s = time.monotonic() - start
            dispatch = time.monotonic()
            jobs = list(workers.map(one, keys))
        finished = time.monotonic()
        wall = finished - start
    except BaseException:
        if created:
            subprocess.run(
                engine.docker + ["rm", "-f", *created.values()],
                capture_output=True,
                timeout=45,
                check=False,
            )
        raise
    if workload != "legacy":
        require(len({j["hostname"] for j in jobs}) == len(jobs), "A container was reused")
    batch = {
        "engine": engine.name,
        "mode": mode,
        "round": rep,
        "clients": n,
        "seconds": jobs[0].get("go_s", wall),
        "host_wall_s": wall,
        "prepare_s": prepare_s,
        "dispatch_s": finished - dispatch,
        "jobs": jobs,
        "host_load": os.getloadavg(),
    }
    print(f"{rep} {engine.name} {mode} {n}: {batch['seconds']:.3f}s", flush=True)
    return batch


def lifecycles(engine, batches):
    jobs = [j for b in batches if b["engine"] == engine.name for j in b["jobs"]]
    until = time.monotonic() + 12
    while any("destroy" not in engine.events.get(j["job"], {}) for j in jobs) and time.monotonic() < until:
        time.sleep(0.05)
    require(not engine.errors, str(engine.errors))
    ids = set()
    for job in jobs:
        events = engine.events.get(job["job"], {})
        require(
            set(events) == {"create", "start", "die", "destroy"},
            "Missing measured Docker events",
        )
        ident = events["start"][0]
        require(
            ident not in ids and ident.startswith(job.get("hostname", "")),
            "Container identity mismatch",
        )
        ids.add(ident)
        job.update(container=ident, lifecycle_ns={e: row[1] for e, row in events.items()})
    for batch in batches:
        if batch["engine"] == engine.name and batch["mode"].startswith("staged-"):
            stamps = [job["lifecycle_ns"] for job in batch["jobs"]]
            require(
                max(v["create"] for v in stamps) <= min(v["start"] for v in stamps),
                "A staged container started before the whole batch had been created",
            )
    return len(ids)


def preparation_bursts(args, record, directory):
    cli = str(args.micropod.resolve())
    status = json.loads(execute([cli, "ci", "status"]).stdout)
    engine = Engine("micropod", status["endpoint"], cli, record["run"])
    env = dict(os.environ, **GO_ENV, MICROPOD_BIN=cli, MICROPOD_CI_GO_SCOPE=engine.scope)
    record.update(worker=status, clients=args.clients, rounds=args.rounds, batches=[])
    with ExitStack() as stack:
        engine.setup(args.image, stack)
        fixture = Fixture(directory, engine.lock)
        for rep in range(1, args.rounds + 1):
            for n in args.clients:
                checkout = fixture.workspace(f"checkout-{rep}-{n}")
                with (checkout / "main.go").open("a") as src:
                    src.write(f"\n// Distinct revision {record['run']} {rep} {n}\n")
                command = [
                    str(ROOT / "ci/prepare-go-workspace.sh"),
                    args.image,
                    str(checkout),
                    "app",
                ]

                def prepare(_, command=command, build_env=env):
                    reply, seconds = timed(lambda: execute(command, env=build_env))
                    (event,) = [
                        json.loads(line)
                        for line in reply.stderr.splitlines()
                        if line.startswith('{"event":"ci.go.prepare",')
                    ]
                    require(
                        event["image"] == reply.stdout.strip(),
                        "Preparation result differs from event",
                    )
                    return dict(event, seconds=seconds)

                since = str(int(time.time()))
                with ThreadPoolExecutor(max_workers=n) as workers:
                    jobs, elapsed = timed(lambda n=n: list(workers.map(prepare, range(n))))
                require(
                    sum(j["cache"] == "miss" for j in jobs) == 1
                    and sum(j["cache"] == "hit" for j in jobs) == n - 1,
                    "Expected exactly one linker job",
                )
                first = jobs[0]
                require(
                    all((j["image"], j["key"]) == (first["image"], first["key"]) for j in jobs),
                    "Concurrent callers received different images or cache keys",
                )
                tag = "micropod-internal/ci-go-output:" + first["key"]
                source = execute([cli, "ci", "snapshot", args.image, str(checkout)]).stdout.strip()
                stack.callback(
                    execute,
                    engine.docker
                    + [
                        "image",
                        "rm",
                        "micropod-internal/ci-workspace:" + source.removeprefix("sha256:"),
                    ],
                )
                stack.callback(execute, engine.docker + ["image", "rm", tag])
                again = prepare(None)
                require(
                    again["image"] == first["image"] and again["cache"] == "hit",
                    "Repeat missed the image",
                )
                flag_env = [v for k, val in GO_ENV.items() for v in ("-e", k + "=" + val)]
                product = engine.run(
                    first["image"],
                    [
                        "sh",
                        "-ec",
                        "sha256sum main.go app; go tool buildid app\n"
                        + BUILD
                        + " -o app .\nsha256sum app; go tool buildid app; exec ./app",
                    ],
                    engine.mounts() + flag_env,
                )
                source_sha, before, before_id, after, after_id, token = product.stdout.splitlines()
                tools = go_tools(product.stderr)
                if (
                    source_sha.split()[0] != hashlib.sha256((checkout / "main.go").read_bytes()).hexdigest()
                    or token != TOKEN
                    or first["binary_sha256"] != before.split()[0]
                    or before != after
                    or before_id != after_id
                    or any(tools.values())
                ):
                    record["failed_preparation"] = {
                        "round": rep,
                        "clients": n,
                        "result": first,
                        "output": product.stdout,
                        "tools": tools,
                        "commands": product.stderr,
                    }
                    raise ValueError(f"Prepared image output or build ID changed: {tools} {product.stdout}")
                creates = execute(
                    engine.docker
                    + [
                        "events",
                        "--since",
                        since,
                        "--until",
                        str(int(time.time()) + 1),
                        "--filter",
                        "type=container",
                        "--filter",
                        "event=create",
                        "--filter",
                        "label=io.micropod.ci.go-prepare=" + first["key"],
                        "--format",
                        "{{json .}}",
                    ]
                ).stdout.splitlines()
                creates = [json.loads(line)["Actor"]["ID"] for line in creates]
                require(
                    len(creates) == 1,
                    "Expected one Docker preparation container for all callers",
                )
                record["batches"].append(
                    {
                        "round": rep,
                        "clients": n,
                        "seconds": elapsed,
                        "jobs": jobs,
                        "repeat_s": again["seconds"],
                        "creates": creates,
                        "tools": tools,
                    }
                )
                print(
                    f"{rep} preparation at {n}: {elapsed:.3f}s, one build, repeat {again['seconds']:.3f}s",
                    flush=True,
                )
        changed_flags = dict(env, GOFLAGS=env["GOFLAGS"] + " -tags=micropod_prepare_control")
        changed = prepare(None, build_env=changed_flags)
        stack.callback(
            execute, engine.docker + ["image", "rm", "micropod-internal/ci-go-output:" + changed["key"]]
        )
        repeated = prepare(None, build_env=changed_flags)
        require(
            changed["cache"] == "miss"
            and changed["key"] != first["key"]
            and repeated["cache"] == "hit"
            and repeated["image"] == changed["image"],
            "Go build flag change reused the previous preparation",
        )
        record["settings_control"] = {"original_key": first["key"], "changed": changed, "repeat": repeated}
        nested = prepare(None, command=[*command[:-1], "bin/deep/app"])
        stack.callback(
            execute, engine.docker + ["image", "rm", "micropod-internal/ci-go-output:" + nested["key"]]
        )
        nested_run = engine.run(
            nested["image"],
            ["sh", "-ec", BUILD + " -o bin/deep/app .\nexec ./bin/deep/app"],
            engine.mounts() + flag_env,
        )
        require(
            nested["cache"] == "miss"
            and nested["key"] != first["key"]
            and nested_run.stdout.strip() == TOKEN
            and not any(go_tools(nested_run.stderr).values()),
            "Nested executable was missing or relinked",
        )
        record["nested_output_control"] = nested
        require(json.loads(execute([cli, "ci", "status"]).stdout) == status, "Micropod identity changed")


def bench(args, record, directory):
    cli = str(args.micropod.resolve())
    status = json.loads(execute([cli, "ci", "status"]).stdout)
    token = record["run"]
    mic = Engine("micropod", status["endpoint"], cli, token)
    peer = Engine("orbstack", "unix://" + str(args.orbstack.resolve()), cli, token)
    env = dict(os.environ, **GO_ENV, MICROPOD_BIN=cli, MICROPOD_CI_GO_SCOPE=mic.scope)
    record.update(
        worker=status,
        cli_sha256=hashlib.sha256(args.micropod.read_bytes()).hexdigest(),
        host=platform.platform(),
        rounds=args.rounds,
        clients=args.clients,
        preparation={},
        batches=[],
        fixture_sha256=hashlib.sha256(FIXTURE.encode()).hexdigest(),
        engines={},
    )
    with ExitStack() as stack:
        for e in (mic, peer):
            e.setup(args.image, stack)
            record["engines"][e.name] = {
                "server": e.info,
                "boot": e.boot,
                "seed": e.seed,
            }
        require(
            mic.lock == peer.lock
            and mic.info["NCPU"] == peer.info["NCPU"]
            and abs(mic.info["MemTotal"] - peer.info["MemTotal"]) < 128 * 2**20,
            "Unmatched engine budgets or inputs",
        )
        src = Fixture(directory, mic.lock).workspace("checkout")
        files = [(src / name).read_text() for name in ("go.mod", "go.sum", "main.go")]
        require(
            not (src / "app").exists(),
            "The source checkout must begin without an output",
        )
        source, src_s = timed(lambda: execute([cli, "ci", "snapshot", args.image, str(src)]).stdout.strip())
        output, out_s = timed(
            lambda: execute(
                [str(ROOT / "ci/prepare-go-workspace.sh"), args.image, str(src), "app"],
                env=env,
            ).stdout.strip()
        )
        tags = {k: "micropod-internal/go-series:" + token + "-" + k for k in ("source", "output")}
        for k, img in [("source", source), ("output", output)]:
            execute(mic.docker + ["tag", img, tags[k]])
            stack.callback(execute, mic.docker + ["image", "rm", tags[k]])
        _, transport = timed(lambda: transfer(mic, peer, list(tags.values()), directory))
        for tag in tags.values():
            stack.callback(execute, peer.docker + ["image", "rm", tag])
        record["preparation"].update(source_s=src_s, source_and_output_s=out_s, peer_transfer_s=transport)
        for e in (mic, peer):
            for k, v in tags.items():
                e.refs[k] = v
            digests = {}
            for k, v in e.refs.items():
                info = json.loads(execute(e.docker + ["image", "inspect", v]).stdout)[0]
                require(
                    info["Architecture"] == "arm64" and info["Os"] == "linux",
                    "Expected native ARM64",
                )
                digests[k] = image_config_digest(e.endpoint.removeprefix("unix://"), info["Id"], "arm64")
            er = record["engines"][e.name]
            er["configs"] = digests
            e.run(e.refs["source"], ["sh", "-ec", "test ! -e /workspace/app"])
            er["output_sha256"] = e.run(e.refs["output"], ["sha256sum", "/workspace/app"]).stdout.split()[0]
            # An edit must invalidate the baked executable. The next untouched container must see the original.
            changed = e.run(
                e.refs["output"],
                [
                    "sh",
                    "-ec",
                    """sed -i 's/fmt.Println(shared.Message)/fmt.Println(shared.Message + "-changed")/' main.go
"""
                    + BUILD_RUN,
                ],
                e.mounts() + [v for k, val in GO_ENV.items() for v in ("-e", k + "=" + val)],
            )
            er["edit_tools"] = go_tools(changed.stderr)
            require(
                changed.stdout.strip() == TOKEN + "-changed"
                and er["edit_tools"]["link"] == 1
                and er["edit_tools"]["compile"] > 0,
                "Source edit did not rebuild the executable",
            )
            for mode in ("legacy", "direct", "source", "output"):
                measure(e, mode, 1, files, 0)
            er["before"] = e.audit()
        require(
            record["engines"]["micropod"]["configs"] == record["engines"]["orbstack"]["configs"]
            and record["engines"]["micropod"]["output_sha256"]
            == record["engines"]["orbstack"]["output_sha256"],
            "Peer source or executable digest differed",
        )
        if args.suite == "group":
            # The runc shim exits with its last task. Hold one task across bursts so a short-lived
            # first job cannot shut the shared shim down during another job's create request.
            for e in (mic, peer):
                anchor, seconds = timed(
                    lambda e=e: execute(
                        e.docker
                        + [
                            "run",
                            "-d",
                            "--rm",
                            "--network",
                            "none",
                            "--read-only",
                            "--cap-drop",
                            "ALL",
                            "--pids-limit",
                            "8",
                            "--memory",
                            "16m",
                            "--label",
                            e.label,
                            "--annotation",
                            "io.containerd.runc.v2.group=micropod-ci-" + e.scope,
                            e.refs["base"],
                            "sleep",
                            "2147483647",
                        ]
                    ).stdout.strip()
                )
                stack.callback(execute, e.docker + ["rm", "-f", anchor])
                record["engines"][e.name]["anchor"] = {"id": anchor, "start_s": seconds}
        for rep in range(args.rounds):
            for e in [mic, peer] if rep % 2 == 0 else [peer, mic]:
                if args.suite == "group":
                    modes = [
                        "launch",
                        "group-launch",
                        "source",
                        "group-source",
                        "output",
                        "group-output",
                    ]
                elif args.suite == "staged":
                    modes = ["source", "staged-source", "output", "staged-output"]
                else:
                    modes = ["legacy", "direct", "source", "output", "launch", "raw"]
                    if e is mic:
                        modes += ["crun-launch", "crun-source", "crun-output"]
                levels = args.clients if rep % 2 == 0 else args.clients[::-1]
                for idx, n in enumerate(levels):
                    offset = (rep + idx) % len(modes)
                    for mode in modes[offset:] + modes[:offset]:
                        b = measure(e, mode, n, files, rep + 1)
                        record["batches"].append(b)
        for e in (mic, peer):
            er = record["engines"][e.name]
            er["fresh_containers"] = lifecycles(e, record["batches"])
            er["after"] = e.audit()
            require(
                er["before"]["payload_inodes"] == er["after"]["payload_inodes"]
                and er["before"]["cache_sizes"] == er["after"]["cache_sizes"],
                "Warm cache payload changed",
            )
            require(
                e.run(args.image, ["cat", "/proc/sys/kernel/random/boot_id"]).stdout.strip() == e.boot
                and execute(e.docker + ["info", "--format", "{{.ID}}"]).stdout.strip() == e.info["ID"],
                "Engine restarted",
            )
    require(
        json.loads(execute([cli, "ci", "status"]).stdout) == status,
        "Micropod identity changed",
    )
    record["median_s"] = {}
    for b in record["batches"]:
        times = record["median_s"].setdefault(b["engine"], {}).setdefault(b["mode"], {})
        times[b["clients"]] = statistics.median(
            i["seconds"]
            for i in record["batches"]
            if (i["engine"], i["mode"], i["clients"]) == (b["engine"], b["mode"], b["clients"])
        )


def export_trace(record, path):
    """Each batch has its own lane and aligned engine timestamps relative to its first create."""
    events = []
    cursor_us = 0
    for pid, batch in enumerate(record["batches"], start=1):
        label = f"{batch['engine']} {batch['mode']} / {batch['clients']} jobs / round {batch['round']}"
        events.append(
            {
                "ph": "M",
                "name": "process_name",
                "pid": pid,
                "tid": 0,
                "args": {"name": label},
            }
        )
        first = min(job["lifecycle_ns"]["create"] for job in batch["jobs"])
        for tid, job in enumerate(batch["jobs"], start=1):
            stamp = job["lifecycle_ns"]
            for a, b, name in [
                ("create", "start", "Create to start"),
                ("start", "die", "Running"),
                ("die", "destroy", "Remove"),
            ]:
                events.append(
                    {
                        "ph": "X",
                        "name": name,
                        "pid": pid,
                        "tid": tid,
                        "ts": cursor_us + (stamp[a] - first) // 1000,
                        "dur": (stamp[b] - stamp[a]) // 1000,
                        "args": {
                            "container": job["container"],
                            "go_links": job.get("link"),
                        },
                    }
                )
        cursor_us += max(j["lifecycle_ns"]["destroy"] - first for j in batch["jobs"]) // 1000 + 1000
    path.write_bytes(
        gzip.compress(json.dumps({"traceEvents": events}, separators=(",", ":")).encode(), mtime=0)
    )


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--image", required=True)
    p.add_argument("--suite", choices=["oci", "group", "staged", "preparation"], default="oci")
    p.add_argument("--micropod", type=Path, default=ROOT / ".build/release/micropod")
    p.add_argument("--orbstack", type=Path, default=Path.home() / ".orbstack/run/docker.sock")
    p.add_argument("--clients", type=int, nargs="+", default=[16, 32])
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--database", type=Path, default=DEFAULT_DB)
    args = p.parse_args()
    if (
        not 1 <= args.rounds <= 50
        or len(set(args.clients)) != len(args.clients)
        or any(n < 1 or n > 64 for n in args.clients)
    ):
        p.error("Use unique concurrency levels from 1 to 64 and 1–50 rounds")
    for key in (
        "DOCKER_CONTEXT",
        "DOCKER_TLS_VERIFY",
        "DOCKER_CERT_PATH",
        "BUILDX_BUILDER",
        "DOCKER_HOST",
    ):
        os.environ.pop(key, None)
    args.out.parent.mkdir(exist_ok=True, parents=True)
    record = {"run": uuid.uuid4().hex, "suite": args.suite, "passed": False}
    try:
        with tempfile.TemporaryDirectory(prefix="micropod-go-") as t:
            if args.suite == "preparation":
                preparation_bursts(args, record, Path(t))
            else:
                bench(args, record, Path(t))
                export_trace(record, args.out.parent / (record["run"] + ".trace.json.gz"))
        record["passed"] = True
    except KeyboardInterrupt:
        record["error"] = "Interrupted"
        raise
    except Exception as err:
        record["error"] = str(err)
        raise
    finally:
        raw = (json.dumps(record, separators=(",", ":")) + "\n").encode()
        args.out.write_bytes(gzip.compress(raw, mtime=0) if args.out.suffix == ".gz" else raw)
        store(
            args.database,
            record["run"],
            "go-output-preparation" if args.suite == "preparation" else "fresh-go",
            record,
        )


if __name__ == "__main__":
    main()
