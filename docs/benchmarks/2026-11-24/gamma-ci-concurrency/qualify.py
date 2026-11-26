"""Exercise real Go CI jobs behind independently published ports on one Gamma worker."""

import argparse
import hashlib
import http.client
import json
import math
import os
import re
import shutil
import signal
import sys
import tarfile
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path[:0] = [str(HERE.parent / "gamma-local-peer"), str(ROOT / "scripts")]
import bench_go_fanout as fanout
import run as peer
from run import local_admission, local_qos, receiver, relay, require, terminal

IMAGE = "micropod-internal/go-cache-fanout:r7zsq0"
CONFIG = "cb8603c28332918143157ab6706d633d898a30ab79a66ccd1e5a536f8046104a"
LABEL = "io.micropod.bench.ci-concurrency"
BASELINE = HERE.parent / "disposable-local-fixture/20261124T101312Z-local-iad8j2_g/preserved/manifest.json"
BASELINE_SHA = "8e7826379b6ae9afd581d179a64b5a0aa11c1efa18f6ba30cd0ea13669f0163e"
CI_CASES = [
    (16, [(16, "AB"), (4, "BA"), (4, "AB"), (16, "BA")]),
    (32, [(4, "BA"), (32, "AB"), (32, "BA"), (4, "AB")]),
]


def check_baseline():
    require(terminal.digest(BASELINE) == BASELINE_SHA, "original baseline manifest changed")
    manifest = json.loads(BASELINE.read_bytes())
    root = Path(manifest["source"])
    for name, digest in manifest["sha256"].items():
        require(terminal.digest(root / name) == digest, f"original input changed: {name}")
        require(terminal.digest(BASELINE.parent / name) == digest, f"preserved copy changed: {name}")
    return len(manifest["sha256"])


def cli(engine, *args, timeout=90):
    proc = terminal.invoke(*engine, *args, timeout=timeout)
    return proc.stdout.strip()


class Admission(local_admission.Admission):
    def __init__(self, folder):
        super().__init__(folder)
        self.orb_id = None
        self.serving = False
        self.owner = ""
        self.names = set()
        self.offered = None

    def observe(self, *, force=False):
        if not force and time.monotonic() - self.last_check < 2:
            return
        super().observe(force=force)
        for pid, exe, argv in local_admission.processes():
            if exe.name == "fixed" and argv[1:2] == ["--targets"]:
                try:
                    own_group = os.getpgid(pid) == self.receiver_group
                except ProcessLookupError:
                    continue
                require(
                    self.offered
                    and own_group
                    and exe.resolve() == self.offered[0]
                    and argv[1:] == ["--targets", str(self.offered[1])]
                    and terminal.digest(self.offered[1]) == self.offered[2],
                    "unrelated multi-port client",
                )
        rows = local_admission.read_json(peer.SOCKET, "/containers/json")
        for r in rows:
            if r["Id"] == self.orb_id:
                continue
            require(
                self.owner
                and r.get("Labels", {}).get(LABEL) == self.owner
                and len(r["Names"]) == 1
                and r["Names"][0].lstrip("/") in self.names,
                "unrelated OrbStack workload is active",
            )
        require(not self.serving or any(r["Id"] == self.orb_id for r in rows), "peer service stopped")
        with (self.folder / "orb-inventory.jsonl").open("a") as out:
            print(json.dumps({"time": terminal.now(), "running": [r["Id"] for r in rows]}), file=out)


def request(job, path, method="GET", timeout=15):
    connection = http.client.HTTPConnection("127.0.0.1", job["port"], timeout=timeout)
    try:
        connection.request(method, path, headers={"Connection": "close", "Accept-Encoding": "identity"})
        response = connection.getresponse()
        data = response.read()
        require(
            response.status == 200 or response.status == 204,
            f"{job['name']} {path}: HTTP {response.status}: {data[:4096]!r}",
        )
        return data
    finally:
        connection.close()


def ci_image_identity(image_archive):
    with tarfile.open(image_archive) as a:
        (manifest,) = json.load(a.extractfile("manifest.json"))
        config = a.extractfile(manifest["Config"]).read()
        require(
            hashlib.sha256(config).hexdigest() == CONFIG and manifest["RepoTags"] == [IMAGE],
            "wrong offline CI image",
        )
        (descriptor,) = json.load(a.extractfile("index.json"))["manifests"]
        image_id = descriptor["digest"].removeprefix("sha256:")
        image_manifest = a.extractfile("blobs/sha256/" + image_id).read()
        require(
            hashlib.sha256(image_manifest).hexdigest() == image_id
            and json.loads(image_manifest)["config"]["digest"] == "sha256:" + CONFIG,
            "wrong image manifest",
        )
    return {"ci_config_sha256": CONFIG, "manifest_id": "sha256:" + image_id,
            "layer_ids": json.loads(config)["rootfs"]["diff_ids"]}


def inputs(folder, work, image_archive, *, pages=False, accounting=False):
    image = ci_image_identity(image_archive)
    binary = work / "tenant"
    env = {**os.environ, "GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0"}
    terminal.invoke(
        "go",
        "build",
        "-trimpath",
        "-o",
        binary,
        HERE / "tenant.go",
        HERE / "artifact.go",
        env=env,
        timeout=180,
    )
    binary.chmod(0o755)
    (work / "job.sh").write_text(fanout.JOB)
    sources = [
        *HERE.glob("*.py"),
        HERE / "tenant.go",
        HERE / "artifact.go",
        HERE / "link_udp_linux.go",
        HERE / "private_qdisc_linux.go",
        HERE.parent / "batch11-private-vmnet-mtu/relay_mss.c",
        HERE / "kernel-observer.sh",
        ROOT / "ci/runner/published-ports.sh",
        ROOT / "ci/runner/start.sh",
        Path(fanout.__file__),
        Path(peer.__file__),
        Path(terminal.__file__),
        Path(local_admission.__file__),
        Path(receiver.__file__),
        Path(relay.__file__),
    ]
    from build_pages import stage
    probes = stage(work, sources, env, pages=pages, accounting=accounting)
    hvf = ROOT / "scripts/relaybench/hvf_notify"
    sources.extend([hvf / name for name in ("flows.c", "flows.S", "vm.c", "vm.h")])
    sources.append(hvf.parent / "hvf_tx_probe/apple.c")
    with tarfile.open(folder / "sources.tar.gz", "x:gz") as archive:
        for source in sorted(set(sources)):
            archive.add(source, arcname=source.relative_to(ROOT))
    return {
        **probes,
        **image,
        "tenant_binary_sha256": terminal.digest(binary),
        "job_sha256": terminal.digest(work / "job.sh"),
        "sources": {str(p.relative_to(ROOT)): terminal.digest(p) for p in sources},
    }


