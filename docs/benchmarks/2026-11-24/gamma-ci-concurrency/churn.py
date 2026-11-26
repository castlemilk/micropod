"""Run ephemeral CI jobs while a fixed client keeps all 32 sidecars busy."""

import http.client
import json
import os
import re
import socket
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from qualify import IMAGE, LABEL, fanout, peer, receiver, request, require, terminal

JOB = """
set -eu
gate=$1
revision=$2
kind=$3
echo waiting-for-dispatch
while [ ! -f "/mpcheck/$gate" ]; do sleep .1; done
if [ -n "${MCI_BUILD_CPUS:-}" ]; then
    @apply_cpu_list@
    awk '$1=="Cpus_allowed_list:" {print "mci-build-cpus=" $2}' /proc/self/status
fi
case "$kind" in
    fail)
        export EXPECTED_REVISION="$revision-deliberate-mismatch"
        exec go test -count=1 -run '^TestFanoutRevision$' -v . ;;
    cancel)
        echo cancellation-step-started
        exec sleep 120 ;;
    pass)
        @build_revisions@ ;;
    *) exit 64 ;;
esac
"""


def job_command(native_cpuset=False, *, accounting=False):
    affinity = 'taskset -pc "$MCI_BUILD_CPUS" $$ >/dev/null'
    revisions = '/bin/sh /mpcheck/job.sh "$revision-a"\n        exec /bin/sh /mpcheck/job.sh "$revision-b"'
    if native_cpuset:
        affinity = 'echo "mci-build-cgroup=$(cat /sys/fs/cgroup/cpuset.cpus.effective) quota=$(cat /sys/fs/cgroup/cpu.max)"'
        revisions = r'''work_tmp=$(mktemp -d "$MCI_SCRATCH_PARENT/mci-work.XXXXXXXX")
        trap 'rm -rf -- "$work_tmp"' EXIT
        export TMPDIR="$work_tmp" GOTMPDIR="$work_tmp"
        mounts=$(awk -v parent="$MCI_SCRATCH_PARENT" '$5=="/" {root=$1} $5==parent {exact=$1} $5=="/cache" {cache=$1}
                     END {print (exact ? exact : root),cache}' /proc/self/mountinfo)
        echo "mci-build-scratch $MCI_SCRATCH_PARENT $(stat -f -c %T "$work_tmp") $mounts"
        cpu_stat() {
            awk '$1=="nr_periods" {p=$2} $1=="nr_throttled" {n=$2} $1=="throttled_usec" {t=$2}
                 $1=="user_usec" {u=$2} $1=="system_usec" {s=$2}
                 END {print "mci-build-cpu-stat",p,n,t,u,s}' /sys/fs/cgroup/cpu.stat
        }
        cpu_stat
        /bin/sh /mpcheck/job.sh "$revision-a"
        /bin/sh /mpcheck/job.sh "$revision-b"
        cpu_stat'''
    if accounting:
        require(native_cpuset, "phase accounting needs a job-private scratch directory")
        revisions = revisions.replace("/mpcheck/job.sh", "/mpcheck/job-accounted.sh")
        revisions = revisions.replace("        cpu_stat\n", '        export MCI_USAGE_LOG="$work_tmp/go-usage"\n        cpu_stat\n', 1)
        revisions += r'''
        sed "s/^/mci-go-phase /" "$MCI_USAGE_LOG"
        echo "mci-memory-peak $(cat /sys/fs/cgroup/memory.peak)"
        awk '$1=="oom" || $1=="oom_kill" {print "mci-memory-event",$1,$2}' /sys/fs/cgroup/memory.events'''
    return JOB.replace("@apply_cpu_list@", affinity).replace("@build_revisions@", revisions)


def live_objects(cohort, ids, running):
    rows = json.loads(cohort.cmd("inspect", *ids))
    require(len(rows) == len(ids) and {r["Id"] for r in rows} == set(ids), "missing job identities")
    for r in rows:
        require(
            r["Config"]["Labels"].get(LABEL) == cohort.owner
            and r["Name"].lstrip("/") in cohort.expected
            and bool(r["State"]["Running"]) == running
            and not r["State"].get("OOMKilled"),
            "unexpected job state",
        )
    return rows


