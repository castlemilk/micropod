#!/usr/bin/env python3
"""Controlled paired Gamma benchmarks for Micropod Track A engine tuning vs OrbStack 2.2.5."""
import argparse
import concurrent.futures
import hashlib
import ipaddress
import math
from importlib.util import module_from_spec, spec_from_file_location
import json
import os
import random
import re
import shutil
import signal
import statistics
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

from sibling_dense_load import (
    CPU_PERIOD_US, DenseCompileLoad, FOREGROUND_SCRIPT, compiler_quota_us, foreground_window, parse_compiler_spread_cpus,
    validate_native_compiler_groups,
)

ROOT = Path(__file__).resolve().parent.parent
ORB_SOCK = Path.home() / ".orbstack/run/docker.sock"
DEFAULT_KERNEL = ROOT / ".build/local-kernel-pages/20261124T233020Z-ipvlan-my8pf7su/full-16k/Image"
DEFAULT_PRODUCT_DIR = ROOT / ".build/local-published-tcp/ci-published-link-79cf766b2fde0258"
AUTH_PRODUCT_DIR = ROOT / ".build/local-published-tcp/micropod-authorized-runtime-8YYEiYai"
QUIET_BIN = ROOT / ".build/local-fair-scheduler/125us-quiet"
VMM_ROOT = ROOT.parent.parent / "vmm"
DEFAULT_HVF_BIN = VMM_ROOT / "target/release/micropod-vmm"
DEFAULT_HVF_INITRD = VMM_ROOT / "target/mp-hvf-init.cpio"
DEFAULT_ALPINE_EXT4 = Path.home() / ".micropod/sandbox/images/sha256-469c9ea410b9215eaee7976ba6c0639039b444be8e5d638f7abbada189971eb2-4g.ext4"
DRIVE_HELPER = ROOT / "docs/benchmarks/2026-11-24/gamma-ci-concurrency/worker_apfs_drive.py"
BULK_DEFAULT_BURSTS = 24
BULK_STREAMS = 32
BULK_BYTES_PER_BURST = BULK_STREAMS * (8 << 20)


class BenchmarkWorkerDrive:
    def __init__(self, directory):
        spec = spec_from_file_location("micropod_benchmark_apfs", DRIVE_HELPER)
        self.apfs = module_from_spec(spec)
        spec.loader.exec_module(self.apfs)
        self.directory = directory
        self.home = directory / "home"
        self.home.mkdir(mode=0o700)
        self.scope_id = self.inode(directory.lstat())
        self.home_id = self.inode(self.home.lstat())
        self.log = None
        self.image = directory / "worker.sparseimage"
        self.disk = self.home / "worker.ext4"
        self.receipts = {}

    @staticmethod
    def inode(st):
        return st.st_dev, st.st_ino

    def open_log(self, name):
        path = self.directory / name
        stream = path.open("xb")
        self.log = (path, self.inode(os.fstat(stream.fileno())))
        return stream

    def attach(self):
        # The VZ arm provisions a 16 GiB logical disk. Both arms get the
        # same sparse APFS capacity with space for metadata and image growth.
        self.started = time.monotonic()
        created = self.apfs.create(self.image, self.home, size_gib=32, disabled=True)
        self.receipts["created"] = created
        self.receipts["volume_setup_s"] = round(time.monotonic() - self.started, 4)
        self.home.chmod(0o700)

    def verify_live(self, minimum_bytes):
        ready = time.monotonic()
        live = self.apfs.verify(self.receipts["created"])
        raw = self.disk.lstat()
        if (not stat.S_ISREG(raw.st_mode) or raw.st_dev != live["volume"]["dev"]
                or raw.st_size < minimum_bytes or raw.st_dev == self.directory.stat().st_dev):
            raise RuntimeError(f"writable guest disk is missing from its dedicated volume: {self.disk}")
        self.receipts["live"] = live
        self.receipts["raw_disk"] = {"path": str(self.disk), "inode": raw.st_ino, "device": raw.st_dev,
                                     "bytes": raw.st_size, "allocated_bytes": raw.st_blocks * 512}
        self.receipts["provision_to_ready_s"] = round(ready - self.started, 4)

    def close(self):
        if self.directory.exists() and self.inode(self.directory.lstat()) != self.scope_id:
            raise RuntimeError(f"worker scope identity changed: {self.directory}")
        if "created" in self.receipts and "detached" not in self.receipts:
            before = self.receipts.get("raw_disk")
            expected = (before["inode"], before["bytes"]) if before else None
            retired = self.apfs.detach(self.receipts["created"], remove_image=True, inspect_history=True,
                                       expected_raw_identity=expected)
            self.receipts["detached"] = retired
        if self.home.is_mount() or self.image.exists() or self.image.with_suffix(".apfs-recovery.json").exists():
            raise RuntimeError(f"worker drive requires inspection at {self.directory}")
        if self.directory.exists():
            expected = {self.home}
            if self.log:
                expected.add(self.log[0])
            if (set(self.directory.iterdir()) != expected or self.inode(self.home.lstat()) != self.home_id
                    or any(self.home.iterdir()) or (self.log and self.inode(self.log[0].lstat()) != self.log[1])):
                raise RuntimeError(f"preserved unexpected worker files at {self.directory}")
            if self.log:
                self.log[0].unlink()
            self.home.rmdir()
            self.directory.rmdir()
        return self.receipts


def stop_worker(worker, grace):
    proc = worker.proc
    if proc and proc.poll() is None:
        try:
            if os.getpgid(proc.pid) != proc.pid:
                raise RuntimeError(f"worker lost its private process group: {proc.pid}")
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(timeout=5)
    if hasattr(worker, "_log_file"):
        worker._log_file.close()
    if "created" in worker.drive.receipts and "detached" not in worker.drive.receipts:
        deadline = time.monotonic() + 45
        query_timeout = 5
        observation = {"pid": proc.pid if proc else None, "process_exit_code": proc.returncode if proc else None,
                       "disk_query_timeouts": 0}
        worker.drive.receipts["retirement"] = observation
        while True:
            group_alive = False
            if proc:
                try:
                    os.killpg(proc.pid, 0)
                    group_alive = True
                except ProcessLookupError:
                    pass
            disk = worker.drive.disk
            try:
                holder = run(["/usr/sbin/lsof", "-nP", "-t", str(disk)], timeout=query_timeout, check=False) if disk.exists() else None
            except subprocess.TimeoutExpired as error:
                observation["disk_query_timeouts"] += 1
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError(f"could not verify disk holders; preserved {worker.dir}") from error
                # A busy Mac can take longer than five seconds to enumerate its
                # open files. Give the next complete scan the remaining budget.
                query_timeout = remaining
                continue
            if not group_alive and (holder is None or
                                    (holder.returncode == 1 and not holder.stdout.strip() and not holder.stderr.strip())):
                worker.drive.receipts["shutdown"] = {**observation, "process_group_absent": True,
                                                     "disk_present": holder is not None, "disk_holders": []}
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError(f"worker process group or disk is still in use; preserved {worker.dir}")
            query_timeout = min(query_timeout, remaining)
            time.sleep(0.2)
    return worker.drive.close()


