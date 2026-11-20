"""Guest-side measurements for profile_ci_worker.py, executed from the pinned toolchain image."""
import time
PYTHON_ENTRY_NS = time.time_ns()

import json
import os
from pathlib import Path
import re
import select
import shlex
import sys
import tempfile
import subprocess
from contextlib import contextmanager


def go_tools(stderr):
    """Count actual command lines from go build -x, including environment-prefixed link commands."""
    counts = dict(compile=0, asm=0, link=0)
    for line in stderr.splitlines():
        if not re.search(r"/(?:compile|asm|link)['\"]?[ \t]", line):
            continue
        try:
            argv = shlex.split(line)
        except ValueError:
            continue  # A diagnostic containing a tool path may contain unmatched quotes.
        while argv and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", argv[0]):
            argv.pop(0)
        if len(argv) < 2 or not argv[0].startswith("/") or argv[1].split("=")[0] == "-V":
            continue
        tool = os.path.basename(argv[0])
        if tool in counts:
            counts[tool] += 1
    return counts


def fields(path):
    return {line.split()[0].rstrip(":"): int(line.split()[1])
            for line in Path(path).read_text().splitlines() if len(line.split()) >= 2}


def kernel():
    stat = Path("/proc/stat").read_text().splitlines()
    vm = fields("/proc/vmstat")
    mem = fields("/proc/meminfo")
    result = {"uptime": time.monotonic(), "cpu_ticks": list(map(int, stat[0].split()[1:9])),
              "context_switches": int(next(s for s in stat if s.startswith("ctxt ")).split()[1]),
              "forks": int(next(s for s in stat if s.startswith("processes ")).split()[1]),
              "vm": {k: vm[k] for k in ("pgfault", "pgmajfault", "pgpgin", "pgpgout", "workingset_refault_file")},
              "memory_kib": {k: mem[k] for k in ("MemAvailable", "Cached", "Dirty", "Writeback")},
              "pressure_us": {}, "disk": {}}
    for name in ("cpu", "io", "memory"):
        path = Path("/proc/pressure") / name
        if path.exists():
            result["pressure_us"][name] = {line.split()[0]: int(line.split("total=")[1])
                                            for line in path.read_text().splitlines()}
    for line in Path("/proc/diskstats").read_text().splitlines():
        words = line.split()
        if Path("/sys/block", words[2], "device").exists():
            result["disk"][words[2]] = dict(zip(("read_sectors", "write_sectors", "busy_ms", "flushes"),
                (int(words[5]), int(words[9]), int(words[12]), int(words[18]) if len(words) >= 20 else 0)))
    return result


@contextmanager
def trace_instance(enabled):
    """Only this instance's buffers and events are changed. Raw event payloads stay in Linux."""
    if not enabled:
        yield None
        return
    subprocess.run(["mount", "-t", "tracefs", "tracefs", "/trace"], check=True)
    instance = Path("/trace/instances", "micropod-" + os.environ["HOSTNAME"])
    instance.mkdir()
    try:
        (instance / "tracing_on").write_text("0")
        (instance / "buffer_size_kb").write_text("256")
        counters = {}
        for group, name in (("ext4", "ext4_sync_file_enter"), ("syscalls", "sys_enter_mount"),
                            ("syscalls", "sys_enter_umount"), ("syscalls", "sys_enter_open_tree"),
                            ("syscalls", "sys_enter_move_mount"), ("sched", "sched_process_exec"),
                            ("sched", "sched_process_fork"), ("block", "block_rq_issue")):
            flag = instance / "events" / group / name / "enable"
            if flag.exists():
                flag.write_text("1")
                counters[name] = 0
        if not counters:
            raise ValueError("Kernel provides none of the requested tracepoints")
        fd = os.open(instance / "trace_pipe", os.O_RDONLY | os.O_NONBLOCK)
        try:
            partial = b""
            def read_counts():
                nonlocal partial
                for _ in range(16):
                    try:
                        chunk = os.read(fd, 65536)
                    except BlockingIOError:
                        break
                    if not chunk:
                        break
                    lines = (partial + chunk).split(b"\n")
                    partial = lines.pop()
                    for name in re.findall(rb": (\w+): ", b"\n".join(lines)):
                        event = name.decode()
                        if event in counters:
                            counters[event] += 1
                overruns = 0
                for stat in instance.glob("per_cpu/cpu*/stats"):
                    fields = dict(line.split(":", 1) for line in stat.read_text().splitlines() if ":" in line)
                    overruns += int(fields.get("overrun", 0)) + int(fields.get("dropped events", 0))
                return {**counters, "lost_events": overruns}
            (instance / "tracing_on").write_text("1")
            yield read_counts
        finally:
            (instance / "tracing_on").write_text("0")
            os.close(fd)
    finally:
        instance.rmdir()