def traffic_arguments(cohort, fixed, target_index):
    """Bind the pinned client to the current cohort's published identities."""
    jobs = cohort.jobs
    targets = cohort.folder / f"targets-{cohort.arm}.tsv"
    contents = "".join(f"http://127.0.0.1:{j['port']}\t{j['name']}\n" for j in jobs)
    require(len(jobs) == 32 and len({j["port"] for j in jobs}) == 32, "need 32 distinct services")
    if not targets.exists():
        targets.write_text(contents)
    require(targets.read_text() == contents and terminal.digest(fixed) == peer.CLIENT,
            "changed published client or targets")
    if target_index is None:
        return ["--targets", str(targets)]
    require(type(target_index) is int and 0 <= target_index < len(jobs), "invalid service ordinal")
    job = jobs[target_index]
    return [f"http://127.0.0.1:{job['port']}", job["name"]]


def run_traffic(cohort, fixed, arguments):
    admission = cohort.admission
    multi = arguments[0] == "--targets"
    if multi:
        targets = Path(arguments[1])
        offer = (fixed.resolve(), targets, terminal.digest(targets))
    else:
        # The ordinary guard checks this exact URL/marker and the client's process group.
        require(any(arguments == [f"http://127.0.0.1:{j['port']}", j["name"]] for j in cohort.jobs),
                "single-port client does not target a resident tenant")
        scope = cohort.folder / ("client-" + arguments[1])
        scope.mkdir(exist_ok=True)
        for filename, value in (("addr", arguments[0].removeprefix("http://")), ("name", arguments[1])):
            marker = scope / filename
            if not marker.exists():
                marker.write_text(value)
            require(marker.read_text() == value, "single-port scope changed")
        offer = None
    with admission.lock:
        old_group, old_offer, old_scopes = admission.receiver_group, admission.offered, admission.peer_scopes
        admission.receiver_group = os.getpgrp()
        admission.offered = offer
        if not multi:
            admission.peer_scopes = (*old_scopes, scope)
    try:
        start = time.monotonic()
        proc = terminal.invoke(fixed, *arguments, timeout=65, check=False)
        return proc, {"arguments": arguments, "target_sha256": offer[2] if multi else None,
                      "started_s": start, "ended_s": time.monotonic()}
    finally:
        with admission.lock:
            admission.receiver_group, admission.offered, admission.peer_scopes = old_group, old_offer, old_scopes


