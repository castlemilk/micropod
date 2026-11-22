#!/usr/bin/env python3
"""Compare fresh initdb with a pristine PostgreSQL 16 image on an existing, dedicated Micropod worker."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timezone
import io
import json
import math
import os
from pathlib import Path
import re
import signal
import statistics
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import uuid

from ci_benchmark_store import read_buildkit_trace, store

ROOT = Path(__file__).resolve().parents[1]
MARKER = "MP_PG_RESULT "
LABEL = "io.micropod.postgres-profile"


def require(test, message):
    if not test:
        raise ValueError(message)


def distribution(values):
    if not values:
        return {"n": 0, "p50": None, "p95": None}
    values = sorted(values)
    return {"n": len(values), "p50": round(statistics.median(values), 6),
            "p95": round(values[math.ceil(.95 * len(values)) - 1], 6)}


def command(argv, env, timeout=300):
    # Stop the whole client pipeline on timeout, including shells waiting on Docker.
    with subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, start_new_session=True) as proc:
        try:
            stdout, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
            raise
        return subprocess.CompletedProcess(argv, proc.returncode, stdout, stderr)


def checked(result):
    if result.returncode:
        raise ValueError(f"{Path(result.args[0]).name} exited {result.returncode}: {(result.stderr or result.stdout)[-1200:]}")
    return result.stdout


def verify_shutdown(events):
    actions = [e["action"] for e in events]
    require(all(actions.count(a) == 1 for a in ("start", "die", "destroy")),
            "Incomplete or duplicate PostgreSQL Docker lifecycle")
    times = {e["action"]: e["ns"] for e in events}
    signals = [e for e in events if e["action"] == "kill"]
    require(signals and times["start"] <= signals[0]["ns"] <= times["die"] <= times["destroy"],
            "Missing or unordered PostgreSQL stop request")
    code = next(e["exit"] for e in events if e["action"] == "die")
    require(code == "0" and signals[0]["signal"] in ("2", "15", "SIGINT", "SIGTERM", "INT", "TERM") and all(e["signal"] not in ("9", "SIGKILL", "KILL") for e in signals),
            f"Unclean PostgreSQL shutdown (exit {code})")
    return (times["destroy"] - signals[0]["ns"]) / 1e9


@contextmanager
def docker_events(docker, env, token):
    """Follow this run's events; historical events can be evicted under load."""
    argv = [*docker, "events", "--since", str(int(time.time()) - 1), "--filter", "type=container",
            "--filter", f"label={LABEL}={token}", "--format", "{{json .}}"]
    proc = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, text=True)
    events, errors = {}, []
    changed = threading.Condition()

    def read():
        try:
            for line in proc.stdout:
                raw = json.loads(line)
                action = raw["Action"]
                if action not in {"create", "start", "kill", "die", "destroy"}:
                    continue
                actor = raw["Actor"]
                attrs = actor["Attributes"]
                if attrs.get(LABEL) != token:
                    continue
                e = dict(action=action, ns=raw["timeNano"], exit=attrs.get("exitCode"), signal=attrs.get("signal"))
                with changed:
                    events.setdefault(actor["ID"], []).append(e)
                    changed.notify_all()
        except (KeyError, ValueError, OSError) as exc:
            errors.append(str(exc))
        finally:
            with changed:
                errors.append("Docker event stream ended")
                changed.notify_all()

    thread = threading.Thread(target=read, daemon=True)
    thread.start()

    def audit(jobs):
        ids = {j["pg"]["container"] for j in jobs if j.get("pg", {}).get("container")}
        deadline = time.monotonic() + 5
        with changed:
            def complete():
                return errors or all(any(e["action"] == "destroy" for e in events.get(cid, [])) for cid in ids)
            changed.wait_for(complete, timeout=max(0, deadline - time.monotonic()))
            for job in jobs:
                cid = job.get("pg", {}).get("container")
                if not cid:
                    continue
                lifecycle = job["docker_events"] = list(events.pop(cid, []))
                try:
                    require(not errors, "Docker event stream failed: " + "; ".join(errors))
                    job["stop_request_to_destroy_s"] = verify_shutdown(lifecycle)
                    creates = [e["ns"] for e in lifecycle if e["action"] == "create"]
                    require(len(creates) == 1 and creates[0] <= next(e["ns"] for e in lifecycle if e["action"] == "start"),
                            "Missing or unordered PostgreSQL create event")
                except ValueError as exc:
                    job.update(passed=False, shutdown_error=str(exc))
    try:
        yield audit
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        thread.join(timeout=5)
        proc.stdout.close()


