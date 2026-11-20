#!/usr/bin/env python3
"""Compare source-only Go time and attribute fresh Docker startup inside a warm Micropod worker."""

import argparse
import base64
import calendar
import gzip
import hashlib
import json
import os
import queue
import re
import subprocess
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from pathlib import Path

from bench_fresh_go import (
    BUILD_RUN,
    GO_ENV,
    IDENTITY,
    ROOT,
    Engine,
    Fixture,
    execute,
    lifecycles,
    require,
    transfer,
)
from bench_package_caches import TOKEN
from ci_benchmark_store import DEFAULT_DB, store
from ci_profile_guest import go_tools

ALPINE = "alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"
ALPINE_CTR = [
    "--read-only",
    "--network",
    "none",
    "--cap-drop",
    "ALL",
    "-v",
    "/run/docker/containerd/containerd.sock:/observe.sock",
    "-v",
    "/usr/local/bin/ctr:/bin/worker-ctr:ro",
    ALPINE,
    "/bin/worker-ctr",
    "-a",
    "/observe.sock",
    "-n",
    "moby",
]
# One line per real job on every engine. Keep the Go trace in the job's private filesystem.
JOB = r"""
first=$(date +%s%N)
test ! -e app
test -n "$HOSTNAME" || HOSTNAME=$(cat /proc/sys/kernel/hostname)
go build -x -trimpath -buildvcs=false -o app . 2>/tmp/go-trace
counts=$(awk '{for(i=1;i<=NF;i++){if ($i ~ /\/(link|asm|compile)$/ && $(i+1) !~ /^-V(=|$)/){sub(/^.*\//,"",$i); n[$i]++; break}}} END {print n["link"]+0,n["compile"]+0,n["asm"]+0}' /tmp/go-trace)
digest=$(sha256sum app)
result=$(./app)
printf '%s %s %s %s %s %s\n' "$HOSTNAME" "$first" "$counts" "${digest%% *}" "$result" "$(cat /proc/sys/kernel/random/boot_id)"
"""
# Read each fresh job's own cgroup after the product check, using only shell builtins.
CGROUP_SAMPLE = r"""
while read -r name value; do
    case "$name" in usage_usec|nr_throttled|throttled_usec) printf '%s %s\n' "$name" "$value" ;; esac
done < /sys/fs/cgroup/cpu.stat
cpus=unknown
if [ -r /sys/fs/cgroup/cpuset.cpus.effective ]; then IFS= read -r cpus < /sys/fs/cgroup/cpuset.cpus.effective; fi
printf 'cpuset %s\n' "$cpus"
scheduler=-1
if [ -r "/proc/$$/sched" ]; then
    while IFS=: read -r label number; do
        case "$label" in policy*) scheduler=$((number+0)); break ;; esac
    done < "/proc/$$/sched"
fi
printf 'scheduler %d\n' "$scheduler"
for name in cpu io; do
    while read -r kind avg10 avg60 avg300 total; do
        if [ "$kind" = some ]; then printf '%s_pressure_usec %s\n' "$name" "${total#total=}"; break; fi
    done < "/sys/fs/cgroup/$name.pressure"
done
"""
STAGES = [
    "init_prepare",
    "init_commit",
    "writable",
    "docker_create",
    "metadata",
    "task_create",
    "task_start",
    "entry",
]