def batch(cohort, number, fixed, *, cpu_list=None, observe=None, target_index=None, backend_targets=None,
          build_slots=4, build_placement=None, build_scratch=None, build_accounting=False):
    jobs = cohort.jobs
    require(cohort.running() == 32, "need 32 resident CI services")
    group = f"ep{number}"
    probe = cohort.workspace / "probe"
    arguments = traffic_arguments(cohort, fixed, target_index)
    if backend_targets is not None:
        require(target_index is None and backend_targets == cohort.folder / "direct-targets.tsv"
                and backend_targets.is_file(), "unexpected direct route target file")
        arguments = ["--targets", str(backend_targets)]
    names = [f"{cohort.prefix}{group}-{i}" for i in range(32)]
    for name in names:
        cohort.register(name)
    started = time.monotonic()
    job_script = job_command(bool(build_placement), accounting=build_accounting)
    scratch_parent = "/cache" if build_scratch == "volume" else "/tmp"

    def launch(i):
        name = names[i]
        kind = "fail" if i == 0 else "cancel" if i == 1 else "pass"
        mask = ("0-1", "2-3")[i % 2] if build_placement == "pairs" else cpu_list
        cid = cohort.cmd(
            "run",
            "-d",
            *cohort.job_flags(name),
            *(["-e", "MCI_BUILD_CPUS=" + mask] if mask else []),
            *(["--cpuset-cpus", mask, "-e", "MCI_SCRATCH_PARENT=" + scratch_parent] if build_placement else []),
            "--network",
            "none",
            "--entrypoint",
            "/bin/sh",
            IMAGE,
            "-ec",
            job_script,
            "sh",
            name,
            f"e{number}j{i:02}",
            kind,
        )
        require(re.fullmatch("[0-9a-f]{64}", cid), "invalid ephemeral job ID")
        return {"id": cid, "name": name, "kind": kind, "revision": f"e{number}j{i:02}",
                **({"docker_cpu_list": mask} if build_placement else {})}

    with ThreadPoolExecutor(max_workers=4) as submit:
        ephemeral = list(submit.map(launch, range(32)))
    ids = [j["id"] for j in ephemeral]
    live = live_objects(cohort, ids + [j["id"] for j in jobs], True)
    if build_placement:
        requested = {r["Id"]: r["HostConfig"]["CpusetCpus"] for r in live}
        require(all(requested[j["id"]] == j["docker_cpu_list"] for j in ephemeral), "Docker lost a build's CPU list")
    provisioned = time.monotonic() - started

    # Bound the CPU-heavy steps while keeping all 32 admitted jobs resident.
    def execute(j, origin):
        release = time.monotonic() - origin
        (probe / j["name"]).touch(exist_ok=False)
        if j["kind"] == "cancel":
            deadline = time.monotonic() + 12
            while "cancellation-step-started" not in cohort.cmd("logs", j["id"]):
                require(time.monotonic() < deadline, "cancelled job never began its step")
                time.sleep(0.05)
            cohort.cmd("kill", j["id"])
        exit_code = int(cohort.cmd("wait", j["id"], timeout=120))
        streams = terminal.invoke(*cohort.engine, "logs", j["id"], timeout=90)
        log = streams.stdout + "\n" + streams.stderr
        if exit_code != {"pass": 0, "fail": 1, "cancel": 137}[j["kind"]]:
            info, = json.loads(cohort.cmd("inspect", j["id"]))
            require(info["Id"] == j["id"], "wrong failed job identity")
            terminal.save(cohort.folder / f"failed-job-{j['name']}.json", {
                "job": j, "exit": exit_code, "stdout": streams.stdout[-8192:], "stderr": streams.stderr[-8192:],
                "inspect_state": info["State"],
            })
        mask = j.get("docker_cpu_list", cpu_list)
        if mask:
            require(f"mci-build-cpus={mask}" in log.splitlines(), "kernel affinity readback differs")
        if build_placement:
            require(f"mci-build-cgroup={mask} quota=100000 100000" in log.splitlines(),
                    "build cgroup CPU list or bandwidth differs")
        rows = []
        cpu_stats = {}
        scratch = {}
        phases = []
        if j["kind"] == "pass":
            require(exit_code == 0, f"{j['name']} exited {exit_code}: {log[-600:]}")
            receipts = [line for line in log.splitlines() if line.startswith(j["revision"] + "-")]
            require(len(receipts) == 2, "missing CI workload receipts")
            for suffix, raw in zip("ab", receipts, strict=True):
                row = fanout.parse_job(raw, None)
                require(
                    row["revision"] == j["revision"] + "-" + suffix
                    and row["tests"] == 8
                    and row["cpu_s"] > 0
                    and min(row[k] for k in ("compile", "vet", "link")) > 0
                    and re.fullmatch("[0-9a-f]{64}", row["product"]),
                    "invalid CI receipt",
                )
                rows.append(row)
            if build_accounting:
                from build_pages import validate_usage
                phases = [json.loads(line.removeprefix("mci-go-phase ")) for line in log.splitlines()
                          if line.startswith("mci-go-phase ")]
                validate_usage(phases, j["revision"])
                peaks = [int(line.split()[1]) for line in log.splitlines() if line.startswith("mci-memory-peak ")]
                events = {line.split()[1]: int(line.split()[2]) for line in log.splitlines() if line.startswith("mci-memory-event ")}
                require(len(peaks) == 1 and peaks[0] > 0 and events == {"oom": 0, "oom_kill": 0},
                        "missing job memory peak or unexpected OOM")
            if build_placement:
                entries = [line.split() for line in log.splitlines() if line.startswith("mci-build-scratch ")]
                require(len(entries) == 1 and len(entries[0]) == 5, "missing build scratch mount")
                _, parent, filesystem, mount_id, cache_id = entries[0]
                require(parent == scratch_parent and int(mount_id) > 0 and int(cache_id) > 0
                        and (mount_id == cache_id) == (build_scratch == "volume"),
                        "build scratch used an unexpected filesystem")
                scratch = {"parent": parent, "filesystem": filesystem, "mount_id": int(mount_id), "volume_id": int(cache_id)}
                samples = [list(map(int, line.split()[1:])) for line in log.splitlines() if line.startswith("mci-build-cpu-stat ")]
                keys = ("nr_periods", "nr_throttled", "throttled_usec", "user_usec", "system_usec")
                require(len(samples) == 2 and all(len(s) == len(keys) for s in samples), "missing build cgroup statistics")
                cpu_stats = dict(zip(keys,
                                     (b - a for a, b in zip(*samples, strict=True)), strict=True))
                require(min(cpu_stats.values()) >= 0, "build CPU counters regressed")
        elif j["kind"] == "fail":
            require(
                exit_code == 1
                and "--- FAIL: TestFanoutRevision" in log
                and j["revision"] + "-deliberate-mismatch" in log,
                "wrong failure was reported",
            )
        else:
            require(exit_code == 137 and "cancellation-step-started" in log, "wrong cancellation result")
        return dict(
            **j,
            exit=exit_code,
            submitted_s=release,
            finished_s=time.monotonic() - origin,
            receipts=rows,
            **({"go_phases": phases, "memory_peak_bytes": peaks[0], "memory_oom_events": events} if phases else {}),
            failure_log=log[-700:] if j["kind"] != "pass" else None,
            **({"effective_cpu_list": mask} if mask else {}),
            **({"cgroup_cpu_list": mask, "cpu_max": "100000 100000"} if build_placement else {}),
            **({"cpu_stat_delta": cpu_stats, "scratch_mount": scratch} if cpu_stats else {}),
        )

    idle = receiver.path_pilot.cpu_idle()
    before = observe("before") if observe else None

    def offered():
        proc, invocation = run_traffic(cohort, fixed, arguments)
        return proc, invocation, observe("after") if observe else None

    with ThreadPoolExecutor(max_workers=1) as client, ThreadPoolExecutor(max_workers=build_slots) as ci:
        start = time.monotonic()
        bulk = client.submit(offered)
        try:
            results = list(ci.map(lambda job: execute(job, start), ephemeral))
        except Exception:
            proc, invocation, _ = bulk.result()
            terminal.save(cohort.folder / f"client-on-job-error-{number}-{cohort.arm}.json", {
                "exit": proc.returncode, "invocation": invocation, "stdout": proc.stdout, "stderr": proc.stderr,
            })
            raise
        proc, invocation, after = bulk.result()
        end = time.monotonic()
    raw = json.loads(proc.stdout)
    receipt = {
        "arm": cohort.arm,
        "block": number,
        "pre_idle": idle,
        "resident_services": 32,
        "running_ephemeral_at_barrier": len(ids),
        "provision_and_inspect_s": provisioned,
        "job_release_monotonic_s": start,
        "invocation": invocation,
        "jobs": results,
        "last_job_s": max(r["finished_s"] for r in results),
        "both_finished_s": end - start,
        "client": raw,
        "client_exit": proc.returncode,
        "client_stderr": proc.stderr[-1500:],
    }
    out = cohort.folder / f"churn-{number}-{cohort.arm}.json"
    if observe:
        receipt.update(counter_before=before, counter_after=after)
    terminal.save(out, receipt)
    require(
        proc.returncode == 0
        and not raw["errors"]
        and raw["reopened"] == 0
        and raw["arrivals"] == 240
        and raw["published_ports"] == (32 if target_index is None else 1)
        and raw["streams"] == len(raw["per_stream_bytes"]) == 32
        and min(raw["per_stream_bytes"]) > 0
        and sum(raw["per_stream_bytes"]) == raw["bytes"],
        "bulk or fresh traffic failed",
    )
    for job, observed in zip(results, live_objects(cohort, ids, False), strict=True):
        require(
            job["id"] == observed["Id"] and observed["State"]["ExitCode"] == job["exit"],
            "exit state disagrees with wait",
        )
    cohort.cmd("rm", *ids, timeout=120)
    require(
        set(ids).isdisjoint(cohort.cmd("ps", "-aq", "--no-trunc").splitlines()), "retired jobs still listed"
    )
    for j in jobs:
        require(request(j, "/health").decode() == j["name"], "sidecar identity changed during job churn")
    cohort.running()
    cohort.runner.guard()
    receipt["provision_to_final_cleanup_s"] = time.monotonic() - started
    receipt["removed"] = ids
    terminal.save(out, receipt)
    print(
        f"{cohort.arm} churn {number}: 30 passed, 1 failed as injected, 1 cancelled, "
        f"{raw['mib_s']:.1f} MiB/s, p95 {raw['fresh_p95_us'] / 1000:.1f} ms",
        flush=True,
    )
    return receipt