class Cohort:
    def __init__(self, arm, engine, runner, workspace, folder, admission, kernel_study=False, link_study=False,
                 docker_queues=(), service_cpus=None, docker_cpuset=False):
        self.arm, self.engine, self.runner = arm, engine, runner
        self.workspace, self.folder, self.admission = workspace, folder, admission
        self.owner = runner.root.name
        token = hashlib.sha256(self.owner.encode()).hexdigest()[:10]
        self.prefix = f"mci-{token}-{arm.lower()}-"
        self.volume = self.prefix + "cache"
        self.jobs = []
        self.expected = set()
        self.volume_planned = False
        self.kernel_study = kernel_study
        self.link_study = link_study
        self.docker_queues = docker_queues
        self.service_cpus = service_cpus
        self.docker_cpuset = docker_cpuset

    def cmd(self, *args, **kwargs):
        return cli(self.engine, *args, **kwargs)

    def register(self, name):
        self.expected.add(name)
        if self.arm == "B":
            self.admission.names.add(name)

    def job_flags(self, name):
        return [
            "--pull=never",
            "--name",
            name,
            "--label",
            f"{LABEL}={self.owner}",
            "--cpus",
            "1",
            "--memory",
            "512m",
            "--pids-limit",
            "192",
            "--mount",
            f"type=volume,src={self.volume},dst=/cache,volume-nocopy",
            "--mount",
            f"type=bind,src={self.workspace / 'probe'},dst=/mpcheck,readonly",
            "-e",
            "GOMAXPROCS=1",
            "-e",
            "GOFLAGS=-trimpath -p=1",
            "-e",
            "GOMODCACHE=/cache/mod",
            "-e",
            "GOCACHE=/cache/build",
        ]

    def create_volume(self):
        require(self.volume not in self.cmd("volume", "ls", "-q").splitlines(), "cache name collision")
        self.volume_planned = True
        require(
            self.cmd("volume", "create", "--label", f"{LABEL}={self.owner}", self.volume) == self.volume,
            "could not create owned Linux cache volume",
        )

    def add(self, n):
        new = list(range(len(self.jobs), n))
        if not new:
            return
        start = time.monotonic()
        for i in new:
            name = self.prefix + str(i)
            self.register(name)

        def create(i):
            name = self.prefix + str(i)
            cookie = int(hashlib.sha256(name.encode()).hexdigest()[:15], 16) or 1
            queue = self.docker_queues[i % 2] if self.docker_queues else None
            mask = self.service_mask(i)
            taskset = mask and not self.docker_cpuset
            cid = self.cmd(
                "run",
                "-d",
                *self.job_flags(name),
                *(["--cpuset-cpus", mask] if self.docker_cpuset else []),
                *(["--sysctl", f"net.ipv4.tcp_limit_output_bytes={queue}"] if queue else []),
                "-p",
                "127.0.0.1::8080",
                *(["-e", "MCI_KERNEL_STUDY=1"] if self.kernel_study else []),
                *(["-e", "MCI_LINK_STUDY=1"] if self.link_study else []),
                "--entrypoint",
                "/usr/bin/taskset" if taskset else "/mpcheck/tenant",
                IMAGE,
                *(["-c", mask, "/mpcheck/tenant"] if taskset else []),
                name,
                str(cookie),
            )
            require(re.fullmatch("[0-9a-f]{64}", cid), f"invalid container ID {cid}")
            addr = self.cmd("port", cid, "8080/tcp")
            require(re.fullmatch(r"127\.0\.0\.1:[1-9][0-9]*", addr), f"invalid port for {name}: {addr}")
            job = {"id": cid, "name": name, "port": int(addr.split(":")[1]), "cookie": cookie}
            deadline = time.monotonic() + 12
            while True:
                try:
                    info = json.loads(request(job, "/identity"))
                    break
                except (OSError, http.client.HTTPException):
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(0.1)
            require(
                info["name"] == name
                and info["cookie"] == cookie
                and info["cpu"] == "100000 100000"
                and info["pids"] == "192"
                and info["memory"] == str(512 << 20),
                f"incorrect effective identity or limits for {name}: {info}",
            )
            job["identity"] = info
            if queue:
                require(info["tcp_queue"] == str(queue), f"{name} received a different TCP queue")
            return job

        with ThreadPoolExecutor(max_workers=4) as pool:
            self.jobs.extend(pool.map(create, new))
        require(
            len({j["port"] for j in self.jobs}) == n
            and len({j["identity"]["cgroup"] for j in self.jobs}) == n,
            "duplicate port or cgroup",
        )
        terminal.save(
            self.folder / f"tenants-{self.arm}-{n}.json",
            {"new_count": len(new), "provision_seconds": time.monotonic() - start, "tenants": self.jobs},
        )
        self.running()

    def service_mask(self, index):
        if self.service_cpus == "spread":
            # Both queue sizes and both artifact types occur equally often on each CPU.
            return str(index // 2 % 4)
        if self.service_cpus == "pairs":
            return ("0-1", "2-3")[index // 2 % 2]
        return "0-3" if self.service_cpus == "shared" else None

    def record_service_cpus(self, phase):
        if not self.service_cpus:
            return
        def sample(item):
            i, job = item
            script = r'''set -eu
expected=$(printf '%s\n%s\n%s' /mpcheck/tenant "$1" "$2")
pid=
for path in /proc/[0-9]*/cmdline; do
    [ -r "$path" ] || continue
    [ "$(tr '\000' '\n' < "$path" 2>/dev/null)" = "$expected" ] || continue
    [ -z "$pid" ] || { echo "duplicate service process for $1" >&2; exit 1; }
    pid=${path%/cmdline}
done
[ -n "$pid" ] || { echo "missing service process for $1, namespace init is $(cat /proc/1/comm)" >&2; exit 1; }
awk '$1=="Cpus_allowed_list:" {print $2}' "$pid"/task/*/status'''
            if self.docker_cpuset:
                script += "\ncat /sys/fs/cgroup/cpuset.cpus.effective"
            actual = self.cmd("exec", job["id"], "sh", "-ec", script, "sh", job["name"], str(job["cookie"])).splitlines()
            mask = self.service_mask(i)
            effective = actual.pop() if self.docker_cpuset and actual else None
            require(not self.docker_cpuset or effective == mask, f"{job['name']} effective cgroup CPUs differ")
            require(actual and set(actual) == {mask}, f"service {job['name']} did not keep its thread affinity")
            return {"id": job["id"], "name": job["name"], "mask": mask, "threads": len(actual),
                    **({"cgroup_cpus": effective} if self.docker_cpuset else {})}
        with ThreadPoolExecutor(max_workers=4) as pool:
            rows = list(pool.map(sample, enumerate(self.jobs)))
        require(len(rows) == 32, "CPU placement needs the full service cohort")
        terminal.save(self.folder / f"service-cpus-{self.arm}-{phase}.json", rows)

    def running(self):
        rows = json.loads(self.cmd("inspect", *(j["id"] for j in self.jobs)))
        require(len(rows) == len(self.jobs), "missing CI participants")
        for i, (j, row) in enumerate(zip(self.jobs, rows, strict=True)):
            if self.docker_cpuset:
                require(row["HostConfig"]["CpusetCpus"] == self.service_mask(i), "Docker inspect lost the CPU list")
            if self.docker_queues:
                require(row["HostConfig"]["Sysctls"]["net.ipv4.tcp_limit_output_bytes"] == str(self.docker_queues[i % 2]),
                        "Docker inspect lost the service TCP queue")
            require(
                row["Id"] == j["id"]
                and row["Config"]["Labels"][LABEL] == self.owner
                and row["State"]["Running"]
                and not row["State"].get("OOMKilled"),
                f"CI participant exited: {j['name']} {row['State']}",
            )
        self.runner.guard()
        return len(rows)

    def check_docker_cpuset(self):
        if not self.docker_cpuset or self.arm != "A":
            return
        name = self.prefix + "cpu-restart"
        self.register(name)
        program = """set -eu
awk '/^Cpus_allowed_list:/ {print $2}' /proc/self/status
cat /sys/fs/cgroup/cpuset.cpus.effective /sys/fs/cgroup/cpu.max"""
        args = ["create", *self.job_flags(name), "--network", "none", "--entrypoint", "/bin/sh"]
        invalid = terminal.invoke(*self.engine, *args, "--cpuset-cpus", "0,4", IMAGE, "-ec", program, check=False)
        require(invalid.returncode != 0 and "CPU 4 is unavailable" in invalid.stderr, "out-of-allocation CPU accepted")
        cid = self.cmd(*args, "--cpuset-cpus", "1-2", IMAGE, "-ec", program)
        require(re.fullmatch(r"[0-9a-f]{64}", cid), "invalid cpuset test container ID")
        expected = ["1-2", "1-2", "100000 100000"]
        states = []
        for attempt in range(2):
            self.cmd("start", cid)
            require(self.cmd("wait", cid) == "0", "cpuset test process failed")
            actual = self.cmd("logs", cid).splitlines()
            require(actual == expected * (attempt + 1), "effective CPU mask or bandwidth changed on restart")
            state = json.loads(self.cmd("inspect", cid))[0]
            require(state["Id"] == cid and state["HostConfig"]["CpusetCpus"] == "1-2",
                    "Docker restart lost its CPU list")
            states.append(actual[-3:])
        self.cmd("rm", cid)
        terminal.save(self.folder / "docker-cpuset-restart.json", {"id": cid, "states": states,
                      "out_of_range": "0,4", "rejection": invalid.stderr.strip(), "removed": True})

    def cleanup(self):
        # Listing the exact run label also finds creates interrupted before the CLI returned an ID.
        ids = self.cmd("ps", "-aq", "--no-trunc", "--filter", f"label={LABEL}={self.owner}").splitlines()
        if ids:
            rows = json.loads(self.cmd("inspect", *ids))
            require(
                all(
                    r["Config"]["Labels"].get(LABEL) == self.owner
                    and r["Name"].lstrip("/") in self.expected
                    and r["Id"] in ids
                    for r in rows
                ),
                "ambiguous container cleanup",
            )
            self.cmd("rm", "-f", *ids, timeout=120)
        require(not self.cmd("ps", "-aq", "--filter", f"label={LABEL}={self.owner}"), "unremoved CI jobs")
        if self.volume_planned and self.volume in self.cmd("volume", "ls", "-q").splitlines():
            (info,) = json.loads(self.cmd("volume", "inspect", self.volume))
            require(
                info["Name"] == self.volume and info["Labels"].get(LABEL) == self.owner,
                "ambiguous cache ownership",
            )
            self.cmd("volume", "rm", self.volume)
        require(self.volume not in self.cmd("volume", "ls", "-q").splitlines(), "CI Linux cache remains")
        terminal.save(
            self.folder / f"cleanup-jobs-{self.arm}.json", {"ids_removed": ids, "cache_absent": self.volume}
        )

    def audit_memory(self):
        rows = []
        for job in self.jobs:
            current = json.loads(request(job, "/identity"))
            events = {k: int(v) for k, v in (line.split() for line in current["memory_events"].splitlines())}
            peak = int(current["memory_peak"])
            require(
                current["cookie"] == job["cookie"]
                and current["cgroup"] == job["identity"]["cgroup"]
                and events["oom"] == events["oom_kill"] == 0
                and peak > 0,
                "CI memory or identity check failed",
            )
            rows.append({"id": job["id"], "cgroup": current["cgroup"], "peak_bytes": peak, "events": events})
        terminal.save(self.folder / f"memory-{self.arm}.json", rows)


def build_job(job, revision, origin):
    started = time.monotonic()
    output = request(job, "/build?rev=" + revision, "POST", 190).decode().strip()
    built = time.monotonic()
    row = fanout.parse_job(output, built - started)
    binary = request(job, "/artifact", timeout=45)
    digest = hashlib.sha256(binary).hexdigest()
    require(
        row["revision"] == revision
        and row["tests"] == 8
        and row["product"] == digest
        and row["cpu_s"] > 0
        and min(row[k] for k in ("compile", "vet", "link")) > 0
        and len(binary) > 0
        and binary[:4] == b"\x7fELF",
        f"{job['name']} failed revision, tests, CPU or ELF artifact verification",
    )
    row.update(
        name=job["name"],
        submitted_s=started - origin,
        build_done_s=built - origin,
        done_s=time.monotonic() - origin,
        artifact_bytes=len(binary),
    )
    return row


def percentile(values, q):
    return sorted(values)[math.ceil(len(values) * q) - 1]


def window(cohort, active, code, started=None):
    n = cohort.running()
    jobs = cohort.jobs
    pre_idle = receiver.path_pilot.cpu_idle()
    start = time.monotonic()
    probes, builds, errors = [], [], []

    def probe(i, due):
        j = jobs[i % n]
        observed = time.monotonic()
        try:
            require(request(j, "/health", timeout=5).decode() == j["name"], "wrong endpoint")
            error = None
        except (OSError, ValueError, http.client.HTTPException) as exc:
            error = str(exc) or type(exc).__name__
        return {
            "job": i % n,
            "due_s": due - start,
            "sent_s": observed - start,
            "scheduled_ms": (time.monotonic() - due) * 1000,
            "error": error,
        }

    with ThreadPoolExecutor(max_workers=24) as health, ThreadPoolExecutor(max_workers=active) as workers:
        fs = [workers.submit(build_job, j, f"{code}j{i:02}", start) for i, j in enumerate(jobs)]
        if started is not None:
            started.set()
        i = 0
        while any(not f.done() for f in fs):
            due = start + i / 40
            time.sleep(max(0, due - time.monotonic()))
            probes.append(health.submit(probe, i, due))
            i += 1
        for future in fs:
            try:
                builds.append(future.result())
            except (OSError, ValueError, http.client.HTTPException) as exc:
                errors.append(str(exc) or type(exc).__name__)
        samples = [f.result() for f in probes]
    ok = [s["scheduled_ms"] for s in samples if not s["error"]]
    end = max((b["done_s"] for b in builds), default=0)
    row = {
        "arm": cohort.arm,
        "resident": n,
        "active_limit": active,
        "revision_prefix": code,
        "pre_idle": pre_idle,
        "host_monotonic_start": start,
        "jobs": builds,
        "errors": errors,
        "seconds": end,
        "fresh": samples,
        "fresh_p95_ms": percentile(ok, 0.95) if ok else None,
        "artifact_bytes": sum(b["artifact_bytes"] for b in builds),
    }
    terminal.save(cohort.folder / f"wave-{code}-{cohort.arm}.json", row)
    require(
        not errors
        and len(builds) == n
        and len(ok) == len(samples)
        and len({s["job"] for s in samples}) == n
        and len({b["product"] for b in builds}) == n,
        f"wave {code} failed: {errors[:2]}, {len(ok)}/{len(samples)} fresh probes",
    )
    require(
        all(
            len({b[k] for b in builds}) == 1
            for k in ("boot", "module_inode", "dependency_inode", "dependency")
        ),
        "Go jobs did not share the Linux boot or dependency cache",
    )
    cohort.running()
    print(
        f"{cohort.arm} {code}: {n} jobs, limit {active}, {end:.2f}s, p95 {row['fresh_p95_ms']:.1f}ms",
        flush=True,
    )
    return row


def study(folder, args):
    baseline = check_baseline()
    matched = args.profile in ("qos", "workers")
    mode = "workers" if args.profile == "workers" else "host-role"
    opts = terminal.parse_options(["--mode", mode, "--socket-evidence", "route", "--run"])
    files = terminal.fixture_files(opts)
    worker = peer.CANDIDATE
    publication_mtu = getattr(args, "publication_mtu", None)
    link_workers = getattr(args, "link_workers", 2)
    link_role = getattr(args, "link_role", "Standard")
    product_build = getattr(args, "product_build", None)
    test_repair = getattr(args, "verify_link_repair", False)
    ext4_batch_us = getattr(args, "ext4_batch_us", None)
    require(ext4_batch_us is None or product_build, "ext4 measurement requires a production link worker")
    require(
        not test_repair or (product_build and publication_mtu == 9000),
        "link repair needs a 9000-byte production worker",
    )
    relay_mode = "kqueue-throughput" if getattr(args, "receive_window", "bounded") == "auto" else "kqueue-interactive"
    require(publication_mtu or relay_mode == "kqueue-interactive", "window experiments use the private link fixture")
    steering = args.profile == "link-steering"
    boot_steering = getattr(args, "boot_steering", None)
    flow_steering = getattr(args, "flow_steering", None)
    require(flow_steering is None or boot_steering, "flow steering requires the native private receive queue")
    receive_cpus = getattr(args, "receive_cpus", None)
    require(not receive_cpus or flow_steering == "off", "receive CPU comparison needs flow steering disabled")
    updated_start = getattr(args, "current_guest_start", False)
    trace_handshakes = getattr(args, "trace_handshakes", False)
    parent_mac = getattr(args, "parent_reply_mac", False)
    tso_off = getattr(args, "guest_tso_off", False)
    gso = getattr(args, "guest_gso_bytes", None)
    gso_at_boot = getattr(args, "gso_at_creation", False)
    require(not gso_at_boot or gso in (32768, 40960, 45056), "creation-time GSO needs a measured segmentation limit")
    tsq = getattr(args, "guest_tsq_bytes", None)
    docker_tsq = getattr(args, "docker_tsq", False)
    mixed_artifacts = getattr(args, "mixed_artifacts", False)
    service_cpus = getattr(args, "service_cpus", None)
    docker_cpuset = getattr(args, "docker_cpuset", False)
    build_placement = getattr(args, "build_cpus", None)
    build_scratch = getattr(args, "build_scratch", None)
    require(not build_scratch or build_placement, "build scratch comparison requires a native build CPU set")
    if build_placement and not build_scratch:
        build_scratch = "root"
    require(not build_placement or docker_cpuset, "native build placement requires a Docker CPU placement peer")
    require(not service_cpus or args.profile == "link-peer", "service affinity requires a paired private worker")
    require(not docker_cpuset or (service_cpus and product_build), "Docker CPU placement requires a native peer worker")
    alternate_queue = getattr(args, "alternate_docker_tsq", None)
    require(not alternate_queue or (docker_tsq and alternate_queue != tsq),
            "alternating service queues need two different Docker limits")
    require(not mixed_artifacts or args.profile == "link-peer", "mixed services require a paired link worker")
    require(not docker_tsq or (tsq and boot_steering), "Docker queue comparison needs a limit and a guest engine")
    qdisc = getattr(args, "private_qdisc", None)
    transmit = parent_mac or tso_off or gso or tsq or qdisc
    require(sum(map(bool, (parent_mac, tso_off, gso, tsq, qdisc))) <= 1,
            "change one publication transmit setting at a time")
    require(not transmit or (product_build and args.profile == "link-peer"),
            "testing transmit settings requires the native paired publication path")
    require(not updated_start or args.profile == "link-peer" or steering,
            "guest startup qualification needs a paired link worker")
    require(not trace_handshakes or args.profile == "link-peer", "capture needs the private paired link worker")
    require(not boot_steering or (product_build and args.profile == "link-peer"),
            "boot-time steering requires a paired production link worker")
    link_profile = args.profile in ("link-peer", "link-route") or steering
    build_slots = getattr(args, "build_slots", 4)
    require(build_slots == 4 or args.profile == "link-peer" or steering, "variable concurrency requires a paired link study")
    require(not steering or product_build, "receive steering requires a profiled production worker")
    require(link_profile == (publication_mtu is not None), "link experiments need an explicit publication MTU")
    require(link_profile or link_workers == 2, "link worker selection requires a link profile")
    require(link_profile or link_role == "Standard", "link role selection requires a link profile")
    require(link_profile or product_build is None, "production link builds require a link profile")
    page_kib = getattr(args, "page_kib", None)
    pair_dir = getattr(args, "page_kernel_pair", None)
    accounting = getattr(args, "build_accounting", False)
    thp_dir = getattr(args, "mthp_kernel", None)
    thp_policy = getattr(args, "mthp_16k", None)
    require(bool(thp_dir) == bool(thp_policy) and not (thp_dir and pair_dir),
            "select one kernel trial with its matching policy")
    require(not thp_dir or (args.profile == "link-peer" and build_placement), "mTHP needs the paired build workload")
    live_pages = 4 if thp_dir else page_kib
    require(bool(page_kib) == bool(pair_dir), "choose both the kernel pair and its active page size")
    require(not page_kib or args.profile == "link-peer", "guest page comparison uses the paired CI fixture")
    require(not accounting or build_placement, "phase accounting uses the native build dispatcher")
    kernel_sha = relay.STOCK_KERNEL
    page_meta = {}
    if page_kib:
        import build_pages
        page_meta = build_pages.select(pair_dir, page_kib, files, folder)
        kernel_sha = page_meta["kernel_image_sha256"]
    if thp_dir:
        import build_pages
        import build_thp
        page_meta = build_thp.select(thp_dir, thp_policy, files, folder)
        kernel_sha = page_meta["kernel_image_sha256"]
    link_build = {}
    read_kib = getattr(args, "relay_read_kib", None)
    require(not read_kib or args.profile == "link-peer", "relay read comparison needs a paired worker")
    if publication_mtu:
        import private_link

        link_build = private_link.select(files, product_build)
        require(not read_kib or link_build.get("experimental_read_bytes") == 524288,
                "relay read comparison needs the switchable 512 KiB build")
        terminal.save(folder / "worker-build.json", link_build)
        if product_build is not None:
            shutil.copy2(product_build.resolve().parent / "worker.patch", folder / "worker.patch")
        worker = link_build["worker_executable_sha256"]
    elif mode == "workers":
        worker = "9618161826b37f5a3d7433c9d6a88fa3637e6a6fcc16cfd14b2a263dbcb89aeb"
        rec = json.loads(files["build"].read_bytes())
        require(
            rec["source_revision"] == receiver.FIXED_WORKERS_REV
            and rec["controlled_relay"] == receiver.FIXED_BUILD_CONTROLS
            and rec["entitlements"]["com.apple.security.virtualization"] is True,
            "wrong fixed-budget build",
        )
        terminal.invoke("codesign", "--verify", "--strict", files["cli"])
    else:
        local_qos.signed_worker(files["build"])
    require(
        terminal.digest(files["cli"]) == worker and terminal.digest(files["fixed"]) == peer.CLIENT,
        "worker selection changed",
    )
    terminal.check_archives(files)
    terminal.verify_cache()
    admission = Admission(folder)
    admission.check(force=True)
    runner = terminal.Run(opts, folder, admission)
    root = runner.root
    admission.owner = root.name
    cohorts = {}
    cleanup_errors = []
    try:
        guest_start = ROOT / "ci/runner/start.sh"
        guest_start_sha = terminal.digest(guest_start)
        packaged_start = link_build.get("guest_start_sha256") == guest_start_sha
        workspace, oci, clients = terminal.stage(
            root, files, runner_start=guest_start if (updated_start or docker_cpuset) and not packaged_start else None
        )
        if thp_dir:
            build_thp.stage_observer(oci)
        native_gso = gso_at_boot and boot_steering == "worker"
        guest_runner_sha = None
        if gso_at_boot or docker_tsq or docker_cpuset:
            if boot_steering == "worker":
                guest_runner_sha = link_build["guest_runner_sha256"]
            else:
                guest_runner_sha = private_link.stage_guest_runner(oci, folder)
        if boot_steering:
            source = ROOT / "ci/runner/published-ports.sh"
            helper = oci / "runner/published-ports.sh"
            if boot_steering == "guest":
                shutil.copy2(source, helper)
                # Use the production guest code with the older Mac executable as a separate control.
                start = oci / "runner/start.sh"
                text = start.read_text()
                tag = '. "$tools/runner/published-ports.sh"'
                require(text.count(tag) == 1, "unknown guest publication startup")
                start.write_text(text.replace(tag, 'export MICROPOD_CI_PUBLISHED_RPS=off-irq\n' + tag))
            require(terminal.digest(helper) == terminal.digest(source), "booted guest script differs from source")
        if publication_mtu:
            link_secret = private_link.stage(oci, workspace, publication_mtu, configure_guest=product_build is None,
                                             test_repair=test_repair, trace=product_build is not None,
                                             trace_handshakes=trace_handshakes,
                                             parent_gso_bytes=gso if gso_at_boot and not native_gso else None)
        if args.profile == "kernel" or steering or boot_steering or transmit or docker_cpuset:
            import kernel_ci

            kernel_ci.stage(workspace, oci, qdisc_probe=bool(qdisc))
        probe = workspace / "probe"
        if "role_probe" in files:
            shutil.copy2(files["role_probe"], probe / "netbench")
        archive = args.image_archive or root / "go.tar"
        if not args.image_archive:
            cli(peer.DOCKER, "image", "save", "-o", archive, IMAGE, timeout=180)
        meta = inputs(folder, probe, archive, pages=bool(live_pages), accounting=accounting)
        terminal.save(
            folder / "plan.json",
            dict(
                meta,
                **page_meta,
                **({"build_accounting": True} if accounting else {}),
                host=cli(["hostname"]),
                scope=str(root),
                profile=args.profile,
                initial_baseline_files=baseline,
                **({"ext4_batch_us": ext4_batch_us} if ext4_batch_us is not None else {}),
                **({"boot_steering": boot_steering, "guest_publication_sha256": terminal.digest(helper)}
                   if boot_steering else {}),
                **({"flow_steering": flow_steering} if flow_steering else {}),
                **({"receive_cpus": receive_cpus} if receive_cpus else {}),
                **({"guest_start_sha256": guest_start_sha,
                    "guest_start_origin": "packaged" if packaged_start else "current source"}
                   if updated_start or packaged_start or docker_cpuset else {}),
                **({"trace_handshakes": True} if trace_handshakes else {}),
                **({"parent_reply_mac": True} if parent_mac else {}),
                **({"guest_ipv4_tso": "off"} if tso_off else {}),
                **({"guest_gso_bytes": gso} if gso else {}),
                **({"guest_runner_sha256": guest_runner_sha} if guest_runner_sha else {}),
                **({"gso_at_creation": True,
                    "gso_origin": "worker" if native_gso else "guest control"} if gso_at_boot else {}),
                **({"guest_tsq_bytes": tsq} if tsq else {}),
                **({"mixed_artifacts": True} if mixed_artifacts else {}),
                **({"service_cpus": service_cpus} if service_cpus else {}),
                **({"build_cpu_placement": build_placement, "build_scratch": build_scratch} if build_placement else {}),
                **({"docker_cpuset": True} if docker_cpuset else {}),
                **({"relay_read_kib": read_kib} if read_kib else {}),
                **({"docker_tsq": True} if docker_tsq else {}),
                **({"alternate_docker_tsq": alternate_queue} if alternate_queue else {}),
                **({"private_qdisc": qdisc} if qdisc else {}),
                worker=worker,
                **({"publication_mtu": publication_mtu, "relay_mode": relay_mode, "link_workers": link_workers,
                    "link_role": link_role} if publication_mtu else {}),
                started=terminal.now(),
                schedules=CI_CASES if args.profile == "ci" else None,
                host_load="natural, sampled before each wave",
                **({"concurrent_host_work": args.host_activity} if getattr(args, "host_activity", None) else {}),
                cpus=4,
                vm_mib=4096,
                job_cpus=1,
                job_mib=512,
                pids=192,
                fresh_per_second=40,
                cache="one new shared Linux volume per engine",
            ),
        )
        orb = None if matched else peer.orb_scope(root, workspace, admission)
        fixture_args = SimpleNamespace(
            mode=mode,
            build=files["build"],
            socket_evidence="route",
            out=folder,
            tools=clients,
        )

        engines = {}
        policies = {"A": (link_workers, link_role)}
        if matched:
            policies = (
                {"A": (2, "Interactive"), "B": (4, "Interactive")}
                if mode == "workers"
                else {arm: (2, role) for arm, role in local_qos.ROLES.items()}
            )
        for arm, (count, role) in policies.items():
            letter = arm.lower()
            scope, facts = runner.arm(letter, count, files, workspace, oci, process_type=role,
                                      publication_mtu=publication_mtu, relay_mode=relay_mode, product_mtu=product_build is not None,
                                      ext4_batch_us=ext4_batch_us, published_rps=boot_steering == "worker",
                                      published_gso_bytes=gso if native_gso else None, relay_read_kib=read_kib,
                                      anon_thp_16k=thp_policy)
            if thp_dir:
                build_thp.check_boot(workspace, folder, thp_policy, facts)
            if live_pages:
                require("config_sha256=" + page_meta["kernel_config_sha256"] in facts.read_text().splitlines(),
                        "booted guest config differs from selected Image")
            setattr(fixture_args, "scope_" + letter, scope)
            setattr(fixture_args, "facts_" + letter, facts)
            engines[arm] = ["docker", "--host", "unix://" + str(root / letter / "docker.sock")]
            if publication_mtu:
                private_link.prove_running(scope, folder, workspace, link_build, publication_mtu, link_secret)
                if ext4_batch_us is not None:
                    private_link.check_disk_batch(folder, workspace, ext4_batch_us)
        if not matched:
            engines["B"] = peer.DOCKER

        def fixtures():
            result = {}
            for arm, (_, role) in policies.items():
                if publication_mtu:
                    result[arm], live_engine = private_link.inspect(
                        getattr(fixture_args, "scope_" + arm.lower()), link_build, publication_mtu,
                        clients, relay_mode, link_workers, role, read_kib=read_kib, kernel_sha=kernel_sha,
                    )
                else:
                    result[arm], live_engine = receiver.scope_fixture(
                        fixture_args, arm, None if mode == "workers" else role
                    )
                require(
                    engines[arm] == live_engine and result[arm]["cli_sha256"] == worker,
                    "unverified live worker",
                )
            if mode == "workers":
                receiver.equal_workers(result)
            elif matched:
                local_qos.compare_fixtures(result)
            else:
                result["B"] = relay.inspect(orb, 4, True)
                peer.verify_arms(
                    result, candidate_sha=worker, workers=link_workers,
                    callback_events=128 if link_workers == 2 else 24,
                    source_revision=link_build.get("base_revision", relay.STOCK_RELAY_REV),
                    read_bytes=read_kib * 1024 if read_kib else link_build.get("experimental_read_bytes", 262144),
                    process_type=link_role, kernel_sha=kernel_sha,
                )
            return result

        before = fixtures()
        terminal.save(folder / "fixtures-before.json", before)
        for arm in policies:
            runner.waited([*engines[arm], "load", "-i", archive], f"ci-image-{arm}", 360)
        for arm, engine in engines.items():
            (im,) = json.loads(cli(engine, "image", "inspect", IMAGE))
            terminal.save(
                folder / f"image-{arm}.json",
                {k: im.get(k) for k in ("Id", "RepoTags", "RepoDigests", "RootFS")},
            )
            require(
                im["Id"] in ("sha256:" + CONFIG, meta["manifest_id"])
                and im["Architecture"] == "arm64"
                and im["Os"] == "linux",
                f"unexpected Linux workload image {im['Id']}",
            )
            if "RootFS" in im:
                require(im["RootFS"]["Layers"] == meta["layer_ids"], "Linux workload layers differ")
            cohort = cohorts[arm] = Cohort(
                arm,
                engine,
                runner,
                workspace,
                folder,
                admission,
                kernel_study=args.profile == "file-peer" or link_profile or (args.profile == "kernel" and arm == "A"),
                link_study=publication_mtu is not None,
                docker_queues=(tsq, alternate_queue or tsq) if docker_tsq else (),
                service_cpus=service_cpus,
                docker_cpuset=docker_cpuset,
            )
            cohort.create_volume()
            cohort.add(1)
            if live_pages:
                build_pages.probe(cohort, live_pages if arm == "A" else 4)
            print("Priming Linux toolchain on " + arm, flush=True)
            terminal.save(folder / f"prime-{arm}.json", build_job(cohort.jobs[0], "prime", time.monotonic()))
        if args.profile == "kernel":
            kernel_ci.study(cohorts["A"], folder, clients, before["A"])
        elif args.profile == "link-route":
            backends = private_link.check_tenants(cohorts["A"], publication_mtu, before["A"])
            if test_repair:
                private_link.verify_service_repair(
                    cohorts["A"], workspace, fixture_args.scope_a, link_build, publication_mtu
                )
            private_link.route_study(cohorts["A"], folder, clients, before["A"], backends)
        elif args.profile in ("file-peer", "link-peer") or steering:
            import kernel_ci

            monitor = kernel_ci.Observer(cohorts["A"]) if boot_steering or transmit or docker_cpuset else None
            if docker_cpuset and not (docker_tsq or gso_at_boot):
                require(monitor.collect("runner-sha").strip() == guest_runner_sha, "running CPU placement engine differs")
            if parent_mac:
                monitor.collect("parent-reply-on")
            if tso_off:
                original = monitor.collect("offloads-read")
                require("tx-tcp-segmentation: on" in original, "private IPv4 TSO was already disabled")
                changed = monitor.collect("ipv4-tso-off")
                require("tx-tcp-segmentation: off" in changed, "private IPv4 TSO change did not take effect")
                (folder / "ipv4-tso-before.txt").write_text(original)
                (folder / "ipv4-tso-applied.txt").write_text(changed)
            if publication_mtu:
                for cohort in cohorts.values():
                    private_link.check_tenants(cohort, publication_mtu, before[cohort.arm])
                if test_repair:
                    private_link.verify_service_repair(
                        cohorts["A"], workspace, fixture_args.scope_a, link_build, publication_mtu
                    )
            hooks = {}
            if gso:
                def capture_gso(action, size, label):
                    state = dict(line.split() for line in monitor.collect(action).splitlines())
                    require(state.pop("ipv4-tso") == "on" and state.pop("parent") == str(size)
                            and len(state) == 33 and set(state.values()) == {str(size)},
                            "unexpected GSO limit on the leased publication interfaces")
                    terminal.save(folder / f"ipv4-gso-{label}.json", state)

                if gso_at_boot:
                    require(monitor.collect("runner-sha").strip() == guest_runner_sha, "running guest engine differs")
                    capture_gso("gso-read", gso, "before")
                else:
                    capture_gso("gso-read", 65536, "before")
                    capture_gso("gso-" + str(gso), gso, "applied")
                hooks["before_retirement"] = lambda: capture_gso("gso-read", gso, "after")
            if tsq:
                def capture_tsq(action):
                    return dict(line.split() for line in monitor.collect(action).splitlines())

                original = capture_tsq("tsq-read")
                expected = kernel_ci.small_queue_state(original, tsq, cohorts["A"].jobs if docker_tsq else None,
                                                       alternate_queue)
                if docker_tsq:
                    require(monitor.collect("runner-sha").strip() == guest_runner_sha, "running guest engine differs")
                else:
                    require(capture_tsq(f"tsq-{tsq}") == expected, "per-service TCP queue limit did not take effect")

                def verify_tsq():
                    require(capture_tsq("tsq-read") == expected, "private TCP queue or offload controls changed")

                hooks["before_retirement"] = verify_tsq
            if qdisc:
                def capture_qdisc(action, kind):
                    (root_queue,) = json.loads(monitor.collect(action))
                    require(root_queue["root"] and root_queue["kind"] == kind, "unexpected private NIC root qdisc")
                    return root_queue

                capture_qdisc("qdisc-read", "fq")
                applied_queue = capture_qdisc("qdisc-fq-codel", qdisc)

                def verify_qdisc():
                    final = capture_qdisc("qdisc-read", qdisc)
                    require(final["handle"] == applied_queue["handle"] and final["bytes"] > applied_queue["bytes"],
                            "private NIC queue changed or did not transmit")

                hooks["before_retirement"] = verify_qdisc
            counters = None
            if product_build:
                counters = {
                    arm: (lambda _phase, fixture=fx: relay.snapshot(clients, fixture))
                    for arm, fx in before.items()
                }
            if boot_steering:
                first_queue = monitor.collect("rps-read")
                require("rps_cpus=7" in first_queue.splitlines(), "guest did not steer its published receive queue at boot")
            if receive_cpus:
                initial_cpus = dict(line.split("=", 1) for line in first_queue.splitlines())
                require(initial_cpus["effective"] == "3", "expected the private IRQ on CPU 3")
                mask = "c" if receive_cpus == "irq-pair" else "f"
                applied_cpus = kernel_ci.flow_sample(monitor, "rps-" + mask)
                require(int(applied_cpus["rps_cpus"], 16) == int(mask, 16), "private queue rejected CPU mask")
            if flow_steering:
                original = kernel_ci.flow_sample(monitor)
                require(original["queue_flow_entries"] == "0", "fresh private NIC already has flow steering")
                configured = kernel_ci.flow_sample(monitor, "rfs-on") if flow_steering == "on" else original
                expected_entries = ("32768", "32768") if flow_steering == "on" else (original["global_flow_entries"], "0")
                require((configured["global_flow_entries"], configured["queue_flow_entries"]) == expected_entries
                        and configured["egress_flow_entries"] == original["egress_flow_entries"],
                        "unexpected Linux flow tables")
                terminal.save(folder / "flow-steering.json", {"before": original, "configured": configured})
                counters = {arm: kernel_ci.flow_counters(cohorts[arm], monitor if arm == "A" else None, capture)
                            for arm, capture in counters.items()}
            compare = kernel_ci.steering_study if steering else kernel_ci.peer_confirmation
            if mixed_artifacts:
                hooks["mixed_artifacts"] = True
            if build_placement:
                hooks["build_placement"] = build_placement
                hooks["build_scratch"] = build_scratch
                hooks["build_accounting"] = accounting
            if thp_dir or (page_kib and not accounting):
                hooks["observe_vm_memory"] = True
            if trace_handshakes and boot_steering:
                monitor.collect("pressure-start")
            try:
                compare(cohorts, folder, clients / "fixed", getattr(args, "order_seed", 13438), counters, build_slots, **hooks)
            except Exception:
                if boot_steering:
                    try:
                        last_queue = monitor.collect("rps-read")
                        terminal.save(folder / "failed-network-counters.json", {
                            "before": dict(line.split("=", 1) for line in first_queue.splitlines()),
                            "after": dict(line.split("=", 1) for line in last_queue.splitlines()),
                        })
                        monitor.collect("link-failure")
                        if qdisc:
                            monitor.collect("qdisc-read")
                    except (OSError, RuntimeError, ValueError) as observation_error:
                        (folder / "failed-network-observer.txt").write_text(str(observation_error) + "\n")
                raise
            finally:
                if trace_handshakes and boot_steering:
                    monitor.collect("pressure-stop")
                if receive_cpus:
                    try:
                        observed_cpus = kernel_ci.flow_sample(monitor, "rps-read")
                    finally:
                        restored_cpus = kernel_ci.flow_sample(monitor, "rps-7")
                    terminal.save(folder / "receive-cpus.json", {"initial": initial_cpus, "applied": applied_cpus,
                                  "final": observed_cpus, "restored": restored_cpus})
                    require(int(restored_cpus["rps_cpus"], 16) == 7, "private receive mask was not restored")
                if parent_mac:
                    proof = monitor.collect("parent-reply-read")
                    require(re.search(r"@replies ether saddr set [0-9a-f:]+ counter packets [1-9]\d* bytes [1-9]\d* accept",
                                      proof), "no validated replies used the parent MAC")
                    (folder / "parent-replies.txt").write_text(proof)
                if tso_off:
                    (folder / "ipv4-tso-after.txt").write_text(monitor.collect("offloads-read"))
            if boot_steering:
                terminal.save(folder / "boot-steering.json", {
                    "before": dict(line.split("=", 1) for line in first_queue.splitlines()),
                    "after": dict(line.split("=", 1) for line in monitor.collect("rps-read").splitlines()),
                })
            if monitor:
                monitor.collect("done")
        elif args.profile in ("bridge", "buffers", "grants", "low-water"):
            import bridge

            bridge.study(cohorts["A"], folder, profile=args.profile)
        elif args.profile == "fanout":
            import fanout_ci

            fanout_ci.study(cohorts, folder, clients, before)
        elif args.profile == "churn" or matched:
            import churn

            churn.study(cohorts, folder, clients / "fixed", matched)
        else:
            cases = [(4, [(4, "AB")])] if args.profile == "smoke" else CI_CASES
            for n, schedules in cases:
                for arm in "AB":
                    cohorts[arm].add(n)
                for k, (active, order) in enumerate(schedules):
                    for arm in order:
                        window(cohorts[arm], active, f"n{n:02}r{k:02}")
        for arm in list(cohorts):
            if args.profile not in ("churn", "qos", "workers", "file-peer", "link-peer", "link-steering") and not (
                args.profile in ("kernel","link-route") and arm == "A"
            ):
                cohorts[arm].audit_memory()
            cohorts[arm].cleanup()
            del cohorts[arm]
        after = fixtures()
        terminal.save(folder / "fixtures-after.json", after)
        require(after == before, "selected worker or peer changed")
        runner.guard()
    finally:
        for name in ("publication-neighbors.log", "guest-neighbors.log", "publication-setup-trace"):
            events = root / "workspace" / name
            if events.is_file():
                shutil.copy2(events, folder / name)
        for c in cohorts.values():
            try:
                c.cleanup()
            except Exception as exc:  # noqa: BLE001 -- finish teardown of the other owned resources
                cleanup_errors.append(str(exc))
        runner.tearing_down = True
        try:
            if not matched:
                peer.clean_orb(root, folder)
        except Exception as exc:  # noqa: BLE001 -- always stop the private VM
            cleanup_errors.append(str(exc))
        runner.cleanup()
        terminal.save(
            folder / "verification.json",
            {"baseline_files": check_baseline(), "extra_cleanup_errors": cleanup_errors},
        )
        require(
            not cleanup_errors and not runner.errors and not root.exists(),
            f"cleanup incomplete: {cleanup_errors + runner.errors}",
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--profile",
        choices=(
            "smoke", "ci", "bridge", "buffers", "churn", "qos", "workers", "kernel", "grants",
            "file-peer", "fanout", "low-water", "link-peer", "link-route", "link-steering",
        ),
        required=True,
    )
    parser.add_argument("--image-archive", type=Path)
    parser.add_argument("--publication-mtu", type=int, choices=(1500, 8000, 9000))
    parser.add_argument("--receive-window", choices=("bounded", "auto"), default="bounded")
    parser.add_argument("--link-workers", type=int, choices=(2, 3, 4), default=2)
    parser.add_argument("--build-slots", type=int, choices=(4, 6, 8), default=4)
    parser.add_argument("--link-role", choices=("Standard", "Interactive"), default="Standard")
    parser.add_argument("--product-build", type=Path)
    parser.add_argument("--order-seed", type=int, default=13438)
    parser.add_argument("--host-activity", help="record known concurrent work on Gamma for an ambient comparison")
    parser.add_argument("--verify-link-repair", action="store_true")
    parser.add_argument("--boot-steering", choices=("worker", "guest"))
    parser.add_argument("--flow-steering", choices=("off", "on"),
                        help="sample service CPU and compare socket-aware steering on the private receive queue")
    parser.add_argument("--receive-cpus", choices=("irq-pair", "all"),
                        help="allow the private NIC interrupt CPU and its neighbor, or all four CPUs, to receive flows")
    parser.add_argument("--current-guest-start", action="store_true")
    parser.add_argument("--trace-handshakes", action="store_true")
    parser.add_argument("--parent-reply-mac", action="store_true")
    parser.add_argument("--guest-tso-off", action="store_true")
    parser.add_argument("--guest-gso-bytes", type=int, choices=(32768, 40960, 45056, 49152))
    parser.add_argument("--gso-at-creation", action="store_true")
    parser.add_argument("--guest-tsq-bytes", type=int, choices=(98304, 163840, 196608))
    parser.add_argument("--docker-tsq", action="store_true", help="request the same container sysctl from both engines")
    parser.add_argument("--relay-read-kib", type=int, choices=(256, 512))
    parser.add_argument("--mthp-kernel", type=Path, help="4 KiB kernel built with anonymous transparent huge pages")
    parser.add_argument("--mthp-16k", choices=("never", "always"))
    parser.add_argument("--page-kernel-pair", type=Path, help="matched full and full-16k kernel builder outputs")
    parser.add_argument("--page-kib", type=int, choices=(4, 16))
    parser.add_argument("--build-accounting", action="store_true", help="collect wait4 usage for each Go command")
    parser.add_argument("--mixed-artifacts", action="store_true", help="serve files and memory on 16 endpoints each")
    parser.add_argument("--service-cpus", choices=("shared", "spread", "pairs"),
                        help="give services all four guest CPUs or distribute them evenly across single CPUs or CPU pairs")
    parser.add_argument("--docker-cpuset", action="store_true", help="apply service placement through Docker and verify the cgroup")
    parser.add_argument("--build-cpus", choices=("shared", "pairs"),
                        help="apply a Docker CPU set to each build job and verify its effective mask and quota")
    parser.add_argument("--build-scratch", choices=("root", "volume"),
                        help="place private compiler scratch on the container root or the disposable Linux volume")
    parser.add_argument("--alternate-docker-tsq", type=int, choices=(163840, 196608),
                        help="set this queue limit on the odd-numbered Docker services")
    parser.add_argument("--private-qdisc", choices=("fq_codel",))
    parser.add_argument("--ext4-batch-us", type=int, choices=(0,))
    args = parser.parse_args()
    folder = Path(
        tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-") + args.profile + "-", dir=HERE)
    )
    print(folder, flush=True)
    status = {"complete": False, "profile": args.profile}
    signal.signal(signal.SIGTERM, terminal.exit_on_signal)
    try:
        with terminal.terminal_lock():
            study(folder, args)
        status["complete"] = True
    except BaseException as exc:
        status["error"] = str(exc) or type(exc).__name__
        raise
    finally:
        terminal.save(folder / "status.json", dict(status, end=terminal.now()))
