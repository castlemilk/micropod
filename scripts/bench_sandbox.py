#!/usr/bin/env python3
"""bench_sandbox.py — CI-shaped VM benchmark.

  micropod sandbox   one in-process VZ micro-VM per run (clonefile rootfs, tmpfs /tmp)
  container run      Apple container: apiserver + per-container VM
  shuru              VZ microVM sandbox (optional: SHURU=/path/to/shuru or on PATH)

Rows: boot → `true` → teardown; `go vet && go test` on ci/samples/go-app with a
cold GOCACHE and a shared pre-warmed module cache; N concurrent jobs (matrix
fan-out). Every runtime gets 2 vCPU / 2 GiB.

Usage: scripts/bench_sandbox.py      (N_BOOT=10 N_JOB=5 PAR=4 to tune)
Needs `task cli` first (the CLI must carry the virtualization entitlement).
"""
import concurrent.futures as cf
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MICROPOD = os.environ.get("MICROPOD", f"{ROOT}/.build/debug/micropod")
SHURU = os.environ.get("SHURU") or shutil.which("shuru")
N_BOOT = int(os.environ.get("N_BOOT", 10))
N_JOB = int(os.environ.get("N_JOB", 5))
PAR = int(os.environ.get("PAR", 4))

GO_JOB = ("export GOMODCACHE=/gomod GOFLAGS=-modcacherw GOCACHE=/tmp/gocache GOTOOLCHAIN=local; "
          "cp -r /src /tmp/w && cd /tmp/w && go vet ./... && go test -count=1 ./...")


def sandbox(args, image="alpine:3.20", mounts=()):
    cmd = [MICROPOD, "sandbox", "run", "-c", "2", "-m", "2048"]
    for m in mounts:
        cmd += ["-v", m]
    return cmd + [image, "--"] + args


def apple(args, image="alpine:3.20", mounts=()):
    cmd = ["container", "run", "--rm", "-c", "2", "-m", "2G"]
    for m in mounts:
        cmd += ["-v", m]
    return cmd + [image] + args


def shuru(args, frm=None, mounts=()):
    cmd = [SHURU, "run", "--cpus", "2", "--memory", "2048"]
    if frm:
        cmd += ["--from", frm, "--disk-size", "8192"]
    for m in mounts:
        cmd += ["--mount", m]
    return cmd + ["--"] + args


def timed(cmd, retried=False):
    t = time.perf_counter()
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    dt = time.perf_counter() - t
    if r.returncode != 0 and not retried:
        return timed(cmd, retried=True)
    if r.returncode != 0:
        sys.exit(f"FAILED ({r.returncode}): {' '.join(cmd)}\n{r.stdout[-2000:]}")
    return dt


def row(name, xs):
    xs = sorted(xs)
    print(f"  {name:<34} p50 {statistics.median(xs):6.2f}s  min {xs[0]:6.2f}s  "
          f"max {xs[-1]:6.2f}s  (n={len(xs)})", flush=True)


def series(name, cmd, n):
    timed(cmd)  # warm-up: first-run unpack / page cache, not counted
    row(name, [timed(cmd) for _ in range(n)])


def fanout(name, cmd, k):
    timed(cmd)
    walls = []
    for _ in range(3):
        t = time.perf_counter()
        with cf.ThreadPoolExecutor(k) as ex:
            list(ex.map(lambda _: timed(cmd), range(k)))
        walls.append(time.perf_counter() - t)
    row(name, walls)


def main():
    # shuru only mounts paths under CWD — stage the sample + module cache there.
    work = tempfile.mkdtemp(prefix="bench-sandbox-")
    os.chdir(work)
    shutil.copytree(f"{ROOT}/ci/samples/go-app", "go-app")
    os.mkdir("gomod")
    mods = [f"{work}/go-app:/src", f"{work}/gomod:/gomod"]
    print(f"workdir {work}")
    subprocess.run([MICROPOD, "sandbox", "run", "--net", "-v", mods[0], "-v", mods[1],
                    "-e", "GOMODCACHE=/gomod", "-e", "GOFLAGS=-modcacherw", "-w", "/src",
                    "golang:1", "--", "go", "mod", "download"], check=True)
    if SHURU and subprocess.run([SHURU, "checkpoint", "list"], capture_output=True,
                                text=True).stdout.find("go127") < 0:
        subprocess.run([SHURU, "checkpoint", "create", "go127", "--allow-net", "--disk-size", "8192",
                        "--", "sh", "-c",
                        "curl -fsSL https://go.dev/dl/go1.27.1.linux-arm64.tar.gz | tar -C /usr/local -xz"
                        " && ln -sf /usr/local/go/bin/go /usr/local/bin/go"], check=True)

    print(f"\n== boot → `true` → teardown (n={N_BOOT}) ==")
    series("micropod sandbox", sandbox(["true"]), N_BOOT)
    series("container run", apple(["true"]), N_BOOT)
    if SHURU:
        series("shuru", shuru(["true"]), N_BOOT)

    job = ["sh", "-c", GO_JOB]
    print(f"\n== go vet + go test, cold GOCACHE (n={N_JOB}) ==")
    series("micropod sandbox golang:1", sandbox(job, "golang:1", mods), N_JOB)
    series("container run golang:1", apple(job, "golang:1", mods), N_JOB)
    if SHURU:
        series("shuru go127", shuru(job, "go127", mods), N_JOB)

    print(f"\n== fan-out: {PAR} concurrent go jobs, wall (3 rounds) ==")
    fanout(f"micropod sandbox x{PAR}", sandbox(job, "golang:1", mods), PAR)
    fanout(f"container run x{PAR}", apple(job, "golang:1", mods), PAR)
    if SHURU:
        fanout(f"shuru x{PAR}", shuru(job, "go127", mods), PAR)

    shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