def replace(cohort):
    victim = cohort.jobs[-1]
    port = victim["port"]
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request("GET", "/id")
        require(
            connection.getresponse().read().decode() == victim["name"] and connection.sock is not None,
            "old connection did not stay open",
        )
        old = connection.sock
        live_objects(cohort, [victim["id"]], True)
        cohort.cmd("rm", "-f", victim["id"])
        try:
            closed = old.recv(1) == b""
        except ConnectionResetError:
            closed = True
        require(closed, "old accepted connection survived removal")
    finally:
        connection.close()
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            raise ValueError("old listener survived retirement")
    except ConnectionRefusedError:
        pass
    name = cohort.prefix + "replacement"
    cohort.register(name)
    cid = cohort.cmd(
        "run",
        "-d",
        "--pull=never",
        "--name",
        name,
        "--label",
        f"{LABEL}={cohort.owner}",
        "-p",
        f"127.0.0.1:{port}:8080",
        terminal.SERVICE,
        "-listen",
        ":8080",
        "-marker",
        name,
    )
    require(
        cid != victim["id"] and cohort.cmd("port", cid, "8080/tcp") == f"127.0.0.1:{port}",
        "port was not reassigned",
    )
    replacement = {"port": port, "name": name}
    require(request(replacement, "/id").decode() == name, "old identity served on reused port")
    siblings = [j["id"] for j in cohort.jobs[:-1] if request(j, "/health").decode() == j["name"]]
    require(len(siblings) == 31, "a sibling lost its route during replacement")
    terminal.save(
        cohort.folder / f"port-reuse-{cohort.arm}.json",
        {
            "port": port,
            "closed": True,
            "refused": True,
            "retired": victim["id"],
            "old_marker": victim["name"],
            "new_marker": name,
            "replacement": cid,
            "siblings": siblings,
        },
    )


def study(cohorts, folder, fixed, matched=False):
    orders = ["AB", "BA", "BA", "AB"] if matched else ["AB", "BA"]
    terminal.save(
        folder / "churn-plan.json",
        {
            "order": orders,
            "cpu_steps": 4,
            "one_shot_jobs": 32,
            "sidecars": 32,
            "per_job_revisions": 2,
            "client_sha256": terminal.digest(fixed),
            "driver_sha256": terminal.digest(Path(__file__)),
            "intentional_exits": [1, 137],
        },
    )
    for c in cohorts.values():
        c.add(32)
    for number, order in enumerate(orders):
        for arm in order:
            batch(cohorts[arm], number, fixed)
    for c in cohorts.values():
        c.audit_memory()
        replace(c)