def timed_result(argv, env, job, queued):
    start = time.monotonic_ns()
    job.update(dispatch_wait_s=(start - queued) / 1e9, ci_queue_s=None)
    output = ""
    try:
        if job["workload"] == "application":
            with tempfile.TemporaryDirectory(prefix="mp-pg-stages-") as directory:
                stages_file = Path(directory) / "stages.jsonl"
                r = command(argv, dict(env, MICROPOD_CI_STAGE_TIMINGS=str(stages_file)), timeout=600)
                records = [json.loads(line) for line in stages_file.read_text().splitlines()] if stages_file.exists() else []
                job["application_stages"] = {k: {"seconds": s, "exit": rc} for k, s, rc in records}
        else:
            r = command(argv, env, timeout=600)
        output = r.stdout + "\n" + r.stderr
        markers = [json.loads(line.split(MARKER, 1)[1]) for line in output.splitlines() if MARKER in line]
        if markers:
            job["pg"] = markers[-1]
        require(r.returncode == 0 and len(markers) == 1 and markers[0]["passed"], f"PostgreSQL test exit {r.returncode}")
        data = job["pg"]
        require("verified SQL round trip on the final TCP server " + data["container"] in output, "Missing canonical SQL assertion")
        require(set(data["spans_us"]) == {"create_to_ready", "readiness", "sql", "observation", "teardown"}
                and all(data.get(k) is not None for k in ("fixture_restore_us", "materialized_to_tcp_ready_us")), "Incomplete PostgreSQL phases")
        if job["workload"] == "application":
            expected = {"postgres", "go-image", "go-checks", "go-unit", "node-image", "node-unit", "node-edit"}
            require(set(job["application_stages"]) == expected and len(records) == len(expected)
                    and all(row["exit"] == 0 for row in job["application_stages"].values()), "Incomplete application stages")
            require("greets the world by default" in output and "--- PASS: TestGreeting" in output
                    and "source edit reached the guest" in output, "Missing application assertions")
        job["passed"] = True
    except (KeyError, TypeError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
        job.update(passed=False, error=str(exc), output_tail=output[-1200:])
    finally:
        job["wall_s"] = (time.monotonic_ns() - start) / 1e9
    return job


def summarize(jobs):
    groups = {}
    for row in jobs:
        if row["round"] == 0:
            continue
        key = (row["workload"], row["mode"], row["clients"])
        groups.setdefault(key, []).append(row)
    summary = []
    for (work, mode, clients), trials in groups.items():
        good = [j for j in trials if j["passed"]]
        phases = {}
        for key in ("create_to_ready", "readiness", "sql", "teardown", "observation"):
            phases[key] = distribution([(j["pg"]["spans_us"][key][1] - j["pg"]["spans_us"][key][0]) / 1e6 for j in good])
        phases["fixture_restore"] = distribution([j["pg"]["fixture_restore_us"] / 1e6 for j in good])
        phases["materialized_to_tcp_ready"] = distribution([j["pg"]["materialized_to_tcp_ready_us"] / 1e6 for j in good])
        phases["stop_request_to_destroy"] = distribution([j["stop_request_to_destroy_s"] for j in good])
        phases["dispatch_wait"] = distribution([j["dispatch_wait_s"] for j in trials])
        summary.append(dict(workload=work, mode=mode, clients=clients, first_attempts=len(trials),
                            first_attempt_failures=len(trials) - len(good),
                            wall_s=distribution([j["wall_s"] for j in good]), phases_s=phases))
        if work == "application" and good:
            summary[-1]["application_stages_s"] = {name: distribution([j["application_stages"][name]["seconds"] for j in good])
                                                  for name in good[0]["application_stages"]}
    return summary


def trace(jobs):
    events = []
    for tid, job in enumerate(jobs, 1):
        data = job.get("pg", {})
        origin = data.get("start_unix_us")
        if origin is None:
            continue
        key = " ".join(str(job[k]) for k in ("workload", "mode", "clients", "round", "job"))
        events.append(dict(ph="M", pid=1, tid=tid, name="thread_name", args={"name": key}))
        for name, (start, end) in data["spans_us"].items():
            args = {"container": data.get("container"), "passed": job["passed"]}
            if name == "readiness":
                args["guest_fixture_materialization_us"] = data.get("fixture_restore_us")
                args["materialized_to_tcp_ready_us"] = data.get("materialized_to_tcp_ready_us")
            events.append(dict(name=name, cat="postgres", ph="X", pid=1, tid=tid, ts=origin+start, dur=end-start, args=args))
        # The PostgreSQL container has a private cgroup. These are cumulative job counters.
        section, counters = "", {}
        for line in data.get("job_cgroup", "").splitlines():
            if line.startswith("["):
                section = line.strip("[]")
                continue
            fields = line.split()
            if section in ("cpu.stat", "memory.events") and len(fields) == 2 and fields[1].isdigit():
                counters[section+"."+fields[0]] = int(fields[1])
            elif section in ("cpu.pressure", "io.pressure") and fields:
                value = next((f[6:] for f in fields[1:] if f.startswith("total=")), "")
                if value.isdigit():
                    counters[section+"."+fields[0]+"_us"] = int(value)
            elif section == "io.stat":
                for field in fields[1:]:
                    metric, _, value = field.partition("=")
                    if metric in ("rbytes", "wbytes") and value.isdigit():
                        k = section+"."+metric
                        counters[k] = counters.get(k, 0) + int(value)
        if counters and "observation" in data["spans_us"]:
            events.append(dict(name="PostgreSQL cgroup", cat="kernel", ph="C", pid=1, tid=tid, id=tid,
                               ts=origin+data["spans_us"]["observation"][1], args=counters))
    return {"traceEvents": events, "displayTimeUnit": "ms"}


def measure_guest_packages(docker, env, image_id, token, rounds):
    # Send scripts over stdin. No host-path bind mounts or changes to shared caches.
    files = ("profile_ci_package_commands.py", "bench_package_caches.py", "bench_postgres_fixture.py", "ci_benchmark_store.py")
    bundle = io.BytesIO()
    with tarfile.open(fileobj=bundle, mode="w") as tar:
        for name in files:
            tar.add(ROOT / "scripts" / name, arcname=name)
    script = """cd /tmp && tar xf - && rc=0
python3 -B profile_ci_package_commands.py --rounds "$1" --out results.json --database results.sqlite3 >&2 || rc=$?
cat results.json
exit "$rc" """
    result = subprocess.run([*docker, "run", "--pull=never", "--rm", "-i", "--network", "none", "--cpus", "1",
                             "--memory", "1g", "--label", LABEL + "=" + token, "--entrypoint", "sh", image_id,
                             "-ec", script, "sh", str(rounds)], input=bundle.getvalue(), capture_output=True,
                            env=env, timeout=120*rounds+60)
    if not result.stdout.strip():
        raise ValueError("Package container failed before producing a receipt: " + result.stderr.decode(errors="replace")[-1200:])
    data = json.loads(result.stdout)
    data["container_exit"] = result.returncode
    return data


def run(args, rec):
    require(args.endpoint.startswith("unix:///"), "An explicit local worker Unix socket is required")
    socket = Path(args.endpoint[7:])
    require(socket.is_socket(), "Dedicated Micropod worker socket is absent")
    inherited = {"DOCKER_CONTEXT", "DOCKER_CERT_PATH", "DOCKER_TLS_VERIFY", "BUILDX_BUILDER", "MICROPOD_CI_STAGE_TIMINGS"}
    env = {k: v for k, v in os.environ.items() if k not in inherited}
    env.update(DOCKER_HOST=args.endpoint, DOCKER_BUILDKIT="1", BUILDKIT_PROGRESS="plain")
    docker = ["docker", "--host", args.endpoint]

    def dk(*argv):
        return checked(command([*docker, *argv], env))

    def identity():
        info = json.loads(dk("info", "--format", "{{json .}}"))
        labels = dict(label.split("=", 1) for label in info.get("Labels") or [] if "=" in label)
        owner = labels.get("io.micropod.ci.worker", "")
        require(owner and owner.lower() == args.worker_id.lower() and labels.get("io.micropod.ci.boot"),
                "Docker endpoint is not the specified Micropod worker")
        return dict(worker=owner, boot=labels["io.micropod.ci.boot"], daemon=info["ID"],
                    cpus=info["NCPU"], memory=info["MemTotal"], kernel=info["KernelVersion"], storage=info["Driver"])

    first = rec["worker"] = identity()
    require(not dk("ps", "-q").strip(), "Dedicated worker already has running containers")
    require(first["storage"] in ("overlayfs", "overlay2"), "The prepared template requires an overlay storage driver")
    package_id = None
    if args.package_image:
        package = json.loads(dk("image", "inspect", args.package_image))[0]
        require(package["Os"] == "linux" and package["Architecture"] == "arm64", "Expected an ARM64 Linux package image")
        package_id = package["Id"]
    pg = json.loads(dk("image", "inspect", args.postgres))[0]
    require(re.search(r"^PG_MAJOR=16$", "\n".join(pg["Config"]["Env"]), re.M), "Expected PostgreSQL major 16")
    require(pg["Os"] == "linux" and pg["Architecture"] == "arm64", "Expected the ARM64 Linux PostgreSQL image")
    base = next((v for v in pg.get("RepoDigests") or [] if re.fullmatch(
        r"(?:(?:index[.])?docker[.]io/)?(?:library/)?postgres@sha256:[0-9a-f]{64}", v)), None)
    require(base, "The locally provisioned postgres:16 image must have an upstream repo digest")
    rec["postgres_base"] = dict(reference=base, local_id=pg["Id"], bytes=pg["Size"])
    rec["revision"] = checked(command(["git", "-C", str(ROOT), "rev-parse", "HEAD"], env)).strip()
    token = rec["run"]
    prefix = "micropod-internal/pg-profile-" + token
    cases = {v: prefix + ":" + v for v in ("fresh", "prepared")}
    samples = prefix + "-samples"
    jobs = rec["jobs"] = []
    builds = rec["image_builds"] = []
    batches = rec["batches"] = []
    rec["clock"] = "Mac monotonic client clock; readiness and SQL use the check process monotonic clock; guest fixture uses Linux uptime"
    rec["ci_queue_s"] = None
    rec["queue_source"] = "local dispatch, no CI scheduler"

    @contextmanager
    def owned_db(image, name, password):
        pg_env = ["-e", "POSTGRES_USER=ci", "-e", "POSTGRES_DB=ci", "-e", "POSTGRES_PASSWORD=" + password]
        cid = dk("create", "--pull=never", "--name", name, "--network", "none", "--label", LABEL + "=" + token,
                 *pg_env, image).strip()
        require(re.fullmatch(r"[0-9a-f]{64}", cid) and dk("inspect", "--format",
                '{{index .Config.Labels "' + LABEL + '"}}', cid).strip() == token, "Unexpected container ownership")
        try:
            dk("start", cid)
            # Readiness polling is part of one attempt, and always uses the final TCP listener.
            deadline = time.monotonic() + 40
            while command([*docker, "exec", cid, "pg_isready", "-q", "-h", "127.0.0.1", "-U", "ci", "-d", "ci"], env).returncode:
                require(time.monotonic() < deadline, "Recovery probe did not become ready")
                time.sleep(.1)
            yield cid
        finally:
            dk("rm", "-f", "-v", cid)

    def sql(cid, password, statement):
        return command([*docker, "exec", "-e", "PGPASSWORD=" + password, cid, "psql", "-XqAtw", "-h", "127.0.0.1",
                        "-U", "ci", "-d", "ci", "-v", "ON_ERROR_STOP=1", "-c", statement], env)

    try:
        for mode, tag in cases.items():
            for state in ("cold", "warm"):
                start = time.monotonic()
                b = command([*docker, "build", "--pull=false", "--progress=rawjson", "--target", mode,
                             "--build-arg", "BASE=" + base, "--build-arg", "FIXTURE_BUILD=" + token, "-t", tag,
                             str(ROOT / "ci/fixtures/postgres-profile")], env, timeout=600)
                row = dict(mode=mode, state=state, seconds=time.monotonic()-start, exit=b.returncode)
                builds.append(row)
                checked(b)
                row["solve_sha256"], solve = read_buildkit_trace(io.BytesIO((b.stderr or b.stdout).encode()))
                row.update(solve)
                require(row["steps"] and all(s["outcome"] in ("cached", "executed") for s in row["steps"]),
                        "Missing BuildKit step evidence")
                require(state != "warm" or all(s["outcome"] == "cached" for s in row["steps"]), "Warm build was not fully cached")
                if mode == "prepared" and state == "cold":
                    require(any(s["operation"] == "RUN" and s["outcome"] == "executed" and "prepared" in s["position"] for s in row["steps"]),
                            "Prepared control did not initialize a new template")
                info = json.loads(dk("image", "inspect", tag))[0]
                base_layers = pg["RootFS"]["Layers"]
                require(info["RootFS"]["Layers"][:len(base_layers)] == base_layers, "Fixture lost its pinned base layers")
                row.update(image_id=info["Id"], image_bytes=info["Size"], base_delta_bytes=info["Size"] - pg["Size"],
                           layers=info["RootFS"]["Layers"])
                if state == "warm":
                    require(row["image_id"] == builds[-2]["image_id"], "Repeat build changed the image")

        # A killed job's committed table must be absent from the next, independently writable cluster.
        previous, current = uuid.uuid4().hex, uuid.uuid4().hex
        with owned_db(cases["prepared"], "pg-fault-" + token, previous) as cid:
            require(checked(sql(cid, previous, "CREATE TABLE ci_probe(value integer NOT NULL); INSERT INTO ci_probe VALUES(42); SELECT value FROM ci_probe;")).strip() == "42",
                    "Dirty fixture setup failed")
            dk("kill", "--signal=KILL", cid)
            require(dk("wait", cid).strip() == "137", "Fault injection did not terminate the owned container")
        with owned_db(cases["prepared"], "pg-recovered-" + token, current) as cid:
            require(checked(sql(cid, current, "SELECT to_regclass('public.ci_probe') IS NULL;")).strip() == "t",
                    "Prior job state leaked")
            denied = sql(cid, previous, "SELECT 1;")
            require(denied.returncode != 0 and "password authentication failed" in denied.stderr, "Prior job password accepted or unverified")
            dk("stop", cid)
            require(dk("wait", cid).strip() == "0", "Recovered job shutdown failed")
        rec["dirty_job_recovery"] = True

        def batch(mode, count, rnd, work, audit):
            tag = cases[mode]
            jobenv = dict(env, MICROPOD_PG_PROFILE_IMAGE=tag, MICROPOD_PG_PROFILE_RUN=token, MICROPOD_CI_SAMPLE_IMAGE=samples)
            if work == "application":
                argv = ["bash", str(ROOT / "ci/worker-pipeline.sh"), "all", args.endpoint]
            else:
                argv = [*docker, "run", "--pull=never", "--rm", "--network", "host", "--label", LABEL + "=" + token,
                        "-v", "/var/run/docker.sock:/var/run/docker.sock", "-e", "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock",
                        "-e", "TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1", "-e", "MICROPOD_PG_PROFILE_IMAGE",
                        "-e", "MICROPOD_PG_PROFILE_RUN", "--entrypoint", "/out/postgres-test", samples + ":checks", "-test.v"]
            start = time.monotonic_ns()
            with ThreadPoolExecutor(max_workers=count) as pool:
                futures = [pool.submit(timed_result, argv, jobenv, dict(workload=work, mode=mode, clients=count,
                                       round=rnd, job=i+1), time.monotonic_ns()) for i in range(count)]
                result = [f.result() for f in futures]
            wall = (time.monotonic_ns() - start)/1e9
            jobs.extend(result)
            audit(result)
            batches.append(dict(workload=work, mode=mode, clients=count, round=rnd, seconds=wall, passed=all(j["passed"] for j in result)))
            require(identity() == first, "The worker changed during a measured batch")
            require(all(j["passed"] for j in result), "First attempt failed; results retained without retry")

        with docker_events(docker, env, token) as audit:
            for rnd in range(args.rounds + 1):
                modes = list(cases) if rnd % 2 == 0 else list(reversed(cases))
                for mode in modes:
                    batch(mode, 1, rnd, "application", audit)
                if rnd:
                    for n in args.clients:
                        for mode in modes:
                            batch(mode, n, rnd, "postgres", audit)
        ids = [j["pg"]["container"] for j in jobs]
        require(len(ids) == len(set(ids)), "A job reused a PostgreSQL container")
        volumes = [v for j in jobs for v in j["pg"].get("volumes") or []]
        require(len(volumes) == len(set(volumes)), "Jobs shared a writable PostgreSQL volume")
        remaining = set(dk("volume", "ls", "-q").split()).intersection(volumes)
        rec["database_isolation"] = dict(unique_containers=len(set(ids)), unique_volumes=len(set(volumes)),
                                         remaining_volumes=len(remaining))
        require(not remaining, "Anonymous PostgreSQL volumes survived job cleanup")
        if package_id:
            require(identity() == first, "Worker changed before package profiling")
            data = rec["package_commands"] = measure_guest_packages(docker, env, package_id, token, args.rounds)
            data.update(runtime="micropod", worker=first, image_id=package_id)
            require(data["passed"] and data["container_exit"] == 0, "A package command or control failed")
            require(identity() == first, "Worker changed during package profiling")
    finally:
        rec["summary"] = summarize(jobs)
        for group in rec["summary"]:
            group["batch_wall_s"] = distribution([b["seconds"] for b in batches if b["passed"] and b["round"] > 0
                and all(b[key] == group[key] for key in ("mode", "clients", "workload"))])
        # Clean only objects tagged by this invocation. Leave worker state and unrelated caches alone.
        try:
            leftovers = dk("ps", "-aq", "--filter", "label=" + LABEL + "=" + token).split()
            if leftovers:
                rec["leftover_containers"] = len(leftovers)
                dk("rm", "-fv", *leftovers)
            tags = [*cases.values(), *(samples+":"+s for s in ("checks","go","node","node-edited"))]
            owned = [tag for tag in tags if command([*docker, "image", "inspect", tag], env).returncode == 0]
            if owned:
                dk("image", "rm", *owned)
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            rec["cleanup_error"] = str(exc)
    require(not rec.get("cleanup_error") and not rec.get("leftover_containers"), "Workload cleanup was incomplete")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--endpoint", required=True)
    p.add_argument("--worker-id", required=True, help="Expected ID of an already running, dedicated Micropod worker")
    p.add_argument("--postgres", default="postgres:16", help="Locally available official image")
    p.add_argument("--package-image", help="Local Linux ARM64 bench_cache_image for direct cold/warm Go and npm commands")
    p.add_argument("--clients", nargs="+", type=int, default=[1, 4])
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--database", type=Path, help="SQLite benchmark data store (default: beside the JSON)")
    args = p.parse_args()
    if not 1 <= args.rounds <= 50 or len(set(args.clients)) != len(args.clients) or not all(1 <= n <= 32 for n in args.clients):
        p.error("Use 1..50 rounds and distinct concurrency levels from 1..32")
    rec = dict(run=uuid.uuid4().hex, started_utc=datetime.now(timezone.utc).isoformat(timespec="seconds"), passed=False,
               requested_clients=args.clients, rounds=args.rounds, ci_queue_s=None)
    try:
        run(args, rec)
        rec["passed"] = True
    except (KeyError, TypeError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
        rec["error"] = str(exc)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    rec["first_attempt_job_failures"] = sum(not j["passed"] for j in rec.get("jobs", []))
    if rec.get("jobs"):
        dest = args.out.with_suffix(".trace.json")
        dest.write_text(json.dumps(trace(rec["jobs"])) + "\n")
        rec["trace_file"] = dest.name
    args.out.write_text(json.dumps(rec, indent=2) + "\n")
    database = args.database or args.out.with_suffix(".sqlite3")
    store(database, rec["run"], "postgres-fixture-profile", rec)
    if rec.get("package_commands"):
        data = rec["package_commands"]
        store(database, data["run"], "package-command-profile", data)
    print(json.dumps({k: rec[k] for k in ("run","passed","error","summary") if k in rec}))
    return 0 if rec["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
