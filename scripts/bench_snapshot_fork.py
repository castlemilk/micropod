#!/usr/bin/env python3
"""Measure cold boot, snapshot save and independently writable APFS-backed HVF forks."""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import signal
import socket
import stat
import statistics
import subprocess
import tempfile
from threading import Lock
import time
from uuid import uuid4

import bench_engine_tuning as bet


ROOT = Path(__file__).resolve().parents[1]
B5_KERNEL = ROOT / ".build/local-kernel-pages/20261125-b5-16k/full-16k/Image"
IMAGE = "alpine:3.23"
CPUS = 4
MEMORY_MIB = 4096
MIB = 1 << 20
SHARE_FILE = "host-marker"
GUEST_FILE = "guest-marker"
VOLUME_PATH = "/state/marker"
IMAGE_SEEDS = ("registry.k8s.io/pause:3.10.2", IMAGE)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def ms_since(start):
    return round((time.perf_counter() - start) * 1000, 2)


def digest(path):
    with path.open("rb") as file:
        return {"path": str(path), "sha256": hashlib.file_digest(file, "sha256").hexdigest()}


def tail(path, max_bytes=3600):
    try:
        with path.open("rb") as file:
            end = file.seek(0, os.SEEK_END)
            file.seek(max(0, end - max_bytes))
            return file.read(max_bytes).decode(errors="replace")
    except OSError as error:
        return f"log unavailable: {error}"


