"""Paired ext4 fsync batching experiment for an owned, disposable Apple qualification VM."""
from concurrent.futures import ThreadPoolExecutor
import os
import statistics
import time

from bench_live_kernel import fingerprint
from bench_package_caches import Fixture
from guest_cache_workload import measure_packages


def profile_ext4(cli, docker, alpine, image, scope, lock, home, worker, clients, rounds):
    shell = """cd "$(mktemp -d)"
printf '%s' "$1" > go.mod
printf '%s' "$2" > go.sum
printf '%s' "$3" > main.go
export GOENV=off GOPROXY=off GOSUMDB=off CGO_ENABLED=0 GOMAXPROCS=2 GOWORK=off
export GOTOOLCHAIN=local GOTELEMETRY=off GOFLAGS="-trimpath -p=2"
go build -x -trimpath -buildvcs=false -o app . 2>log
if grep -E '^[^ ]*/(compile|asm|link) ' log | grep -v ' -V'; then exit 8; fi
./app
"""
    source = Fixture(home, lock).workspace("ext4-source")
    files = [(source / filename).read_text() for filename in ("go.mod", "go.sum", "main.go")]
    options = docker("run", "--rm", "--network", "none", alpine, "cat", "/proc/fs/ext4/vdb/options").stdout.splitlines()
    original = int(next(s for s in options if s.startswith("max_batch_time=")).split("=")[1])
    if "barrier" not in options or "data=ordered" not in options:
        raise ValueError("The trial requires the disposable worker's journaled ext4 disk")
    record = dict(worker=worker, clients=clients, rounds=rounds, original=options, pairs=[], package_pairs=[])

    def select(value):
        script = """p=$(pidof dockerd)
nsenter -t "$p" -m -r -- /bin/mount -o "remount,max_batch_time=$1" /dev/vdb /
grep -qx "max_batch_time=$1" /proc/fs/ext4/vdb/options
grep -qx barrier /proc/fs/ext4/vdb/options
grep -qx data=ordered /proc/fs/ext4/vdb/options
"""
        docker("run", "--rm", "--network", "none", "--privileged", "--pid=host",
               alpine, "sh", "-ec", script, "sh", str(value))

    def diskstats():
        row = docker("run", "--rm", "--network", "none", alpine, "cat", "/sys/block/vdb/stat").stdout
        return list(map(int, row.split()))

    def run(kind):
        limits = ["--network", "none", "--pull=never", "--cpus", "1"]
        if kind == "go":
            actual = cli("run", "--cache", "go", "--cache-scope", scope, *limits, "--memory", "1g",
                         image, "sh", "-ec", shell, "sh", *files).stdout.strip()
            if actual != "micropod-cache-ok":
                raise ValueError("The offline Go product did not match")
        else:
            boot = cli("run", *limits, "--memory", "256m", alpine, "cat", "/proc/sys/kernel/random/boot_id").stdout
            if boot.strip().lower() != worker["boot"].lower():
                raise ValueError("The worker rebooted during the mount experiment")

    def run_packages(block, value):
        def command(argv, check=True):
            if argv[:2] == ["run", "--rm"]:
                return cli("run", *argv[2:], check=check)
            return docker(*argv, check=check)

        receipt = {}
        measure_packages(command, image, "arm64", fingerprint(worker["boot"]), fingerprint,
                         [clients], 1, receipt)
        record["package_pairs"].append(dict(round=block+1, max_batch_us=value, receipt=receipt))

    run("go")
    try:
        for block in range(rounds):
            for value in ((15000, 0) if block % 2 == 0 else (0, 15000)):
                select(value)
                if block % 2:
                    run_packages(block, value)
                for kind in (("go", "launch") if block % 2 == 0 else ("launch", "go")):
                    first = diskstats()
                    start = time.perf_counter()
                    with ThreadPoolExecutor(max_workers=clients) as pool:
                        list(pool.map(lambda _: run(kind), range(clients)))
                    seconds = time.perf_counter() - start
                    last = diskstats()
                    record["pairs"].append(dict(round=block+1, max_batch_us=value, workload=kind,
                        seconds=seconds, sectors_written=last[6]-first[6], flushes=last[15]-first[15], load=os.getloadavg()))
                if block % 2 == 0:
                    run_packages(block, value)
    finally:
        select(original)
    record["median_s"] = {}
    record["package_median_s"] = {}
    for value in (15000, 0):
        direct = [p for p in record["pairs"] if p["max_batch_us"] == value]
        packages = [p["receipt"]["median_seconds"] for p in record["package_pairs"] if p["max_batch_us"] == value]
        record["median_s"][str(value)] = {kind: statistics.median(p["seconds"] for p in direct if p["workload"] == kind)
                                         for kind in ("go", "launch")}
        record["package_median_s"][str(value)] = {tool: statistics.median(p[tool][str(clients)] for p in packages)
                                                 for tool in ("go", "npm")}
    return record