def copy_hvf_seed(source, target, volume_device):
    """Bind the cross-volume disk copy to the configured, read-only seed inode."""
    def identity(st):
        return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns

    def content_hash(stream):
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
        return digest.hexdigest()

    with os.fdopen(os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as seed:
        initial = os.fstat(seed.fileno())
        if (not stat.S_ISREG(initial.st_mode) or initial.st_size <= 0
                or target.parent.stat().st_dev != volume_device or initial.st_dev == volume_device):
            raise RuntimeError(f"expected a regular HVF root filesystem: {source}")
        with tempfile.TemporaryDirectory(dir=target.parent, prefix=".hvf-seed-") as staging:
            private = Path(staging) / "seed.ext4"
            run(["/bin/cp", "-c", str(source), str(private)], timeout=120)
            source_hash = content_hash(seed)
            with os.fdopen(os.open(private, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as copy:
                copied = os.fstat(copy.fileno())
                if (not stat.S_ISREG(copied.st_mode) or copied.st_uid != os.getuid() or copied.st_nlink != 1
                        or copied.st_dev != volume_device or copied.st_size != initial.st_size):
                    raise RuntimeError("invalid staged HVF root filesystem")
                if (content_hash(copy) != source_hash or identity(copied) != identity(private.lstat())
                        or identity(initial) != identity(os.fstat(seed.fileno())) or identity(initial) != identity(source.lstat())):
                    raise RuntimeError("HVF root filesystem source or copy changed during provisioning")
                os.link(private, target, follow_symlinks=False)
                private.unlink()
                published = target.lstat()
                if (published.st_dev, published.st_ino, published.st_nlink) != (volume_device, copied.st_ino, 1):
                    raise RuntimeError("HVF root filesystem did not publish its verified private inode")
    return {"source": str(source), "device": initial.st_dev, "inode": initial.st_ino,
            "bytes": initial.st_size, "mtime_ns": initial.st_mtime_ns, "ctime_ns": initial.st_ctime_ns,
            "source_sha256": source_hash, "private_copy_sha256": source_hash, "private_inode": copied.st_ino}


def run(cmd, env=None, timeout=180, check=True, input_data=None):
    res = subprocess.run(
        cmd,
        env=env,
        input=input_data,
        capture_output=True,
        timeout=timeout,
        text=input_data is None or isinstance(input_data, str),
    )
    if check and res.returncode != 0:
        raise RuntimeError(
            f"cmd failed ({res.returncode}): {' '.join(map(str, cmd))}\n"
            f"stdout: {res.stdout[-800:] if isinstance(res.stdout, str) else ''}\n"
            f"stderr: {res.stderr[-800:] if isinstance(res.stderr, str) else ''}"
        )
    return res


def docker(sock, *args, timeout=120, check=True):
    return run(["docker", "--host", f"unix://{sock}", *args], timeout=timeout, check=check)


def pct(vals, p):
    if not vals:
        return None
    s = sorted(vals)
    idx = min(len(s) - 1, max(0, int(round((p / 100.0) * (len(s) - 1)))))
    return s[idx]


def stage_oci_tools(base_tools: Path, dst_tools: Path, rebuild_runner: bool = False):
    shutil.copytree(base_tools, dst_tools, symlinks=True)
    # Copy current start.sh and published-ports.sh from checkout
    for name in ("start.sh", "published-ports.sh"):
        src = ROOT / "ci/runner" / name
        dst = dst_tools / "runner" / name
        shutil.copy2(src, dst)
        dst.chmod(0o755)
    if rebuild_runner:
        env = dict(os.environ)
        env.pop("GOROOT", None)
        env.update({"GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0"})
        subprocess.run(
            ["go", "build", "-trimpath", "-o", str(dst_tools / "runner/bin/job"), "."],
            cwd=str(ROOT / "guest/runner"),
            env=env,
            check=True,
            capture_output=True,
            text=True,
        )
        (dst_tools / "runner/bin/job").chmod(0o755)


class WorkerHandle:
    def __init__(self, name, micropod_bin, tools_dir, kernel_path, kernel_args, workspace, extra_env=None):
        self.name = name
        self.dir = Path(tempfile.mkdtemp(prefix=f"mp-tune-{name}-", dir="/private/tmp"))
        self.drive = BenchmarkWorkerDrive(self.dir)
        self.home = self.drive.home
        self.micropod_bin = Path(micropod_bin)
        self.tools_dir = Path(tools_dir)
        self.kernel_path = Path(kernel_path)
        self.kernel_args = kernel_args
        self.workspace = Path(workspace)
        self.extra_env = extra_env or {}
        self.proc = None
        self.sock = self.home / "docker.sock"
        self.boot_s = None

    def env(self):
        e = dict(os.environ)
        e.update({
            "MICROPOD_CI_CPUS": "4",
            "MICROPOD_CI_MEMORY_MIB": "4096",
            "MICROPOD_CI_OCI_TOOLS": str(self.tools_dir),
            "MICROPOD_CI_KERNEL": str(self.kernel_path),
            "MICROPOD_CI_PUBLISHED_PATH": "macvlan",
            "MICROPOD_CI_PORT_RELAY": "kqueue-throughput",
            "MICROPOD_CI_PORT_RELAY_WORKERS": "2",
        })
        if self.kernel_args:
            e["MICROPOD_SANDBOX_KERNEL_ARGS"] = self.kernel_args
        e.update(self.extra_env)
        e.update({"MICROPOD_CI_VMM": "vz", "MICROPOD_CI_ENGINE": "containerd",
                  "MICROPOD_CI_HOME": str(self.home), "MICROPOD_CI_WORKSPACE": str(self.workspace),
                  "MICROPOD_CI_DISK_GIB": "16"})
        return e

    def start(self):
        self.drive.attach()
        t0 = time.perf_counter()
        log_path = self.dir / "serve.log"
        self._log_file = self.drive.open_log("serve.log")
        self.proc = subprocess.Popen(
            [str(self.micropod_bin), "ci", "serve"],
            env=self.env(),
            start_new_session=True,
            stdout=self._log_file,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
        )
        deadline = time.perf_counter() + 120.0
        while time.perf_counter() < deadline:
            if self.proc.poll() is not None:
                self._log_file.flush()
                tail = log_path.read_text(errors="replace")[-2000:]
                raise RuntimeError(f"worker {self.name} exited early ({self.proc.returncode}):\n{tail}")
            if self.sock.is_socket():
                r = docker(self.sock, "info", "--format", "{{.NCPU}}", timeout=3, check=False)
                if r.returncode == 0 and r.stdout.strip() == "4":
                    self.boot_s = round(time.perf_counter() - t0, 4)
                    config = json.loads((self.home / "worker.json").read_bytes())
                    self.drive.verify_live(int(config["diskGiB"]) << 30)
                    return self.boot_s
            time.sleep(0.05)
        tail = log_path.read_text(errors="replace")[-2000:]
        raise RuntimeError(f"worker {self.name} timed out booting:\n{tail}")

    def stop(self):
        return stop_worker(self, 15)


class HVFWorkerHandle:
    """Direct launcher for the Rust Hypervisor.framework CI worker (micropod-vmm)."""

    def __init__(self, name, vmm_bin, initrd_path, tools_dir, kernel_path, workspace, mtu=9000, wakeup="next-buddy", cc=None, idle_poll_us=None):
        self.name = name
        self.dir = Path(tempfile.mkdtemp(prefix=f"mp-hvf-{name}-", dir="/private/tmp"))
        self.drive = BenchmarkWorkerDrive(self.dir)
        self.home = self.drive.home
        self.vmm_bin = Path(vmm_bin)
        self.initrd_path = Path(initrd_path)
        self.tools_dir = Path(tools_dir)
        self.kernel_path = Path(kernel_path)
        self.workspace = Path(workspace)
        self.mtu = mtu
        self.wakeup = wakeup
        self.cc = cc
        self.idle_poll_us = idle_poll_us
        self.disk = self.drive.disk
        self.sock = self.home / "docker.sock"
        self.oci_sock = self.home / "oci.sock"
        self.proc = None
        self.boot_s = None
        self.vmm_summary = None

    def start(self):
        self.drive.attach()
        seed = copy_hvf_seed(DEFAULT_ALPINE_EXT4, self.disk, self.drive.receipts["created"]["volume"]["dev"])
        self.drive.receipts["rootfs_seed"] = seed
        cc_arg = f" micropod.ci_cc={self.cc}" if self.cc else ""
        poll_arg = f" idle_poll_us={self.idle_poll_us}" if self.idle_poll_us else ""
        cmdline = (
            "quiet console=ttyAMA0 rcupdate.rcu_expedited=1 psi=1 "
            "cgroup.memory=nokmem,nosocket slab_min_order=2 swiotlb=noforce "
            "workqueue.power_efficient=1 micropod.ci_sched=hrtick-250us "
            f"micropod.ci_wakeup={self.wakeup} micropod.ci_sysctls=perf{cc_arg}{poll_arg} "
            f"mp.workspace={self.workspace} mp.mtu={self.mtu} panic=-1"
        )
        t0 = time.perf_counter()
        log_path = self.dir / "vmm.log"
        self._log_file = self.drive.open_log("vmm.log")
        self.proc = subprocess.Popen(
            [
                str(self.vmm_bin),
                "--kernel", str(self.kernel_path),
                "--initrd", str(self.initrd_path),
                "--disk", str(self.disk),
                "--cpus", "4",
                "--memory-mib", "4096",
                "--share", f"oci-tools:{self.tools_dir}:ro",
                "--share", f"workspace:{self.workspace}",
                "--vsock-expose", f"{self.sock}:2375",
                "--vsock-expose", f"{self.oci_sock}:2376",
                "--published-net",
                "--published-mtu", str(self.mtu),
                "--cmdline", cmdline,
            ],
            start_new_session=True,
            stdout=self._log_file,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
        )
        deadline = time.perf_counter() + 60.0
        while time.perf_counter() < deadline:
            if self.proc.poll() is not None:
                self._log_file.flush()
                tail = log_path.read_text(errors="replace")[-2000:]
                raise RuntimeError(f"HVF worker {self.name} exited early ({self.proc.returncode}):\n{tail}")
            if self.sock.is_socket():
                r = docker(self.sock, "info", "--format", "{{.NCPU}}", timeout=3, check=False)
                if r.returncode == 0 and r.stdout.strip() == "4":
                    self.boot_s = round(time.perf_counter() - t0, 4)
                    self.drive.verify_live(seed["bytes"])
                    return self.boot_s
            time.sleep(0.025)
        tail = log_path.read_text(errors="replace")[-2000:]
        raise RuntimeError(f"HVF worker {self.name} timed out booting:\n{tail}")

    def stop(self):
        return stop_worker(self, 10)


def load_images(sock, image_tar):
    with open(image_tar, "rb") as f:
        res = subprocess.run(
            ["docker", "--host", f"unix://{sock}", "load"],
            stdin=f,
            capture_output=True,
            timeout=120,
        )
    if res.returncode != 0:
        raise RuntimeError(f"docker load failed: {res.stderr.decode(errors='replace')}")


def inspect_guest_tuning(sock):
    cmd = (
        "cat /proc/cmdline; echo ---; "
        "for p in vm/compaction_proactiveness vm/watermark_boost_factor vm/overcommit_memory "
        "kernel/sched_rt_runtime_us net/core/rmem_max net/core/wmem_max net/ipv4/tcp_rmem net/ipv4/tcp_wmem; do "
        "printf '%s=%s\\n' \"$p\" \"$(cat /proc/sys/$p 2>/dev/null || echo NA)\"; done"
    )
    r = docker(sock, "run", "--rm", "alpine:3.23", "sh", "-c", cmd, timeout=30)
    return r.stdout.strip()


def verify_oom_kill(sock):
    name = f"mp-oom-{uuid.uuid4().hex[:8]}"
    # Allocate ~64 MiB inside a 32 MiB memory limit using alpine dd into /dev/shm or awk/sh
    # Use netbench or busybox awk string doubling to trigger clean anonymous RSS OOM
    r = docker(
        sock,
        "run",
        "--name", name,
        "--memory", "32m",
        "--cpus", "1",
        "alpine:3.23",
        "awk", 'BEGIN{s="0123456789abcdef"; for(i=0;i<26;i++) s=s s; print length(s)}',
        timeout=30,
        check=False,
    )
    ins = docker(sock, "inspect", "--format", "{{.State.OOMKilled}} {{.State.ExitCode}}", name, timeout=15)
    docker(sock, "rm", "-f", name, timeout=15, check=False)
    parts = ins.stdout.strip().split()
    return {
        "returncode": r.returncode,
        "oom_killed": parts[0] == "true" if len(parts) >= 1 else False,
        "exit_code": int(parts[1]) if len(parts) >= 2 else r.returncode,
    }


def sibling_resources(sock, label):
    containers = docker(sock, "ps", "--all", "--filter", f"label={label}", "--format", "{{.Names}}", timeout=20)
    networks = docker(sock, "network", "ls", "--filter", f"label={label}", "--format", "{{.Name}}", timeout=20)
    return containers.stdout.splitlines(), networks.stdout.splitlines()


def cleanup_sibling_resources(sock, label):
    containers, networks = sibling_resources(sock, label)
    errors = []
    for command, names in ((["rm", "-f"], containers), (["network", "rm"], networks)):
        for name in names:
            try:
                result = docker(sock, *command, name, timeout=20, check=False)
                if result.returncode:
                    errors.append(f"{name}: {result.stderr.strip()}")
            except (OSError, subprocess.TimeoutExpired) as exc:
                errors.append(f"{name}: {exc}")
    containers, networks = sibling_resources(sock, label)
    if containers or networks:
        raise RuntimeError(f"sibling benchmark cleanup left {containers + networks}: {'; '.join(errors)}")


def sibling_probe_digests(sock, server, client):
    files = ["netbench-linux", "quiet-http"]
    output = docker(sock, "exec", client, "sha256sum", *(f"/mpw/{name}" for name in files), timeout=15).stdout
    hashes = {Path(file).name: digest for digest, file in (line.split() for line in output.splitlines())}
    server_digest = docker(sock, "exec", server, "/mpw/netbench-linux", "-self-sha256", timeout=15).stdout.strip()
    if set(hashes) != set(files) or hashes["netbench-linux"] != server_digest:
        raise RuntimeError("server and client did not read the same netbench binary")
    return hashes


def bulk_rate_key(bursts):
    return "sibling_6gib_bulk_mibs" if bursts == BULK_DEFAULT_BURSTS else "sibling_bulk_mibs"


def verified_sibling_bulk(sample, expected_cc, bursts=BULK_DEFAULT_BURSTS):
    accepted = sample.get("accepted_tcp_congestion")
    rate = sample.get("mib_s")
    return (sample.get("mode") == "bulk" and sample.get("streams") == BULK_STREAMS and sample.get("iterations") == bursts
            and sample.get("bytes") == bursts * BULK_BYTES_PER_BURST and sample.get("reopened_connections") == 0
            and isinstance(rate, (int, float)) and math.isfinite(rate) and rate > 0
            and isinstance(accepted, list) and len(accepted) == BULK_STREAMS
            and all(isinstance(cc, str) and cc and cc == cc.strip() for cc in accepted)
            and (expected_cc is None or all(cc == expected_cc for cc in accepted)))


def sibling_address(sock, container, network):
    deadline = time.monotonic() + 3
    while True:
        record, = json.loads(docker(sock, "inspect", container, timeout=8).stdout)
        endpoint = (record["NetworkSettings"].get("Networks") or {}).get(network) or {}
        address = endpoint.get("IPAddress") or ""
        try:
            return str(ipaddress.IPv4Address(address))
        except ipaddress.AddressValueError:
            if not record["State"]["Running"] or time.monotonic() >= deadline:
                logs = docker(sock, "logs", "--tail", "80", container, timeout=8, check=False)
                raise RuntimeError(f"{container} has no IPv4 address on {network}: "
                                   f"state={record['State']}, endpoint={endpoint}, logs={(logs.stdout + logs.stderr)[:650]}")
        time.sleep(0.1)


def bench_in_guest_suite(sock, engine_label, workspace, net_driver="bridge", rounds=3, sibling_cc=None,
                         report_congestion=False, probe_image=None, bulk_bursts=BULK_DEFAULT_BURSTS,
                         align_dense_bulk=False):
    """Run quiet HTTP, single & 32-client DNS, and a sized sibling bulk sample."""
    if type(bulk_bursts) is not int or not 1 <= bulk_bursts <= 1024:
        raise ValueError("bulk bursts must be between 1 and 1024")
    scope = uuid.uuid4().hex
    tag = f"mpb-{scope[:8]}"
    label = f"com.micropod.benchmark.scope={scope}"
    net_name = f"{tag}-net"
    svc_name = f"{tag}-svc"
    cli_name = f"{tag}-cli"
    report_congestion = report_congestion or sibling_cc is not None
    try:
        net_args = ["network", "create", "--internal", "--driver", net_driver, "--label", label]
        probe_mount = [] if probe_image else ["-v", f"{workspace}:/mpw:ro"]
        server_image = probe_image or "micropod-qa/netbench:local"
        client_image = probe_image or "alpine:3.23"
        service_options = []
        server_flags = ["-report-tcp-congestion"] if report_congestion else []
        bulk_flags = list(server_flags)
        if report_congestion:
            service_options = [*probe_mount, "--entrypoint", "/mpw/netbench-linux"]
        if sibling_cc is not None:
            net_args += ["--opt", f"com.micropod.network.tcp-congestion={sibling_cc}"]
            bulk_flags += ["-verify-tcp-congestion", sibling_cc]
        docker(sock, *net_args, net_name, timeout=30)
        # Start service container (netbench -listen :8080 -marker ok)
        docker(
            sock,
            "run", "-d",
            "--name", svc_name,
            "--label", label,
            "--network", net_name,
            "--network-alias", "svc",
            "--cpus", "4",
            "--memory", "512m",
            *service_options,
            server_image,
            "-listen", ":8080",
            "-marker", tag,
            *server_flags,
            timeout=30,
        )
        svc_ip = sibling_address(sock, svc_name, net_name)

        # Start client container with quiet-http mounted read-only (sleep helper via alpine or netbench? Wait: netbench image is scratch!)
        # For quiet HTTP, mount quiet binary into alpine:3.23 container!
        docker(
            sock,
            "run", "-d",
            "--name", cli_name,
            "--label", label,
            "--network", net_name,
            "--cpus", "4",
            "--memory", "512m",
            *probe_mount, client_image,
            "sleep", "600",
            timeout=30,
        )

        # Wait for service reachable
        for _ in range(40):
            r = docker(
                sock, "exec", cli_name, "/mpw/netbench-linux",
                "-url", f"http://{svc_ip}:8080", "-marker", tag, "-requests", "2",
                timeout=10, check=False,
            )
            if r.returncode == 0:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(f"{engine_label}: service did not become reachable at {svc_ip}")

        probe_digests = sibling_probe_digests(sock, svc_name, cli_name) if report_congestion else None

        quiet_unrestricted_p50 = []
        quiet_unrestricted_p95 = []
        dns1_p50, dns1_p95 = [], []
        dns32_p50, dns32_p95 = [], []
        bulk_mibs = []
        bulk_verification = []
        bulk_guest_windows = []

        for r_idx in range(rounds):
            # 1. Quiet HTTP (unrestricted, 200 reqs on 1 verified reused socket)
            q_out = docker(
                sock, "exec", cli_name, "/mpw/quiet-http",
                "-url", f"http://{svc_ip}:8080",
                "-marker", tag,
                "-requests", "200",
                timeout=30,
            ).stdout
            q_json = json.loads(q_out)
            if not q_json.get("complete"):
                raise RuntimeError(f"{engine_label}: quiet-http incomplete")
            totals_us = [s["total_ns"] / 1000.0 for s in q_json["samples"]]
            quiet_unrestricted_p50.append(pct(totals_us, 50))
            quiet_unrestricted_p95.append(pct(totals_us, 95))

            # 2. Single-resolver DNS (1000 lookups to 'svc')
            d1_out = docker(
                sock, "exec", cli_name, "/mpw/netbench-linux",
                "-url", "http://svc:8080", "-marker", tag,
                "-requests", "2", "-lookups", "1000", "-dns-clients", "1",
                timeout=30,
            ).stdout
            d1 = json.loads(d1_out)
            dns1_p50.append(d1["dns_p50_us"])
            dns1_p95.append(d1["dns_p95_us"])

            # 3. 32-resolver concurrent DNS (100 lookups x 32 clients = 3200 lookups)
            d32_out = docker(
                sock, "exec", cli_name, "/mpw/netbench-linux",
                "-url", "http://svc:8080", "-marker", tag,
                "-requests", "2", "-lookups", "100", "-dns-clients", "32",
                timeout=30,
            ).stdout
            d32 = json.loads(d32_out)
            dns32_p50.append(d32["dns_p50_us"])
            dns32_p95.append(d32["dns_p95_us"])

            # 4. Sustained sibling bulk transfer (8 MiB per stream per burst).
            prefix = ["sh", "-c", FOREGROUND_SCRIPT, "dense-tcp"] if align_dense_bulk else []
            exec_start = time.monotonic_ns()
            bulk = docker(
                sock, "exec", cli_name, *prefix, "/mpw/netbench-linux",
                "-url", f"http://{svc_ip}:8080", "-marker", tag,
                "-profile", "bulk", "-streams", str(BULK_STREAMS), "-bursts", str(bulk_bursts),
                *bulk_flags,
                timeout=max(60, bulk_bursts // 2),
            )
            exec_end = time.monotonic_ns()
            b_json = json.loads(bulk.stdout)
            if report_congestion:
                if not verified_sibling_bulk(b_json, sibling_cc, bulk_bursts):
                    raise RuntimeError(f"{engine_label}: unverified sibling bulk result {b_json}")
                bulk_verification.append(b_json)
            if align_dense_bulk:
                bulk_guest_windows.append(foreground_window(bulk.stderr, b_json.get("elapsed_s"), exec_start, exec_end))
            bulk_mibs.append(b_json["mib_s"])

        # 5. Same-CPU pinned quiet HTTP (both svc & cli pinned to CPU 0)
        svc_pin = f"{tag}-svcp"
        cli_pin = f"{tag}-clip"
        docker(
            sock, "run", "-d", "--name", svc_pin, "--network", net_name, "--label", label,
            "--cpuset-cpus", "0", "--cpus", "1", "--memory", "256m",
            *service_options,
            server_image, "-listen", ":8080", "-marker", tag,
            *server_flags,
            timeout=30,
        )
        svcp_ip = sibling_address(sock, svc_pin, net_name)
        docker(
            sock, "run", "-d", "--name", cli_pin, "--network", net_name, "--label", label,
            "--cpuset-cpus", "0", "--cpus", "1", "--memory", "256m",
            *probe_mount, client_image, "sleep", "300",
            timeout=30,
        )
        for _ in range(30):
            if docker(sock, "exec", cli_pin, "/mpw/netbench-linux", "-url", f"http://{svcp_ip}:8080", "-marker", tag, "-requests", "2", timeout=10, check=False).returncode == 0:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(f"{engine_label}: pinned service did not become reachable at {svcp_ip}")
        quiet_pinned_p50, quiet_pinned_p95 = [], []
        for _ in range(rounds):
            q_out = docker(
                sock, "exec", cli_pin, "/mpw/quiet-http",
                "-url", f"http://{svcp_ip}:8080", "-marker", tag, "-requests", "200",
                timeout=30,
            ).stdout
            q_json = json.loads(q_out)
            totals_us = [s["total_ns"] / 1000.0 for s in q_json["samples"]]
            quiet_pinned_p50.append(pct(totals_us, 50))
            quiet_pinned_p95.append(pct(totals_us, 95))

        rate_key = bulk_rate_key(bulk_bursts)
        result = {
            "engine": engine_label,
            "net_driver": net_driver,
            "quiet_unrestricted_p50_us": round(statistics.median(quiet_unrestricted_p50), 2),
            "quiet_unrestricted_p95_us": round(statistics.median(quiet_unrestricted_p95), 2),
            "quiet_pinned_p50_us": round(statistics.median(quiet_pinned_p50), 2),
            "quiet_pinned_p95_us": round(statistics.median(quiet_pinned_p95), 2),
            "dns1_p50_us": round(statistics.median(dns1_p50), 2),
            "dns1_p95_us": round(statistics.median(dns1_p95), 2),
            "dns32_p50_us": round(statistics.median(dns32_p50), 2),
            "dns32_p95_us": round(statistics.median(dns32_p95), 2),
            rate_key: round(statistics.median(bulk_mibs), 1),
            "raw": {
                "quiet_unrestricted_p50_us": quiet_unrestricted_p50,
                "quiet_pinned_p50_us": quiet_pinned_p50,
                "dns1_p95_us": dns1_p95,
                "dns32_p95_us": dns32_p95,
                rate_key: bulk_mibs,
            },
        }
        if report_congestion:
            result["raw"]["bulk_verification"] = bulk_verification
            result["probe_sha256"] = probe_digests
        if align_dense_bulk:
            result["raw"]["bulk_guest_windows"] = bulk_guest_windows
        if bulk_bursts != BULK_DEFAULT_BURSTS:
            result["sibling_bulk_bytes"] = bulk_bursts * BULK_BYTES_PER_BURST
        result["scope"] = label
        return result
    finally:
        cleanup_sibling_resources(sock, label)


def _bench_sibling_pairs(workspace, net_driver, pairs, variants, dense_loads=None, probe_image=None,
                         bulk_bursts=BULK_DEFAULT_BURSTS):
    base, candidate = variants
    expected_digests = {name: hashlib.sha256((workspace / name).read_bytes()).hexdigest()
                        for name in ("netbench-linux", "quiet-http")}
    blocks = []
    gains = []
    for i in range(pairs):
        order = (base, candidate) if i % 2 == 0 else (candidate, base)
        arms = {}
        for name in order:
            sock, engine, expected_cc = variants[name]
            load = dense_loads[name] if dense_loads is not None else None

            def measure():
                return bench_in_guest_suite(
                    sock, engine, workspace, net_driver=net_driver, rounds=1,
                    sibling_cc=expected_cc, report_congestion=True, probe_image=probe_image,
                    bulk_bursts=bulk_bursts, align_dense_bulk=load is not None,
                )

            arms[name] = load.measure(sock, measure) if load is not None else measure()
            if arms[name]["probe_sha256"] != expected_digests:
                raise RuntimeError(f"{engine}: executed probe bytes do not match the shared workspace")
        baseline, tuned = (arms[name]["raw"][bulk_rate_key(bulk_bursts)][0] for name in (base, candidate))
        gain = 100 * (tuned / baseline - 1)
        gains.append(gain)
        blocks.append({"order": order, "arms": arms, "bulk_gain_pct": round(gain, 2)})
        print(f"  sibling TCP pair {i + 1}: {base} {baseline:.1f}, {candidate} {tuned:.1f} MiB/s ({gain:+.2f}%)", flush=True)
    return {"pairs": blocks, "cubic_bulk_wins": sum(gain > 0 for gain in gains),
            "probe_sha256": expected_digests, "median_bulk_gain_pct": round(statistics.median(gains), 2)}


def bench_sibling_congestion_pair(sock, workspace, net_driver, pairs):
    return _bench_sibling_pairs(workspace, net_driver, pairs, {
        "bbr": (sock, "micropod-hvf", "bbr"), "cubic": (sock, "micropod-hvf", "cubic"),
    })


def bench_live_sibling_pairs(hvf_socket, orbstack_socket, workspace, net_driver="ipvlan", pairs=4,
                             dense_compile=False, compiler_cpus=None, probe_image=None, compiler_in_image=False,
                             probe_manifest=None, compiler_period_us=CPU_PERIOD_US, bulk_bursts=BULK_DEFAULT_BURSTS,
                             compiler_spread_cpus=None, native_compiler_groups=False):
    """Compare tuned HVF with stock OrbStack on two existing Docker sockets."""
    hvf_socket, orbstack_socket = Path(hvf_socket), Path(orbstack_socket)
    if not hvf_socket.is_socket() or not orbstack_socket.is_socket() or hvf_socket.samefile(orbstack_socket):
        raise ValueError("live sibling comparison requires two distinct Docker socket paths")
    if pairs < 2 or pairs % 2:
        raise ValueError("live sibling comparison requires an even pair count of at least two")
    workspace = Path(workspace).resolve(strict=True)
    if compiler_cpus is not None and compiler_spread_cpus is not None:
        raise ValueError("compiler_cpus and compiler_spread_cpus are mutually exclusive")
    if (compiler_cpus or compiler_spread_cpus is not None) and not dense_compile:
        raise ValueError("compiler placement requires a dense compile comparison")
    if native_compiler_groups:
        if not dense_compile:
            raise ValueError("native compiler groups require a dense compile comparison")
        validate_native_compiler_groups(parse_compiler_spread_cpus(compiler_spread_cpus))
        version = docker(hvf_socket, "info", "--format", "{{.ServerVersion}}", timeout=15).stdout.strip()
        if version != "micropod":
            raise ValueError("native compiler groups require a Micropod Docker endpoint")
    if compiler_period_us != CPU_PERIOD_US and not dense_compile:
        raise ValueError("compiler period requires a dense compile comparison")
    compiler_quota_us(compiler_period_us)
    if compiler_in_image and not (probe_image and dense_compile):
        raise ValueError("an image-resident compiler requires a probe image and a dense comparison")
    if probe_manifest and not probe_image:
        raise ValueError("an OCI probe manifest requires a probe image")
    fixture_id = None
    if probe_image:
        ids = [docker(socket, "image", "inspect", "--format", "{{.Id}}", probe_image).stdout.strip()
               for socket in (hvf_socket, orbstack_socket)]
        if probe_manifest:
            encoded = Path(probe_manifest).read_bytes()
            manifest = json.loads(encoded)
            config_digest = (manifest.get("config") or {}).get("digest", "")
            if manifest.get("schemaVersion") != 2 or not manifest.get("layers") or not re.fullmatch(r"sha256:[a-f0-9]{64}", config_digest):
                raise ValueError("expected an OCI image manifest with layers")
            fixture_id = "sha256:" + hashlib.sha256(encoded).hexdigest()
            allowed = {fixture_id, config_digest}
        else:
            fixture_id = ids[0]
            allowed = {fixture_id}
        if not all(re.fullmatch(r"sha256:[a-f0-9]{64}", value) and value in allowed for value in ids):
            raise ValueError("both engines must have the same immutable probe image")
    dense_loads = None
    if dense_compile:
        options = dict(compiler_cpus=compiler_cpus, image=probe_image if compiler_in_image else None,
                       compiler_period_us=compiler_period_us, compiler_spread_cpus=compiler_spread_cpus)
        explicit = DenseCompileLoad(docker, workspace, **options)
        native = DenseCompileLoad(docker, workspace, native_compiler_groups=True, **options) if native_compiler_groups else explicit
        dense_loads = {"orbstack": explicit, "cubic": native}
    results = _bench_sibling_pairs(workspace, net_driver, pairs, {
        "orbstack": (orbstack_socket, "orbstack", None), "cubic": (hvf_socket, "micropod-hvf", "cubic"),
    }, dense_loads=dense_loads, probe_image=probe_image, bulk_bursts=bulk_bursts)
    results["probe_image_id"] = fixture_id
    return results


def bench_ephemeral_churn(sock, engine_label, count=32, concurrency=8, rounds=3):
    """Run 32 ephemeral --rm Alpine containers at concurrency 8 to measure container lifecycle throughput."""
    walls = []
    for _ in range(rounds):
        t0 = time.perf_counter()
        def one(i):
            r = docker(
                sock, "run", "--rm", "--network", "none",
                "--cpus", "1", "--memory", "128m",
                "alpine:3.23", "echo", f"ok-{i}",
                timeout=30,
            )
            if f"ok-{i}" not in r.stdout:
                raise RuntimeError(f"bad output: {r.stdout}")
        with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
            futs = [pool.submit(one, i) for i in range(count)]
            for f in futs:
                f.result()
        walls.append(round(time.perf_counter() - t0, 4))
    med = statistics.median(walls)
    return {
        "engine": engine_label,
        "containers": count,
        "concurrency": concurrency,
        "median_wall_s": round(med, 4),
        "containers_per_s": round(count / med, 2),
        "rounds_s": walls,
    }


def bench_published_tcp(sock, engine_label, offered_bin, rounds=4):
    """Run single-port 32-stream + 40 fresh req/s published TCP benchmark."""
    scope = uuid.uuid4().hex
    tag = f"mppub-{scope[:12]}"
    label = f"com.micropod.benchmark.published={scope}"
    try:
        docker(
            sock, "run", "-d",
            "--name", tag,
            "--label", label,
            "-p", "127.0.0.1::8080",
            "--cpus", "4",
            "--memory", "1g",
            "micropod-qa/netbench:local",
            "-listen", ":8080", "-marker", tag,
            timeout=30,
        )
        port_out = docker(sock, "port", tag, "8080/tcp", timeout=15).stdout.strip().splitlines()[0]
        port = port_out.rsplit(":", 1)[-1].strip()
        url = f"http://127.0.0.1:{port}"
        # Wait reachable
        for _ in range(40):
            r = subprocess.run(["curl", "-sf", "--max-time", "1", f"{url}/id"], capture_output=True, text=True)
            if r.returncode == 0 and r.stdout.strip() == tag:
                break
            time.sleep(0.1)
        else:
            return {"engine": engine_label, "error": f"published port {url} unreachable (possible Local Network TCC)"}

        # 1 warmup + N scored rounds (warmup ignores transient initial reopen; scored rounds are strict)
        run([str(offered_bin), url, tag], timeout=45, check=False)
        mibs, p50s, p95s, p99s, losses, reopens = [], [], [], [], 0, 0
        samples = []
        for _ in range(rounds):
            out = run([str(offered_bin), url, tag], timeout=45).stdout
            j = json.loads(out)
            if (j["published_ports"], j["streams"], j["arrivals"], j["period_us"]) != (1, 32, 240, 25000):
                raise RuntimeError(f"{engine_label}: incomplete offered workload")
            samples.append(j)
            mibs.append(j["mib_s"])
            p50s.append(j["fresh_p50_us"] / 1000.0)
            p95s.append(j["fresh_p95_us"] / 1000.0)
            p99s.append(j["fresh_p99_us"] / 1000.0)
            losses += len(j.get("errors") or [])
            reopens += j.get("reopened", 0)
        return {
            "engine": engine_label,
            "median_mib_s": round(statistics.median(mibs), 1),
            "fresh_p50_ms": round(statistics.median(p50s), 3),
            "fresh_p95_ms": round(statistics.median(p95s), 3),
            "fresh_p99_ms": round(statistics.median(p99s), 3),
            "fresh_failures": losses,
            "bulk_reopens": reopens,
            "raw_mib_s": mibs,
            "raw_p95_ms": p95s,
            "samples": samples,
        }
    finally:
        cleanup_sibling_resources(sock, label)


def live_siblings(argv):
    ap = argparse.ArgumentParser(description="Compare a running Micropod HVF worker with OrbStack on the same checkout.")
    ap.add_argument("--hvf-socket", required=True, type=Path, help="Unix path from the HVF worker's runner-docker-endpoint")
    ap.add_argument("--orbstack-socket", type=Path, default=ORB_SOCK)
    ap.add_argument("--workspace", required=True, type=Path, help="Shared directory containing netbench-linux and quiet-http")
    ap.add_argument("--pairs", type=int, default=4)
    ap.add_argument("--driver", choices=["bridge", "ipvlan"], default="ipvlan")
    ap.add_argument("--dense", action="store_true", help="Run 32 compiler containers per arm, using workspace/compile (Linux ARM64)")
    placement = ap.add_mutually_exclusive_group()
    placement.add_argument("--compiler-cpus", help="Pin all 32 compilers to this canonical Linux CPU list, e.g. 2-3")
    placement.add_argument("--compiler-spread-cpus", help="Pin compilers round-robin to distinct guest CPUs, e.g. 0,1,2,3")
    ap.add_argument("--native-compiler-groups", action="store_true",
                    help="Let Micropod place the dense workers across --compiler-spread-cpus and verify their balance")
    ap.add_argument("--compiler-period-us", type=int, default=CPU_PERIOD_US,
                    help="Set the dense CFS period in microseconds while keeping .0625 CPU per worker (default 100000)")
    ap.add_argument("--bulk-bursts", type=int, default=BULK_DEFAULT_BURSTS,
                    help="8 MiB transfers per bulk stream (default 24 = 6 GiB, 240 = 60 GiB)")
    ap.add_argument("--probe-image", help="Use a preloaded Alpine image with both probes in /mpw")
    ap.add_argument("--probe-manifest", type=Path, help="OCI manifest bytes when engines report different image ID formats")
    ap.add_argument("--compiler-in-image", action="store_true", help="Run the compiler from /mpw/compile in the same image")
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args(argv)
    if args.out.exists():
        ap.error("choose a new receipt path")
    try:
        compiler_quota_us(args.compiler_period_us)
        spread = parse_compiler_spread_cpus(args.compiler_spread_cpus)
        if args.native_compiler_groups:
            validate_native_compiler_groups(spread)
    except ValueError as error:
        ap.error(str(error))
    if not 1 <= args.bulk_bursts <= 1024:
        ap.error("--bulk-bursts must be between 1 and 1024")
    if args.compiler_period_us != CPU_PERIOD_US and not args.dense:
        ap.error("--compiler-period-us requires --dense")
    if (args.compiler_cpus or args.compiler_spread_cpus is not None or args.native_compiler_groups) and not args.dense:
        ap.error("compiler placement requires --dense")
    info = {}
    for key, sock in (("micropod", args.hvf_socket), ("orbstack", args.orbstack_socket)):
        raw = json.loads(docker(sock, "info", "--format", "{{json .}}").stdout)
        info[key] = {k: raw.get(k) for k in ("Name", "OperatingSystem", "ServerVersion", "NCPU", "MemTotal")}
    if (info["micropod"]["ServerVersion"] != "micropod" or info["orbstack"]["OperatingSystem"] != "OrbStack"):
        ap.error("could not verify the Micropod and OrbStack endpoints")
    measured = bench_live_sibling_pairs(args.hvf_socket, args.orbstack_socket, args.workspace, args.driver, args.pairs,
                                        dense_compile=args.dense, compiler_cpus=args.compiler_cpus,
                                        probe_image=args.probe_image, compiler_in_image=args.compiler_in_image,
                                        probe_manifest=args.probe_manifest, compiler_period_us=args.compiler_period_us,
                                        bulk_bursts=args.bulk_bursts, compiler_spread_cpus=args.compiler_spread_cpus,
                                        native_compiler_groups=args.native_compiler_groups)
    with args.out.open("x") as output:
        json.dump({"engines": info, "direct": measured}, output, indent=2)
        output.write("\n")


def main():
    if sys.argv[1:2] == ["live-siblings"]:
        live_siblings(sys.argv[2:])
        return
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--rebuild-runner", action="store_true")
    ap.add_argument("--use-auth-binary", action="store_true", help="Use TCC-authorized Mac binary for published TCP")
    ap.add_argument("--skip-published", action="store_true")
    ap.add_argument("--include-hvf", action="store_true", help="Include micropod-hvf (Rust HVF VMM) arm")
    ap.add_argument("--skip-control", action="store_true", help="Skip untuned micropod-control arm for faster 3-way run")
    ap.add_argument("--hvf-mtu", type=int, default=9000)
    ap.add_argument("--kernel", type=Path, default=DEFAULT_KERNEL, help="Guest Linux ARM64 Image path")
    ap.add_argument("--sync-colocate", action="store_true", help="Enable SYNC_COLOCATE on tuned VZ and HVF arms")
    ap.add_argument("--cc", choices=["cubic", "bbr"], default=None, help="Set guest TCP congestion control via micropod.ci_cc")
    ap.add_argument("--idle-poll-us", type=int, default=0, help="Bounded guest idle poll window in microseconds (7.3.5-micropod-b5+)")
    ap.add_argument("--driver", default="bridge", choices=["bridge", "ipvlan"])
    ap.add_argument("--sibling-cc-ab", action="store_true", help="add an interleaved BBR/CUBIC comparison within the HVF worker")
    ap.add_argument("--label", default="track-a1")
    args = ap.parse_args()
    if args.sibling_cc_ab and (not args.include_hvf or not args.rebuild_runner or args.rounds < 1):
        ap.error("--sibling-cc-ab requires --include-hvf, --rebuild-runner and at least one round")

    shared_drive = BenchmarkWorkerDrive(Path(tempfile.mkdtemp(prefix="mp-tune-work-", dir="/private/tmp")))
    work = shared_drive.home / "fixture"
    orb_probe_dir = Path(tempfile.mkdtemp(prefix="mp-orb-probes-", dir="/private/tmp"))
    retain_workspace = False
    try:
        shared_drive.attach()
        shared_drive.receipts["live"] = shared_drive.apfs.verify(shared_drive.receipts["created"])
        work.mkdir(mode=0o700)
        # 1. Build Linux netbench & Mac offered client once
        env_linux = dict(os.environ)
        env_linux.pop("GOROOT", None)
        env_linux.update({"GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0"})
        netbench_linux = work / "netbench-linux"
        subprocess.run(
            ["go", "build", "-trimpath", "-o", str(netbench_linux), str(ROOT / "scripts/netbench/main.go")],
            env=env_linux, check=True,
        )
        subprocess.run(
            ["go", "build", "-trimpath", "-o", str(work / "quiet-http"), str(ROOT / "scripts/netbench/quiet/main.go")],
            env=env_linux, check=True,
        )
        (work / "quiet-http").chmod(0o755)
        # Mirror read-only probe binaries onto the root APFS volume so OrbStack's VirtioFS can bind-mount them
        for probe in ("netbench-linux", "quiet-http"):
            shutil.copy2(work / probe, orb_probe_dir / probe)
            (orb_probe_dir / probe).chmod(0o755)
        offered_mac = work / "offered-mac"
        env_mac = dict(os.environ)
        env_mac.pop("GOROOT", None)
        subprocess.run(
            ["go", "build", "-trimpath", "-o", str(offered_mac), str(ROOT / "scripts/netbench/offered/main.go")],
            env=env_mac, check=True,
        )

        # 2. Export identical images from OrbStack once (include pause:3.10.2 for offline HVF!)
        img_tar = work / "images.tar"
        img_list = ["alpine:3.23", "micropod-qa/netbench:local"]
        if args.include_hvf:
            img_list = ["registry.k8s.io/pause:3.10.2"] + img_list
        run(["docker", "--host", f"unix://{ORB_SOCK}", "save", "-o", str(img_tar), *img_list], timeout=120)

        # 3. Stage tools bundles (control = untouched stock, candidate = updated start.sh + optional rebuilt job)
        base_tools = AUTH_PRODUCT_DIR / "micropod-oci-tools"
        if not base_tools.exists():
            base_tools = DEFAULT_PRODUCT_DIR / "micropod-oci-tools"
        ctrl_tools = work / "tools-control"
        shutil.copytree(base_tools, ctrl_tools, symlinks=True)
        cand_tools = work / "tools-candidate"
        stage_oci_tools(base_tools, cand_tools, rebuild_runner=args.rebuild_runner)

        mp_bin = (AUTH_PRODUCT_DIR / "micropod") if args.use_auth_binary else (DEFAULT_PRODUCT_DIR / "micropod")

        ctrl_kargs = "micropod.ci_sched=hrtick-250us micropod.ci_wakeup=next-buddy"
        cand_wakeup = "next-buddy,sync-colocate" if args.sync_colocate else "next-buddy"
        cc_arg = f" micropod.ci_cc={args.cc}" if args.cc else ""
        poll_arg = f" idle_poll_us={args.idle_poll_us}" if args.idle_poll_us > 0 else ""
        cand_kargs = (
            f"micropod.ci_sched=hrtick-250us micropod.ci_wakeup={cand_wakeup} "
            "cgroup.memory=nokmem,nosocket slab_min_order=2 swiotlb=noforce "
            f"workqueue.power_efficient=1 micropod.ci_sysctls=perf{cc_arg}{poll_arg}"
        )

        results = {
            "label": args.label,
            "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "driver": args.driver,
            "rounds": args.rounds,
            "rebuild_runner": args.rebuild_runner,
            "micropod_bin": str(mp_bin),
            "kernel": str(args.kernel),
            "sync_colocate": args.sync_colocate,
            "cc": args.cc,
            "idle_poll_us": args.idle_poll_us,
            "arms": {},
        }

        arms = [("orbstack", ("orb", None, None))]
        if not args.skip_control:
            arms.append(("micropod-control", ("vz", ctrl_tools, ctrl_kargs)))
        arms.append(("micropod-vz-tuned", ("vz", cand_tools, cand_kargs)))
        if args.include_hvf:
            arms.append(("micropod-hvf", ("hvf", cand_tools, None)))

        for name, (kind, tools_dir, kargs) in arms:
            print(f"=== Running arm: {name} ===", flush=True)
            worker = None
            try:
                if kind == "orb":
                    sock = ORB_SOCK
                    boot_s = None
                elif kind == "vz":
                    worker = WorkerHandle(name, mp_bin, tools_dir, args.kernel, kargs, work)
                    boot_s = worker.start()
                    print(f"  booted {name} in {boot_s:.3f}s", flush=True)
                    load_images(worker.sock, img_tar)
                    sock = worker.sock
                else:
                    worker = HVFWorkerHandle(
                        name, DEFAULT_HVF_BIN, DEFAULT_HVF_INITRD, tools_dir,
                        args.kernel, work, mtu=args.hvf_mtu, wakeup=cand_wakeup, cc=args.cc,
                        idle_poll_us=args.idle_poll_us or None,
                    )
                    boot_s = worker.start()
                    print(f"  booted {name} in {boot_s:.3f}s", flush=True)
                    load_images(worker.sock, img_tar)
                    sock = worker.sock

                arm_data = {"boot_s": boot_s}
                arm_data["guest_tuning"] = inspect_guest_tuning(sock)
                arm_data["oom_check"] = verify_oom_kill(sock)
                print(f"  oom_check: {arm_data['oom_check']}", flush=True)

                probe_ws = orb_probe_dir if kind == "orb" else work
                arm_data["in_guest"] = bench_in_guest_suite(sock, name, probe_ws, net_driver=args.driver, rounds=args.rounds)
                print(f"  in_guest: { {k: v for k, v in arm_data['in_guest'].items() if k != 'raw'} }", flush=True)

                arm_data["churn_32x8"] = bench_ephemeral_churn(sock, name, count=32, concurrency=8, rounds=args.rounds)
                print(f"  churn_32x8: {arm_data['churn_32x8']}", flush=True)

                if kind == "hvf" and args.sibling_cc_ab:
                    arm_data["sibling_cc_ab"] = bench_sibling_congestion_pair(sock, work, args.driver, args.rounds)

                if not args.skip_published:
                    arm_data["published_tcp"] = bench_published_tcp(sock, name, offered_mac, rounds=args.rounds)
                    print(f"  published_tcp: {arm_data['published_tcp']}", flush=True)

                results["arms"][name] = arm_data
            finally:
                if worker is not None:
                    try:
                        drive = worker.stop()
                    except BaseException:
                        retain_workspace = True
                        print(f"Preserved worker workspace at {work}", file=sys.stderr)
                        raise
                    if name in results["arms"]:
                        results["arms"][name]["host_worker_drive"] = drive

    finally:
        shutil.rmtree(orb_probe_dir, ignore_errors=True)
        if not retain_workspace:
            workspace_receipt = shared_drive.close()
    results["workspace_drive"] = workspace_receipt
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(results, indent=2) + "\n")
    print(f"\nSaved receipt to {args.out}", flush=True)


if __name__ == "__main__":
    main()