def ping(socket_path, timeout):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(str(socket_path))
        connection.sendall(b"GET /_ping HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        with http.client.HTTPResponse(connection) as response:
            response.begin()
            return response.status == 200 and response.read(3) == b"OK"


@dataclass
class Process:
    name: str
    proc: subprocess.Popen
    log: Path
    started: float
    retirement: dict | None = None


def exit_signal(returncode):
    if returncode is None or returncode >= 0:
        return None
    try:
        return signal.Signals(-returncode).name
    except ValueError:
        return f"signal {-returncode}"


class OwnedProcesses:
    def __init__(self, logs):
        self.logs = logs
        self.items = {}
        self.lock = Lock()

    def launch(self, name, argv):
        with self.lock, (self.logs / f"{name}.log").open("xb", buffering=0) as stream:
            require(name not in self.items, f"duplicate VMM process name {name}")
            started = time.perf_counter()
            proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=stream,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            record = Process(name, proc, Path(stream.name), started)
            self.items[name] = record
            return record

    def retire(self, record):
        if record.retirement is not None:
            return record.retirement
        proc = record.proc
        signals = []
        started = time.perf_counter()
        if proc.poll() is None:
            try:
                require(os.getpgid(proc.pid) == proc.pid, f"{record.name} lost its own process group")
                os.killpg(proc.pid, signal.SIGTERM)
                signals.append("SIGTERM")
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                    signals.append("SIGKILL")
                except ProcessLookupError:
                    pass
                proc.wait(timeout=5)
        try:
            os.killpg(proc.pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise RuntimeError(f"{record.name} still has a process group")
        record.retirement = {
            "name": record.name, "pid": proc.pid, "exit_code": proc.returncode, "signals": signals,
            "exit_signal": exit_signal(proc.returncode),
            "clean_exit": proc.returncode == 0 and "SIGKILL" not in signals,
            "process_group_absent": True, "retirement_ms": ms_since(started), "log_tail": tail(record.log),
        }
        return record.retirement

    def close(self):
        results, errors = [], []
        for record in self.items.values():
            try:
                results.append(self.retire(record))
            except Exception as error:
                errors.append({"name": record.name, "pid": record.proc.pid, "error": str(error),
                               "log_tail": tail(record.log)})
        return results, errors


def wait_docker_ping(target, process, timeout_s=20):
    deadline = process.started + timeout_s
    while (remaining := deadline - time.perf_counter()) > 0:
        if process.proc.poll() is not None:
            raise RuntimeError(f"{process.name} exited before Docker was ready: {tail(process.log)}")
        if target.is_socket():
            try:
                if ping(target, min(0.25, remaining)) and process.proc.poll() is None:
                    return ms_since(process.started)
            except (OSError, http.client.HTTPException):
                pass
        time.sleep(0.001)
    raise TimeoutError(f"{process.name} timed out waiting for Docker /_ping on {target}: {tail(process.log)}")


@dataclass(frozen=True)
class Instance:
    name: str
    state: Path
    disk: Path
    share: Path
    host_marker: str

    @property
    def sock(self):
        return self.state / "docker.sock"

    @property
    def oci(self):
        return self.state / "oci.sock"


def file_record(path, device, minimum=1):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_dev == device and info.st_uid == os.getuid()
            and info.st_nlink == 1 and info.st_size >= minimum,
            f"unexpected file on the protected APFS volume: {path}")
    return {"path": str(path), "device": info.st_dev, "inode": info.st_ino, "bytes": info.st_size,
            "allocated": info.st_blocks * 512}


def snapshot_metrics(snapshot, device, source_disk, wall_ms, captured_ns):
    paths = {name: snapshot / name for name in ("disk.ext4", "vmstate.bin", "ram.bin", "READY")}
    files = {name: file_record(path, device) for name, path in paths.items()}
    meta = json.loads(paths["READY"].read_bytes())
    require(meta["num_vcpus"] == CPUS and meta["memory_mib"] == MEMORY_MIB
            and meta["ram_total_bytes"] == files["ram.bin"]["bytes"] == MEMORY_MIB * MIB
            and 0 < meta["ram_written_bytes"] <= meta["ram_total_bytes"]
            and math.isfinite(meta["snapshot_ms"]) and meta["snapshot_ms"] > 0
            and files["disk.ext4"]["bytes"] == source_disk["bytes"]
            and files["disk.ext4"]["inode"] != source_disk["inode"], "invalid snapshot READY or storage files")
    return {
        "wall_ms": wall_ms, "vmm_internal_ms": meta["snapshot_ms"],
        "ram_written_mib": round(meta["ram_written_bytes"] / MIB, 1),
        "ram_total_mib": round(meta["ram_total_bytes"] / MIB, 1),
        "vmstate_kib": round(files["vmstate.bin"]["bytes"] / 1024, 1),
        "capture_started_unix_ns": captured_ns, "files": files,
    }


def clock_evidence(before, after, guest_seconds, captured, pause):
    require(after >= before, "host wall clock stepped backward during the guest clock probe")
    lo, hi = guest_seconds * 10**9, (guest_seconds + 1) * 10**9
    difference = max(before - hi, lo - after, 0)
    return {
        "requested_pause_s": pause, "host_before_unix_ns": before, "host_after_unix_ns": after,
        "guest_unix_s": guest_seconds, "guest_advanced_since_snapshot_s": (lo - captured) / 1e9,
        "outside_host_interval_s": difference / 1e9, "guest_resolution_s": 1,
        "within_1_5_s": difference <= 1_500_000_000,
    }


class SnapshotRun:
    def __init__(self, args, report):
        self.args = args
        self.report = report
        self.drive = None
        self.processes = None
        self.vz = None
        self.token = uuid4().hex[:16]
        self.volume = "snapshot-proof-" + self.token

    def prepare(self):
        self.drive = bet.BenchmarkWorkerDrive(Path(tempfile.mkdtemp(prefix="mp-sf-", dir="/private/tmp")))
        self.report["drive"] = self.drive.receipts
        self.drive.attach()
        self.device = self.drive.receipts["created"]["volume"]["dev"]
        self.state = self.drive.home / "state"
        self.shares = self.drive.home / "shares"
        self.state.mkdir(mode=0o700)
        self.shares.mkdir(mode=0o700)
        log_dir = self.state / "logs"
        log_dir.mkdir(mode=0o700)
        self.processes = OwnedProcesses(log_dir)
        self.report["storage_scope"] = {
            "private_apfs_device": self.device, "state": str(self.state), "share_parent": str(self.shares),
            "base_disk": str(self.drive.disk),
        }
        for path in (self.state, self.shares):
            require(path.stat().st_dev == self.device, f"{path} is not on the protected APFS volume")
        self.snapshot = self.state / "snapshot"
        self.trigger = self.state / "take-snapshot"
        self.seed = self.args.image_tar
        if self.seed is None:
            self.seed = self.state / "images.tar"
            bet.run(["docker", "--host", f"unix://{self.args.orbstack_socket}", "save", "-o", str(self.seed),
                     *IMAGE_SEEDS], timeout=120)
        self.report["artifacts"]["seed_images"] = digest(self.seed)
        seed = bet.copy_hvf_seed(self.args.seed_disk, self.drive.disk, self.device)
        self.drive.receipts["rootfs_seed"] = seed
        self.drive.verify_live(seed["bytes"])
        self.source = self.instance("source", self.drive.disk)
        self.serial = [self.instance(str(100 + i)) for i in range(self.args.serial_rounds)]
        self.parallel = [self.instance(str(200 + i)) for i in range(self.args.parallel_forks)]
        self.delayed = self.instance("fresh")
        self.disk_inodes = {self.drive.receipts["raw_disk"]["inode"]}

    def instance(self, name, disk=None):
        state = self.state / name
        share = self.shares / name
        state.mkdir(mode=0o700)
        share.mkdir(mode=0o700)
        marker = f"{self.token}-{name}-host"
        (share / SHARE_FILE).write_text(marker + "\n")
        record = Instance(name, state, disk or state / "worker.ext4", share, marker)
        require(len(os.fsencode(record.sock)) < 104, f"Unix socket path is too long: {record.sock}")
        return record

    def vmm_args(self, instance):
        return [
            str(self.args.vmm), "--disk", str(instance.disk), "--published-net", "--published-mtu", "9000",
            "--share", f"oci-tools:{self.args.tools}:ro", "--share", f"workspace:{instance.share}",
            "--vsock-expose", f"{instance.sock}:2375", "--vsock-expose", f"{instance.oci}:2376",
            "--quiet", "--json-summary",
        ]

    def docker(self, instance, *args, timeout=20):
        return bet.docker(instance.sock, *args, timeout=timeout).stdout

    def probe(self, instance, *args, mounts=()):
        return self.docker(instance, "run", "--rm", "--pull=never", "--network", "none", *mounts, IMAGE, *args)

    def cold_vz(self):
        workspace = self.shares / "vz"
        workspace.mkdir(mode=0o700)
        kargs = ("micropod.ci_sched=hrtick-250us micropod.ci_wakeup=next-buddy,sync-colocate "
                 f"micropod.ci_cc=cubic idle_poll_us={self.args.idle_poll_us}")
        self.vz = bet.WorkerHandle("vz-cold", self.args.micropod, self.args.tools, self.args.kernel, kargs, workspace)
        self.report["vz_drive"] = self.vz.drive.receipts
        self.report["cold_boot"]["vz_boot_to_ready_ms"] = round(self.vz.start() * 1000.0, 1)
        self.vz.stop()
        self.vz = None

    def make_snapshot(self):
        workspace = self.source.share
        cmdline = (
            "quiet console=ttyAMA0 rcupdate.rcu_expedited=1 psi=1 "
            "cgroup.memory=nokmem,nosocket slab_min_order=2 swiotlb=noforce workqueue.power_efficient=1 "
            "micropod.ci_sched=hrtick-250us micropod.ci_wakeup=next-buddy,sync-colocate "
            "micropod.ci_sysctls=perf micropod.ci_cc=cubic "
            f"idle_poll_us={self.args.idle_poll_us} mp.mtu=9000 mp.workspace={workspace} panic=-1"
        )
        source = self.processes.launch(self.source.name, [
            *self.vmm_args(self.source), "--kernel", str(self.args.kernel), "--initrd", str(self.args.initrd),
            "--cpus", str(CPUS), "--memory-mib", str(MEMORY_MIB), "--cmdline", cmdline,
            "--snapshot-trigger", str(self.trigger), "--snapshot-out", str(self.snapshot), "--snapshot-and-exit",
        ])
        self.report["cold_boot"]["hvf_boot_to_docker_ping_ms"] = wait_docker_ping(self.source.sock, source)
        bet.load_images(self.source.sock, self.seed)
        require(self.docker(self.source, "volume", "create", self.volume).strip() == self.volume,
                "source did not create its owned snapshot volume")
        self.base_marker = self.token + "-original"
        volume_mount, host_mount = self.mounts(read_only=True)
        expected = self.base_marker + "\n" + self.source.host_marker + "\n"
        observed = self.probe(self.source, "sh", "-ec",
                              'printf "%s\\n" "$1" >/state/marker; sync; cat /state/marker /workspace/host-marker',
                              "probe", self.base_marker, mounts=(*volume_mount, *host_mount))
        require(observed == expected, "source baseline volume or workspace marker did not match")
        time.sleep(0.15)
        captured_ns, start = time.time_ns(), time.perf_counter()
        self.trigger.write_text("go\n")
        source.proc.wait(timeout=35)
        wall_ms = ms_since(start)
        log = tail(source.log)
        require(source.proc.returncode == 0, f"snapshot source exited {source.proc.returncode}: {log}")
        summaries = [json.loads(line) for line in log.splitlines() if line.startswith("{") and line.endswith("}")]
        require(summaries and summaries[-1].get("exit_reason") == "snapshot_done", f"VMM did not confirm snapshot: {log}")
        self.processes.retire(source)
        self.report["snapshot_save"] = snapshot_metrics(
            self.snapshot, self.device, self.drive.receipts["raw_disk"], wall_ms, captured_ns,
        )
        self.disk_inodes.add(self.report["snapshot_save"]["files"]["disk.ext4"]["inode"])

    def mounts(self, *, read_only):
        # The mounted guest path from the memory snapshot stays fixed. Only the
        # path passed for the host's workspace share changes on each restore.
        suffix = ",readonly" if read_only else ""
        return (
            ("--mount", f"type=volume,src={self.volume},dst=/state"),
            ("--mount", f"type=bind,src={self.source.share},dst=/workspace{suffix}"),
        )

    def restore(self, instance):
        require(not os.path.lexists(instance.disk), f"restore target already exists: {instance.disk}")
        process = self.processes.launch(instance.name, [*self.vmm_args(instance), "--restore-from", str(self.snapshot)])
        ping_ms = wait_docker_ping(instance.sock, process)
        return process, ping_ms

    def fork_timer(self, instance):
        process, ping_ms = self.restore(instance)
        marker = f"FORK_{instance.name}_OK"
        output = self.docker(instance, "run", "--rm", "--pull=never", IMAGE,
                             "sh", "-ec", 'printf "%s\\n" "$1"; uname -r', "probe", marker)
        first_ms = ms_since(process.started)
        rows = output.splitlines()
        require(len(rows) == 2 and rows[0] == marker and rows[1], f"{instance.name} first container failed: {output!r}")
        return process, {
            "fork": int(instance.name), "restore_to_docker_ping_ms": ping_ms,
            "restore_to_first_container_ms": first_ms, "kernel_release": rows[1],
        }

    def assess_disk(self, instance):
        disk = file_record(instance.disk, self.device)
        require(disk["inode"] not in self.disk_inodes, f"{instance.name} reused another writable disk inode")
        require(disk["bytes"] == self.report["snapshot_save"]["files"]["disk.ext4"]["bytes"],
                f"{instance.name} clone differs in logical size from the snapshot")
        self.disk_inodes.add(disk["inode"])
        return disk

    def assess_fork(self, instance, process, record):
        rss = int(bet.run(["ps", "-o", "rss=", "-p", str(process.proc.pid)], timeout=5).stdout.strip())
        record.update(host_rss_mib=round(rss / 1024, 2), disk=self.assess_disk(instance))

    def serial_forks(self):
        data = self.report["serial_fork"] = {"rounds": self.args.serial_rounds, "samples": []}
        for instance in self.serial:
            process, record = self.fork_timer(instance)
            data["samples"].append(record)
            self.assess_fork(instance, process, record)
            self.processes.retire(process)
        data.update(fork_medians(data["samples"]))
        pings = [s["restore_to_docker_ping_ms"] for s in data["samples"]]
        data.update(restore_to_docker_ping_ms_min=min(pings), restore_to_docker_ping_ms_max=max(pings))

    def parallel_forks(self):
        data = self.report["parallel_fanout"] = {"forks": self.args.parallel_forks, "samples": []}
        launch, failure = {}, []
        start = time.perf_counter()
        with ThreadPoolExecutor(max_workers=len(self.parallel)) as pool:
            futures = {pool.submit(self.fork_timer, instance): instance for instance in self.parallel}
            for future in as_completed(futures):
                instance = futures[future]
                try:
                    launch[instance.name] = future.result()
                except Exception as error:
                    failure.append({"fork": instance.name, "error": str(error)})
        data["all_forks_ready_and_ran_container_wall_ms"] = None if failure else ms_since(start)
        if failure:
            data["failure"] = failure
        for instance in self.parallel:
            if instance.name in launch:
                process, record = launch[instance.name]
                data["samples"].append(record)
                self.assess_fork(instance, process, record)
        if failure:
            raise RuntimeError(f"{len(failure)} parallel fork(s) failed")
        data.update(fork_medians(data["samples"]))
        self.verify_isolation()
        data["cow_disk_isolation_verified"] = True
        for process, _ in launch.values():
            self.processes.retire(process)

    def verify_isolation(self):
        volume_mount, host_mount = self.mounts(read_only=False)
        mounts = (*volume_mount, *host_mount)
        checked = self.report["isolation"] = {"volume": self.volume, "guest_path": VOLUME_PATH, "forks": []}
        # All forks start from the same file in the same named volume. Write all
        # forks before any readback so a shared volume cannot pass one-at-a-time.
        for instance in self.parallel:
            observed = self.probe(instance, "cat", VOLUME_PATH, f"/workspace/{SHARE_FILE}", mounts=mounts)
            require(observed == self.base_marker + "\n" + instance.host_marker + "\n",
                    f"{instance.name} did not start with the snapshot bytes and its private host share")
        for instance in self.parallel:
            marker = f"{self.token}-{instance.name}-guest"
            self.probe(instance, "sh", "-ec",
                       'printf "%s\\n" "$1" >/state/marker; printf "%s\\n" "$1" >/workspace/guest-marker; sync',
                       "probe", marker, mounts=mounts)
        for instance in self.parallel:
            marker = f"{self.token}-{instance.name}-guest"
            observed = self.probe(instance, "cat", VOLUME_PATH, f"/workspace/{SHARE_FILE}", f"/workspace/{GUEST_FILE}",
                                  mounts=mounts)
            actual_host = (instance.share / GUEST_FILE).read_text()
            expected = marker + "\n" + instance.host_marker + "\n" + marker + "\n"
            require(observed == expected and actual_host == marker + "\n", f"{instance.name} write isolation mismatch")
            checked["forks"].append({"fork": int(instance.name), "volume_marker": marker,
                                    "host_share": str(instance.share), "host_marker": instance.host_marker,
                                    "host_write_marker": actual_host.strip()})
        require((self.source.share / SHARE_FILE).read_text() == self.source.host_marker + "\n"
                and not os.path.lexists(self.source.share / GUEST_FILE), "fork wrote into the source workspace")

    def fresh_restore(self):
        paused = time.perf_counter()
        time.sleep(self.args.clock_pause_s)
        observed_pause = time.perf_counter() - paused
        process, ping_ms = self.restore(self.delayed)
        readback = self.report["fresh_restore"] = {"restore_to_docker_ping_ms": ping_ms, "delay_s": observed_pause,
                                                  "disk": self.assess_disk(self.delayed)}
        volume_mount, host_mount = self.mounts(read_only=True)
        before = time.time_ns()
        evidence = self.probe(self.delayed, "sh", "-ec",
                              'date +%s; cat /state/marker /workspace/host-marker; test ! -e /workspace/guest-marker',
                              mounts=(*volume_mount, *host_mount))
        after = time.time_ns()
        seconds, volume, host = evidence.splitlines()
        readback["clock"] = clock_evidence(before, after, int(seconds),
                                           self.report["snapshot_save"]["capture_started_unix_ns"], self.args.clock_pause_s)
        require(volume == self.base_marker and host == self.delayed.host_marker,
                "fresh restore did not recover the original volume and a private workspace")
        readback.update(original_volume_verified=True, original_volume_marker=volume, host_marker=host)
        require(readback["clock"]["within_1_5_s"], "delayed restore guest realtime is outside the host UTC bracket")
        self.processes.retire(process)

    def finish(self):
        teardown = self.report["teardown"] = {"processes": [], "errors": [], "unexpected_process_exits": []}
        if self.processes is not None:
            teardown["processes"], teardown["errors"] = self.processes.close()
            teardown["unexpected_process_exits"] = [row for row in teardown["processes"] if not row["clean_exit"]]
        if unexpected := teardown["unexpected_process_exits"]:
            detail = ", ".join(f"{row['name']} exited {row['exit_signal'] or row['exit_code']} after {row['signals']}"
                               for row in unexpected)
            self.report.setdefault("failure", {"phase": "vmm_exit", "exception": "UnexpectedProcessExit", "detail": detail})
        if self.vz is not None:
            try:
                self.vz.stop()
            except Exception as error:
                teardown["errors"].append({"name": "vz", "error": str(error)})
        if self.drive is not None:
            if teardown["errors"]:
                teardown["drive_preserved"] = str(self.drive.directory)
                return
            try:
                self.drive.close()
            except Exception as error:
                teardown["drive_preserved"] = str(self.drive.directory)
                teardown["errors"].append({"name": "protected APFS drive", "error": str(error)})


def fork_medians(samples):
    keys = ("restore_to_docker_ping_ms", "restore_to_first_container_ms", "host_rss_mib")
    return {key + "_median": round(statistics.median(sample[key] for sample in samples), 2) for key in keys}


def measure(args):
    report = {
        "label": "phase-b5-snapshot-fork", "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kernel": str(args.kernel), "config": {"cpus": CPUS, "memory_mib": MEMORY_MIB, "idle_poll_us": args.idle_poll_us},
        "cold_boot": {}, "artifacts": {},
        "timing_scope": "cold and restore clocks start at VMM spawn. Parallel wall ends after all first containers. "
                        "APFS/image staging, clock checks, and isolation read/write commands are outside timed windows.",
    }
    benchmark = SnapshotRun(args, report)
    phase = "artifacts"
    try:
        for key, path in (("kernel", args.kernel), ("vmm", args.vmm), ("initrd", args.initrd),
                          ("micropod", args.micropod), ("runner", args.tools / "runner/bin/job"),
                          ("runner_start", args.tools / "runner/start.sh")):
            report["artifacts"][key] = digest(path)
        for phase, action in (("apfs_and_fixture", benchmark.prepare), ("vz_cold_boot", benchmark.cold_vz),
                              ("snapshot", benchmark.make_snapshot), ("serial_forks", benchmark.serial_forks),
                              ("parallel_forks", benchmark.parallel_forks), ("fresh_restore", benchmark.fresh_restore)):
            action()
    except (Exception, KeyboardInterrupt) as error:
        report["failure"] = {"phase": phase, "exception": type(error).__name__, "detail": str(error)}
    finally:
        benchmark.finish()
    report["complete"] = "failure" not in report and not report["teardown"]["errors"]
    return report


def interrupted(signum, _frame):
    raise InterruptedError(f"received signal {signum}")


def main():
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    product = bet.AUTH_PRODUCT_DIR if (bet.AUTH_PRODUCT_DIR / "micropod").exists() else bet.DEFAULT_PRODUCT_DIR
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--kernel", type=Path, default=B5_KERNEL)
    parser.add_argument("--vmm", type=Path, default=bet.DEFAULT_HVF_BIN)
    parser.add_argument("--initrd", type=Path, default=bet.DEFAULT_HVF_INITRD)
    parser.add_argument("--tools", type=Path, default=product / "micropod-oci-tools")
    parser.add_argument("--micropod", type=Path, default=product / "micropod")
    parser.add_argument("--seed-disk", type=Path, default=bet.DEFAULT_ALPINE_EXT4)
    parser.add_argument("--orbstack-socket", type=Path, default=bet.ORB_SOCK)
    parser.add_argument("--image-tar", type=Path, help="use an existing local archive containing Alpine and the pause image")
    parser.add_argument("--serial-rounds", type=int, default=5)
    parser.add_argument("--parallel-forks", type=int, default=5)
    parser.add_argument("--idle-poll-us", type=int, default=150)
    parser.add_argument("--clock-pause-s", type=float, default=4.0)
    args = parser.parse_args()
    if not 1 <= args.serial_rounds <= 20 or not 1 <= args.parallel_forks <= 12:
        parser.error("use 1–20 serial rounds and 1–12 parallel forks")
    if not math.isfinite(args.clock_pause_s) or not 2 <= args.clock_pause_s <= 60:
        parser.error("use a delayed restore between 2 and 60 seconds")
    for field in ("kernel", "vmm", "initrd", "tools", "micropod", "seed_disk", "orbstack_socket", "image_tar"):
        value = getattr(args, field)
        if value is not None:
            setattr(args, field, value.resolve())
    if ":" in str(args.tools):
        parser.error("the tools directory cannot contain the VMM share delimiter")
    if not args.image_tar and not args.orbstack_socket.is_socket():
        parser.error("--orbstack-socket must be a Unix socket unless --image-tar is supplied")
    for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_API_VERSION"):
        os.environ.pop(key, None)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("x") as output:
        report = measure(args)
        json.dump(report, output, indent=2)
        output.write("\n")
    print(json.dumps(report, indent=2), flush=True)
    return 0 if report["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