class CtrEvents:
    def __init__(self, engine, stack):
        self.rows = {}
        self.errors = []
        name = "mp-start-trace-" + uuid.uuid4().hex
        self.proc = subprocess.Popen(
            engine.docker + ["run", "--rm", "--name", name, *ALPINE_CTR, "events"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        def read():
            try:
                for line in self.proc.stdout:
                    date, clock, _, _, namespace, topic, data = line.rstrip().split(" ", 6)
                    if namespace != "moby":
                        continue
                    sec, nanos = clock.split(".")
                    ns = calendar.timegm(time.strptime(date + " " + sec, "%Y-%m-%d %H:%M:%S")) * 10**9 + int(
                        nanos.ljust(9, "0")
                    )
                    obj = json.loads(data)
                    key = obj.get("id") or obj.get("container_id") or obj.get("key", "")
                    ident = key[:64]
                    if not re.fullmatch("[0-9a-f]{64}", ident):
                        continue
                    stage = {
                        "/containers/create": "metadata",
                        "/tasks/create": "task_create",
                        "/tasks/start": "task_start",
                        "/tasks/exit": "task_exit",
                        "/tasks/delete": "task_delete",
                    }.get(topic)
                    if topic == "/snapshot/prepare":
                        stage = "init_prepare" if key.endswith("-init-key") else "writable"
                    if topic == "/snapshot/commit" and key.endswith("-init-key"):
                        stage = "init_commit"
                    if stage:
                        line_data = self.rows.setdefault(ident, {})
                        line_data[stage] = ns
                        if stage == "task_create" and "pid" in obj:
                            line_data["init_pid"] = obj["pid"]
            except (ValueError, KeyError, TypeError) as err:
                self.errors.append(str(err))

        th = threading.Thread(target=read, daemon=True)
        th.start()

        def stop():
            subprocess.run(engine.docker + ["rm", "-f", name], capture_output=True, timeout=20, check=False)
            self.proc.wait(timeout=15)
            th.join(3)
            self.proc.stdout.close()
            self.proc.stderr.close()

        stack.callback(stop)
        for _ in range(100):
            if self.proc.poll() is not None:
                raise RuntimeError(self.proc.stderr.read())
            if (
                name
                in execute(
                    engine.docker + ["ps", "--filter", "name=" + name, "--format", "{{.Names}}"]
                ).stdout
            ):
                break
            time.sleep(0.04)
        time.sleep(0.15)


class KernelTrace:
    def __init__(self, engine, image, stack):
        name = "mp-start-kernel-" + uuid.uuid4().hex
        self.proc = subprocess.Popen(
            engine.docker
            + [
                "run",
                "--name",
                name,
                "--rm",
                "-i",
                "--network",
                "none",
                "--cap-drop",
                "ALL",
                "--cap-add",
                "SYS_PTRACE",
                "--pid",
                "host",
                "--read-only",
                image,
                "python3",
                "-u",
                "-c",
                (ROOT / "scripts/ci_startup_trace_guest.py").read_text(),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        def cleanup():
            if self.proc.poll() is None:
                subprocess.run(
                    engine.docker + ["rm", "-f", name], capture_output=True, timeout=20, check=False
                )
            self.proc.wait(timeout=10)

        stack.callback(cleanup)
        ready = self.proc.stdout.readline()
        if not ready:
            raise RuntimeError(self.proc.stderr.read())
        require(json.loads(ready)["ready"], "The runc process sampler did not become ready")

    def finish(self):
        data, err = self.proc.communicate("", timeout=25)
        require(self.proc.returncode == 0, err)
        return json.loads(data)


def parse_job(line):
    host, first, links, compiles, asm, digest, product, boot = line.split()
    require(
        (links, compiles, asm) == ("1", "0", "0") and product == TOKEN,
        "Go did not run one real warm link: " + line,
    )
    return {
        "hostname": host,
        "entry": int(first),
        "link": 1,
        "sha256": digest,
        "boot": boot,
        "product": product,
    }


def timed_product(stdout, stderr):
    identity, token = stdout.strip().splitlines()
    boot, host = identity.split()
    counts = go_tools(stderr)
    require(
        token == TOKEN and counts == {"link": 1, "compile": 0, "asm": 0},
        f"Incorrect Go product/tools: {token} {counts}",
    )
    return {"hostname": host, "boot": boot, "link": 1, "product": token}


def docker_batch(e, source, n, rep, *, timed=False):
    opts = e.mounts() + [v for k, val in GO_ENV.items() for v in ("-e", k + "=" + val)]

    def one(_):
        key = uuid.uuid4().hex
        begin = time.monotonic()
        p = e.run(
            source,
            ["sh", "-ec", IDENTITY + BUILD_RUN if timed else JOB],
            opts + ["--cpus", "1", "--memory", "1g", "--label", "io.micropod.go-job=" + key],
        )
        row = timed_product(p.stdout, p.stderr) if timed else parse_job(p.stdout.strip())
        row.update(job=key, elapsed=time.monotonic() - begin, finish=time.monotonic())
        return row

    begin = time.monotonic()
    with ThreadPoolExecutor(max_workers=n) as pool:
        rows = list(pool.map(one, range(n)))
    for row in rows:
        row["finish"] -= begin
    return {
        "engine": e.name,
        "mode": "source",
        "clients": n,
        "round": rep,
        "seconds": time.monotonic() - begin,
        "jobs": rows,
    }


class WarmSession:
    def __init__(self, cli, handle, runtime, stack, *, backend=None, policy=None):
        self.runtime = runtime
        env = dict(os.environ, **GO_ENV, MICROPOD_BIN=cli, MICROPOD_OCI_RUNTIME=runtime)
        if backend:
            env["MICROPOD_OCI_BACKEND"] = backend
        if policy:
            env["MICROPOD_OCI_POLICY"] = policy
        self.errors = stack.enter_context(tempfile.TemporaryFile())  # noqa: SIM115 - owned by the session ExitStack
        self.messages = queue.Queue()
        self.proc = subprocess.Popen(
            [str(ROOT / "ci/oci-batch.sh"), "session", handle],
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.errors,
        )

        def read():
            for frame in self.proc.stdout:
                self.messages.put(frame)
            self.messages.put(None)

        threading.Thread(target=read, daemon=True).start()
        stack.callback(self.close)
        require(self.receive()["type"] == "ready", "OCI launcher did not become ready")

    def receive(self):
        line = self.messages.get(timeout=150)
        if line is None:
            self.errors.seek(0)
            raise RuntimeError(self.errors.read().decode(errors="replace"))
        return json.loads(line)

    def close(self):
        if not self.proc.stdin.closed:
            self.proc.stdin.close()
        try:
            self.proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            self.proc.wait(timeout=10)
        self.proc.stdout.close()
        require(self.proc.returncode == 0, "OCI session failed to shut down")

    def request(self, n, argv):
        ident = uuid.uuid4().hex
        streams = [{"stdout": bytearray(), "stderr": bytearray()} for _ in range(n)]
        request = (json.dumps({"id": ident, "clients": n, "args": argv}) + "\n").encode()
        begin = time.monotonic()
        self.proc.stdin.write(request)
        self.proc.stdin.flush()
        while True:
            data = self.receive()
            require(data["id"] == ident, "Frame from another batch")
            if data["type"] == "done":
                break
            if data["type"] == "stdout" and "first_stdout_s" not in streams[data["job"]]:
                streams[data["job"]]["first_stdout_s"] = time.monotonic() - begin
            streams[data["job"]][data["type"]].extend(base64.b64decode(data["data"], validate=True))
        elapsed = time.monotonic() - begin
        return data, streams, elapsed

    def batch(self, n, rep, *, probe=False, trace=False):
        script = JOB if probe or trace else IDENTITY + BUILD_RUN
        if trace:
            script += CGROUP_SAMPLE
        data, streams, elapsed = self.request(n, ["sh", "-ec", script])
        require(data["exit"] == 0 and len(data["results"]) == n, str(data["results"]))
        rows = []
        for j, result in enumerate(data["results"]):
            o = streams[j]["stdout"].decode()
            err = streams[j]["stderr"].decode()
            if trace:
                proof, *lines = o.splitlines()
                row = parse_job(proof)
                values = dict(line.split() for line in lines)
                row["cpuset"] = values.pop("cpuset")
                row["scheduler"] = int(values.pop("scheduler"))
                counters = {k: int(v) for k, v in values.items()}
                require(
                    set(counters)
                    == {
                        "usage_usec",
                        "nr_throttled",
                        "throttled_usec",
                        "cpu_pressure_usec",
                        "io_pressure_usec",
                    },
                    "Incomplete per-job cgroup counters",
                )
                start = result["begin_ns"] + result["setup_ns"]
                require(
                    start <= row["entry"] <= start + result["runtime_ns"],
                    "Inconsistent guest clocks",
                )
                row["cgroup"] = counters
            else:
                row = parse_job(o.strip()) if probe else timed_product(o, err)
            require(
                result["index"] == j and result["id"].startswith(row["hostname"]) and result["exit"] == 0,
                "OCI identity mismatch",
            )
            row.update(
                container=result["id"],
                lifecycle=result,
                first_stdout_s=streams[j].get("first_stdout_s"),
            )
            rows.append(row)
        return {
            "engine": "direct-" + self.runtime,
            "mode": "source",
            "clients": n,
            "round": rep,
            "seconds": elapsed,
            "jobs": rows,
        }


def native_client(cli):
    if path := os.getenv("MICROPOD_OCI_CLIENT"):
        return Path(path)
    local = ROOT / ".build/oci-tools/client"
    return local if local.is_file() else Path(cli).resolve().with_name("micropod-oci")


def warm_preparations(helper, img, tag, scope, handle, env):
    def reuse(ref):
        begin = time.monotonic()
        found = execute([helper, "prepare", ref, scope], env=env).stdout.strip()
        require(found == handle, "Warm preparation duplicated a handle")
        return time.monotonic() - begin

    samples = {img: [], tag: []}
    for i in range(5):
        for ref in (img, tag) if i % 2 else (tag, img):
            samples[ref].append(reuse(ref))
    out = {"native_warm_handle_s": samples[img], "native_tag_handle_s": samples[tag]}
    for name, ref in (("native_concurrent", img), ("native_tag_concurrent", tag)):
        begin = time.monotonic()
        with ThreadPoolExecutor(max_workers=8) as pool:
            out[name + "_handle_s"] = list(pool.map(reuse, [ref] * 8))
        out[name + "_wall_s"] = time.monotonic() - begin
    return out


def run(args, r, directory):
    cli = str(args.micropod.resolve())
    status = json.loads(execute([cli, "ci", "status"]).stdout)
    mic = Engine("micropod", status["endpoint"], cli, r["run"])
    engines = [mic]
    if args.mode in ("paired", "native-paired"):
        engines += [Engine("orbstack", "unix://" + str(args.orbstack.resolve()), cli, r["run"])]
    r.update(
        worker=status,
        engines={},
        batches=[],
        prep={},
        cli_sha256=hashlib.sha256(Path(cli).read_bytes()).hexdigest(),
    )
    with ExitStack() as stack:
        for e in engines:
            e.setup(args.image, stack)
            r["engines"][e.name] = {"info": e.info, "boot": e.boot, "lock": e.lock}
        fixture = Fixture(directory, mic.lock)
        checkout = fixture.workspace("source")
        begin = time.monotonic()
        img = execute([cli, "ci", "snapshot", args.image, str(checkout)]).stdout.strip()
        tag = "micropod-internal/startup-source:" + r["run"]
        execute(mic.docker + ["image", "tag", img, tag])
        stack.callback(execute, mic.docker + ["image", "rm", tag])
        r["prep"]["source_s"] = time.monotonic() - begin
        if len(engines) > 1:
            peer = engines[1]
            transfer(mic, peer, [tag], directory)
            stack.callback(execute, peer.docker + ["image", "rm", tag])
            require(
                mic.lock == peer.lock
                and mic.info["NCPU"] == peer.info["NCPU"] == 4
                and abs(mic.info["MemTotal"] - peer.info["MemTotal"]) < 128 * 2**20,
                "Unmatched VM budgets or cached module",
            )
        for e in engines:
            cfg = execute(e.docker + ["image", "inspect", "--format", "{{.Id}}", tag]).stdout.strip()
            require(cfg == img, "Source image ID differs")
            prime = docker_batch(e, tag, 1, 0)
            r["engines"][e.name].update(source=cfg, product=prime["jobs"][0]["sha256"], before=e.audit())
        observer = CtrEvents(mic, stack) if args.mode == "trace" else None
        kernel = KernelTrace(mic, args.image, stack) if observer else None
        sessions = {}
        arms = [e.name for e in engines] if args.mode in ("paired", "native-paired", "trace") else []
        if args.mode.startswith("native-"):
            variants = [("native", args.policies)]
            if args.mode == "native-paired":
                variants.insert(0, ("docker", ["parallel"]))
            for backend, policies in variants:
                begin = time.monotonic()
                helper = str(ROOT / "ci/oci-batch.sh")
                environment = dict(os.environ, MICROPOD_BIN=cli, MICROPOD_OCI_BACKEND=backend)
                handle = execute([helper, "prepare", img, mic.scope], env=environment).stdout.strip()
                stack.callback(execute, [helper, "forget", handle], env=environment)
                r["prep"][backend + "_handle_s"] = time.monotonic() - begin
                if args.mode == "native-paired":
                    opens = []
                    for _ in range(7):
                        with ExitStack() as probe_stack:
                            begin = time.monotonic()
                            WarmSession(cli, handle, "runc", probe_stack, backend=backend)
                            opens.append(time.monotonic() - begin)
                    r["prep"][backend + "_warm_session_s"] = opens
                    if backend == "native":
                        r["prep"].update(warm_preparations(helper, img, tag, mic.scope, handle, environment))
                for policy in policies:
                    name = backend + "-" + policy
                    begin = time.monotonic()
                    session = WarmSession(cli, handle, "runc", stack, backend=backend, policy=policy)
                    r["prep"][name + "_session_s"] = time.monotonic() - begin
                    sessions[name] = session
                    proof = session.batch(1, 0, probe=True)["jobs"][0]
                    require(
                        proof["sha256"] == r["engines"]["micropod"]["product"] and proof["boot"] == mic.boot,
                        "Native or control product/worker differs",
                    )
                    r["engines"]["direct-" + name] = {
                        "product": proof["sha256"],
                        "boot": proof["boot"],
                    }
                    arms.append("direct-" + name)
            tools = Path(os.environ.get("MICROPOD_CI_OCI_TOOLS", ROOT / ".build/oci-tools/guest"))
            r["native_binary_sha256"] = {
                p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                for p in (
                    tools / "service",
                    tools / "executor",
                    native_client(cli),
                )
            }
        elif args.mode != "trace":
            begin = time.monotonic()
            handle = execute(
                [str(ROOT / "ci/oci-batch.sh"), "prepare", img, mic.scope],
                env=dict(os.environ, MICROPOD_BIN=cli),
            ).stdout.strip()
            stack.callback(
                execute,
                [str(ROOT / "ci/oci-batch.sh"), "forget", handle],
                env=dict(os.environ, MICROPOD_BIN=cli),
            )
            r["prep"]["oci_s"] = time.monotonic() - begin
            for runtime in ("runc", "crun") if args.mode == "paired" else ("runc",):
                begin = time.monotonic()
                sessions[runtime] = WarmSession(cli, handle, runtime, stack)
                r["prep"][runtime + "_session_s"] = time.monotonic() - begin
                proof = sessions[runtime].batch(1, 0, probe=True)
                r["engines"]["direct-" + runtime] = {
                    "product": proof["jobs"][0]["sha256"],
                    "boot": mic.boot,
                }
                require(
                    proof["jobs"][0]["sha256"] == r["engines"]["micropod"]["product"],
                    "OCI prime product changed",
                )
                arms.append("direct-" + runtime)
        if args.mode == "fanout":
            second = WarmSession(cli, handle, "runc", stack)
            require(
                second.batch(1, 0, probe=True)["jobs"][0]["sha256"] == r["engines"]["micropod"]["product"],
                "Second launcher product changed",
            )
            arms.append("direct-runc-split")
        for rep in range(1, args.rounds + 1):
            for n in args.clients if rep % 2 else args.clients[::-1]:
                offset = (rep - 1 + args.clients.index(n)) % len(arms)
                order = arms[offset:] + arms[:offset]
                for arm in order if rep % 2 else order[::-1]:
                    if arm == "direct-runc-split":
                        begin = time.monotonic()
                        with ThreadPoolExecutor(max_workers=2) as pool:
                            left = pool.submit(sessions["runc"].batch, n // 2, rep)
                            right = pool.submit(second.batch, n - n // 2, rep)
                            jobs = left.result()["jobs"] + right.result()["jobs"]
                        b = {
                            "engine": arm,
                            "mode": "source",
                            "clients": n,
                            "round": rep,
                            "seconds": time.monotonic() - begin,
                            "jobs": jobs,
                        }
                    elif arm.startswith("direct-"):
                        b = sessions[arm.removeprefix("direct-")].batch(
                            n, rep, trace=args.mode in ("direct-trace", "native-tune")
                        )
                    else:
                        e = next(e for e in engines if e.name == arm)
                        b = docker_batch(
                            e,
                            tag,
                            n,
                            rep,
                            timed=args.mode in ("paired", "native-paired"),
                        )
                    b["engine"] = arm
                    if args.mode == "native-tune":
                        policy = arm.removeprefix("direct-native-")
                        if policy != "default":
                            require(
                                all(j["scheduler"] == (3 if "batch" in policy else 0) for j in b["jobs"]),
                                "Guest scheduling class differs from the requested policy",
                            )
                        if "affinity" in policy:
                            cpus = {j["cpuset"] for j in b["jobs"]}
                            require(
                                all(cpu.isdecimal() for cpu in cpus)
                                and len(cpus) == min(n, mic.info["NCPU"]),
                                "Guest CPU placement differs from the requested policy",
                            )
                    b["host_load"] = os.getloadavg()
                    r["batches"].append(b)
                    print(rep, n, arm, round(b["seconds"], 3), flush=True)
        kernel_result = kernel.finish() if kernel else {}
        if kernel:
            r["kernel"] = {k: kernel_result[k] for k in ("tick_ns", "poll_intervals_ns", "clock_error_ns")}
        for e in engines:
            info = r["engines"][e.name]
            bs = [b for b in r["batches"] if b["engine"] == e.name]
            info["fresh_containers"] = lifecycles(e, bs)
            info["after"] = e.audit()
            require(
                all(info["before"][k] == info["after"][k] for k in ("payload_inodes", "cache_sizes")),
                "Warm caches changed",
            )
            for b in bs:
                for j in b["jobs"]:
                    require(
                        j.get("sha256", info["product"]) == info["product"] and j["boot"] == e.boot,
                        "Product or boot changed",
                    )
                    if observer and e is mic:
                        j["phases_ns"] = dict(
                            observer.rows.get(j["container"], {}),
                            docker_create=j["lifecycle_ns"]["create"],
                            entry=j["entry"],
                        )
                        require(
                            all(k in j["phases_ns"] for k in STAGES),
                            str(j["phases_ns"]),
                        )
                        j["runc"] = [c for c in kernel_result["calls"] if c["container"] == j["container"]]
        if observer:
            require(not observer.errors, str(observer.errors))
            for level in args.clients:
                rows = [j for b in r["batches"] if b["clients"] == level for j in b["jobs"]]
                require(
                    any(c["operation"] == "create" for j in rows for c in j["runc"]),
                    "No runc create spans were observed",
                )
        direct = [job for b in r["batches"] if b["engine"].startswith("direct-") for job in b["jobs"]]
        require(
            len(direct) == len({j["container"] for j in direct})
            and all(j["product"] == TOKEN and j["boot"] == mic.boot for j in direct),
            "Direct jobs differed or were reused",
        )
        require(
            json.loads(execute([cli, "ci", "status"]).stdout) == status,
            "Worker identity changed",
        )
    r["passed"] = True


def export_timeline(receipt, path):
    """Independent lanes use each engine's guest clock, aligned to the first event of each batch."""
    events = []
    cursor = 0
    for pid, batch in enumerate(receipt["batches"], 1):
        tracks = []
        for job in batch["jobs"]:
            if "phases_ns" in job:
                stamps = {k: job["phases_ns"][k] for k in STAGES}
            elif "lifecycle_ns" in job:
                stamps = job["lifecycle_ns"]
            else:
                runtime = job["lifecycle"]
                begin = runtime["begin_ns"]
                launched = begin + runtime["setup_ns"]
                finished = launched + runtime["runtime_ns"]
                stamps = {
                    "prepare overlay and spec": begin,
                    "OCI runtime": launched,
                    "teardown": finished,
                    "removed": finished + runtime["cleanup_ns"],
                }
                if "entry" in job:
                    stamps["first timestamp in job"] = job["entry"]
                stamps.update(job.get("ci_phases_ns", {}))
            tracks.append((job, stamps))
        start = min(min(stamps.values()) for _, stamps in tracks)
        end = max(max(stamps.values()) for _, stamps in tracks)
        for job, _ in tracks:
            for call in job.get("runc", []):
                start = min(start, call["begin_ns"])
                end = max(end, call["end_ns"])
        name = f"{batch['engine']} / {batch['clients']} jobs / round {batch['round']}"
        events.append(
            {
                "ph": "M",
                "name": "process_name",
                "pid": pid,
                "tid": 0,
                "args": {"name": name},
            }
        )
        for tid, (job, stamps) in enumerate(tracks, 1):
            for name, ns in stamps.items():
                details = {"container": job["container"]}
                if name == "OCI runtime":
                    details["admission_wait_ns"] = job["lifecycle"].get("queue_ns", 0)
                if name == "removed" and "cgroup" in job:
                    details.update(job["cgroup"])
                    details.update(cpuset=job.get("cpuset"), scheduler=job.get("scheduler"))
                events.append(
                    {
                        "ph": "i",
                        "s": "t",
                        "name": name,
                        "pid": pid,
                        "tid": tid,
                        "ts": cursor + (ns - start) // 1000,
                        "args": details,
                    }
                )
            for call in job.get("runc", []):
                events.append(
                    {
                        "ph": "X",
                        "name": "sampled runc " + call["operation"],
                        "pid": pid,
                        "tid": tid,
                        "ts": cursor + (call["begin_ns"] - start) // 1000,
                        "dur": max(0, (call["end_ns"] - call["begin_ns"]) // 1000),
                        "args": {"container": job["container"]},
                    }
                )
        cursor += (end - start) // 1000 + 1000
    path.write_bytes(
        gzip.compress(json.dumps({"traceEvents": events}, separators=(",", ":")).encode(), mtime=0)
    )


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--mode",
        choices=(
            "trace",
            "direct-trace",
            "paired",
            "fanout",
            "native-tune",
            "native-paired",
        ),
        required=True,
    )
    p.add_argument(
        "--policies",
        choices=(
            "parallel",
            "single",
            "window4",
            "window8",
            "window16",
            "affinity",
            "batch",
            "batch-affinity",
            "default",
        ),
        nargs="+",
        default=["default"],
    )
    p.add_argument("--image", required=True)
    p.add_argument("--clients", nargs="+", type=int, default=[16, 32])
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--micropod", type=Path, default=ROOT / ".build/release/micropod")
    p.add_argument("--orbstack", type=Path, default=Path.home() / ".orbstack/run/docker.sock")
    args = p.parse_args()
    if (
        not 1 <= args.rounds <= 30
        or len(set(args.clients)) != len(args.clients)
        or any(n < 1 or n > 64 for n in args.clients)
    ):
        p.error("Expected 1–30 rounds and 1–64 clients")
    if args.mode == "fanout" and min(args.clients) < 2:
        p.error("Two launchers require at least two clients")
    r = {"run": uuid.uuid4().hex, "mode": args.mode, "passed": False}
    try:
        with tempfile.TemporaryDirectory() as directory:
            run(args, r, Path(directory))
    except BaseException as err:
        r["error"] = str(err)
        raise
    finally:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_bytes(gzip.compress(json.dumps(r, separators=(",", ":")).encode(), mtime=0))
        store(DEFAULT_DB, r["run"], "source-startup", r)
        if r["passed"]:
            export_timeline(r, args.out.parent / (r["run"] + ".trace.json.gz"))


if __name__ == "__main__":
    main()