def job(op, fixture_source, lock, count):
    if op == "bytecode-audit":
        root = Path(os.environ["PYTHONPYCACHEPREFIX"])
        stats = sorted((str(p.relative_to(root)), p.stat().st_ino, p.stat().st_size) for p in root.rglob("*.pyc"))
        return {"boot": Path("/proc/sys/kernel/random/boot_id").read_text().strip(), "bytecode": stats}
    ns = {"__name__": "fixture"}
    exec(compile(fixture_source, "bench_package_caches.py", "exec"), ns)
    cache = {k: Path(os.environ[v]) for k, v in
             (("npm-cache", "npm_config_cache"), ("go-mod-cache", "GOMODCACHE"), ("go-build-cache", "GOCACHE"))}
    row = {"boot": Path("/proc/sys/kernel/random/boot_id").read_text().strip()}
    with tempfile.TemporaryDirectory(prefix="checkout-") as tmp:
        fixture = ns["Fixture"](Path(tmp), lock)
        if op == "seed":
            options = Path("/proc/fs/ext4/vdb/options")
            if options.is_file():
                row["ext4_options"] = options.read_text().splitlines()
            row["cold"] = fixture.prime(cache, "seed")
            row["lock"] = dict(npm_integrity=fixture.sri, go_sum=fixture.go_sum.decode(), go_zip_sha256=fixture.zip_digest)
        if op in ("seed", "audit"):
            row.update(inodes=[p.stat().st_ino for p in fixture.payloads(cache)], sizes=ns["snapshot"](cache))
        else:
            start = time.perf_counter()
            work = [fixture.workspace(str(i)) for i in range(count)]
            env = fixture.environment(cache)
            setup = time.perf_counter()
            row["build_start_ns"] = time.time_ns()
            cpu_before = fields("/sys/fs/cgroup/cpu.stat")
            def build(path):
                proc, elapsed = ns["command"](fixture.argv("go"), path, env)
                tools = go_tools(proc.stderr)
                compiler = tools["compile"] + tools["asm"]
                links = tools["link"]
                if compiler:
                    raise ValueError("Warm offline job invoked the Go compiler")
                return {"seconds": elapsed, "compiler": compiler, "linker": links}
            with ns["ThreadPoolExecutor"](max_workers=count) as pool:
                products = list(pool.map(build, work))
            built = time.perf_counter()
            row["build_finish_ns"] = time.time_ns()
            cpu_after = fields("/sys/fs/cgroup/cpu.stat")
            for path in work:
                fixture.verify_output("go", path, env)
            verified = time.perf_counter()
            row.update(workspace_s=setup-start, build_s=built-setup, verify_s=verified-built, products=products,
                       cpu_stat={k: v-cpu_before[k] for k, v in cpu_after.items()},
                       product_bytes=(work[0]/"app").stat().st_size)
    if op not in ("seed", "audit"):
        row["cleanup_s"] = time.perf_counter()-verified
    row.update(python_entry_ns=PYTHON_ENTRY_NS, job_finish_ns=time.time_ns())
    return row


if __name__ == "__main__":
    if sys.argv[1] == "monitor":
        # The host timestamps each line. Closing stdin ends the monitor and its Docker client.
        with trace_instance("--kernel-trace" in sys.argv) as counters:
            while True:
                sample = kernel()
                if counters:
                    sample["tracepoints"] = counters()
                print(json.dumps(sample), flush=True)
                if select.select([sys.stdin], [], [], 0.1)[0]:
                    break
    else:
        print(json.dumps(job(sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), int(sys.argv[4]))))
