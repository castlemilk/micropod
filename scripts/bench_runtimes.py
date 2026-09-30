#!/usr/bin/env python3
"""bench_runtimes.py — CI-shaped benchmark across micropod's execution options.

  sandbox       micropod sandbox: in-process VZ micro-VM per run (CLI fast path)
  apple         `container run --rm`: Apple container runtime, VM per container
  docker        `docker run --rm` against the current Docker context
  machine       `container machine run`: exec into a warm, persistent VM
  api:sandbox   Connect API RunContainer(runtime=sandbox) → Wait → Delete
  api:apple     Connect API RunContainer(runtime=apple)   → Wait → Delete
  api:sandbox@new  the same against a second API build (MICROPOD_API_NEW=url)
  shuru         shuru microVM sandbox, if installed (SHURU=/path or on PATH)

Rows: boot → `true` → teardown; `go vet && go test` on ci/samples/go-app with a
cold GOCACHE and a shared pre-warmed module cache; N concurrent go jobs. The
module cache persists in ~/.micropod/bench/gomod (APFS-cloned into each run),
so only the first run needs a network.
Every option gets 2 vCPU / 2 GiB. Rounds are interleaved — each round runs
every option once — so load drift on a busy host lands on all of them alike.

Usage: scripts/bench_runtimes.py [--only a,b] [--skip a,b] [--json out.json]
       N_BOOT=10 N_JOB=3 PAR=4 to tune; MICROPOD=path picks the CLI binary.
The CLI must carry the virtualization entitlement (`task cli`, or a
packaged build); api:* rows need the API daemon on :45454.
"""
import argparse
import concurrent.futures as cf
import json
import os
import shutil
import statistics
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MICROPOD = os.environ.get("MICROPOD", f"{ROOT}/.build/debug/micropod")
SHURU = os.environ.get("SHURU") or shutil.which("shuru")
DOCKER = shutil.which("docker")
API = os.environ.get("MICROPOD_API", "http://127.0.0.1:45454")
API_NEW = os.environ.get("MICROPOD_API_NEW")
N_BOOT = int(os.environ.get("N_BOOT", 10))
N_JOB = int(os.environ.get("N_JOB", 3))
PAR = int(os.environ.get("PAR", 4))
MACHINE = "bench-go"
# A second CLI build benchmarked alongside MICROPOD (regression check).
MICROPOD_NEW = os.environ.get("MICROPOD_NEW")
# `go mod download` fills GOMOD once; later runs find it complete and stay
# offline. SETUP_DNS=1.1.1.1 routes around a dead vmnet DNS forwarder
# (needs a CLI with --dns-resolver).
SETUP_MICROPOD = os.environ.get("SETUP_MICROPOD", MICROPOD)
SETUP_DNS = os.environ.get("SETUP_DNS")
GOMOD = os.path.expanduser("~/.micropod/bench/gomod")

GO_JOB = ("export GOMODCACHE=/gomod GOFLAGS=-modcacherw GOCACHE=$(mktemp -d) GOTOOLCHAIN=local; "
          "cp -r /src /tmp/w-$$ && cd /tmp/w-$$ && go vet ./... && go test -count=1 ./...; "
          "rc=$?; rm -rf /tmp/w-$$ \"$GOCACHE\"; exit $rc")


class Option:
    """One runtime option: `cmd(kind)` returns a callable running one job."""

    def __init__(self, name, boot, job, fanout=True):
        self.name, self.boot, self.job, self.fanout = name, boot, job, fanout


def run(cmd):
    r = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"exit {r.returncode}: {' '.join(cmd)}\n{r.stdout[-1500:]}")


def connect(method, body, timeout=600, api=API):
    req = urllib.request.Request(
        f"{api}/api/micropod.v1.ContainerService/{method}", json.dumps(body).encode(),
        {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read() or b"{}")


def api_run(runtime, image, args, volumes=(), api=API):
    """RunContainer detached, WaitContainer, DeleteContainer — the CI path."""
    def go():
        body = {"image": image, "arguments": args, "detach": True, "runtime": runtime,
                "cpus": 2, "memory": "2G", "volumes": list(volumes)}
        cid = connect("RunContainer", body, api=api)["id"]
        try:
            waited = connect("WaitContainer", {"id": cid, "timeoutSeconds": 600}, api=api)
            if waited.get("exitCode", 0) not in (0, None) and waited.get("known"):
                raise RuntimeError(f"{runtime} {image} exited {waited.get('exitCode')}")
        finally:
            connect("DeleteContainer", {"id": cid, "force": True}, api=api)
    return go


def options(work, only, skip):
    mods = [f"{work}/go-app:/src", f"{work}/gomod:/gomod"]
    vflags = [x for m in mods for x in ("-v", m)]
    job = ["sh", "-c", GO_JOB]
    opts = [
        Option("sandbox",
               lambda: run([MICROPOD, "sandbox", "run", "-c", "2", "-m", "2048", "alpine:3.20", "--", "true"]),
               lambda: run([MICROPOD, "sandbox", "run", "-c", "2", "-m", "2048", *vflags, "golang:1", "--", *job])),
        Option("apple",
               lambda: run(["container", "run", "--rm", "-c", "2", "-m", "2G", "alpine:3.20", "true"]),
               lambda: run(["container", "run", "--rm", "-c", "2", "-m", "2G", *vflags, "golang:1", *job])),
        # `container machine run` insists on a terminal (script(1) lends it a
        # pty) and joins its argv into one line for the login shell — so the
        # job goes as a single string. The machine sees the host home at the
        # same path; the login shell doesn't get the image's ENV (PATH).
        Option("machine",
               lambda: run(["script", "-q", "/dev/null", "container", "machine", "run", "-n", MACHINE,
                            "--", "true"]),
               lambda: run(["script", "-q", "/dev/null", "container", "machine", "run", "-n", MACHINE,
                            "--", "export PATH=/usr/local/go/bin:$PATH; "
                            + GO_JOB.replace("/src", f"{work}/go-app").replace("/gomod", f"{work}/gomod")]),
               fanout=False),
        Option("api:sandbox",
               api_run("sandbox", "alpine:3.20", ["true"]),
               api_run("sandbox", "golang:1", job, mods)),
        Option("api:apple",
               api_run("apple", "alpine:3.20", ["true"]),
               api_run("apple", "golang:1", job, mods)),
    ]
    if MICROPOD_NEW:
        opts.append(Option(
            "sandbox@new",
            lambda: run([MICROPOD_NEW, "sandbox", "run", "-c", "2", "-m", "2048", "alpine:3.20", "--", "true"]),
            lambda: run([MICROPOD_NEW, "sandbox", "run", "-c", "2", "-m", "2048", *vflags, "golang:1", "--", *job])))
    if API_NEW:
        opts.append(Option(
            "api:sandbox@new",
            api_run("sandbox", "alpine:3.20", ["true"], api=API_NEW),
            api_run("sandbox", "golang:1", job, mods, api=API_NEW)))
    if DOCKER:
        opts.append(Option(
            "docker",
            lambda: run([DOCKER, "run", "--rm", "--cpus", "2", "-m", "2g", "alpine:3.20", "true"]),
            lambda: run([DOCKER, "run", "--rm", "--cpus", "2", "-m", "2g", *vflags, "golang:1", *job])))
    if SHURU:
        sm = [x for m in mods for x in ("--mount", m)]
        opts.append(Option(
            "shuru",
            lambda: run([SHURU, "run", "--cpus", "2", "--memory", "2048", "--", "true"]),
            # A checkpoint boots at the disk size it was saved with.
            lambda: run([SHURU, "run", "--cpus", "2", "--memory", "2048", "--disk-size", "8192", "--from", "go127",
                         *sm, "--", *job])))
    names = [o.name for o in opts]
    for n in (only or []) + (skip or []):
        if n not in names:
            sys.exit(f"unknown option {n!r}; have {names}")
    return [o for o in opts if (not only or o.name in only) and o.name not in (skip or [])]


def timed(fn):
    t = time.perf_counter()
    try:
        fn()
    except Exception:  # one retry absorbs a transient runtime hiccup
        t = time.perf_counter()
        fn()
    return time.perf_counter() - t


def interleaved(opts, pick, n):
    """n rounds; each round runs every option once, in rotating order."""
    for o in opts:
        pick(o)()  # warm-up: first-run unpack / page cache, not counted
    samples = {o.name: [] for o in opts}
    for i in range(n):
        order = opts[i % len(opts):] + opts[:i % len(opts)]
        for o in order:
            samples[o.name].append(timed(pick(o)))
    return samples


def fanout(opts, k, rounds=3):
    samples = {}
    for o in opts:
        if not o.fanout:
            continue
        walls = []
        for _ in range(rounds):
            t = time.perf_counter()
            with cf.ThreadPoolExecutor(k) as ex:
                list(ex.map(lambda _: timed(o.job), range(k)))
            walls.append(time.perf_counter() - t)
        samples[o.name] = walls
    return samples


def report(title, samples):
    print(f"\n== {title} ==")
    best = min(statistics.median(xs) for xs in samples.values())
    for name, xs in sorted(samples.items(), key=lambda kv: statistics.median(kv[1])):
        xs = sorted(xs)
        p50 = statistics.median(xs)
        print(f"  {name:<12} p50 {p50:7.2f}s  min {xs[0]:7.2f}s  max {xs[-1]:7.2f}s  "
              f"x{p50 / best:4.2f}  (n={len(xs)})", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", type=lambda s: s.split(","))
    ap.add_argument("--skip", type=lambda s: s.split(","))
    ap.add_argument("--json")
    ap.add_argument("--rows", default="boot,job,fanout")
    args = ap.parse_args()
    rows = args.rows.split(",")

    # Under $HOME: machines see the host home through their home mount, and
    # shuru only mounts paths under CWD.
    work = os.path.expanduser(f"~/.micropod/bench/runtimes-{os.getpid()}")
    os.makedirs(work)
    os.chdir(work)
    shutil.copytree(f"{ROOT}/ci/samples/go-app", "go-app")
    opts = options(work, args.only, args.skip)
    print(f"workdir {work}\noptions: {', '.join(o.name for o in opts)}\nload: {os.getloadavg()}")
    dns = ["--dns-resolver", SETUP_DNS] if SETUP_DNS else []
    os.makedirs(GOMOD, exist_ok=True)
    setup = [SETUP_MICROPOD, "sandbox", "run", "--net", *dns, "-v", f"{work}/go-app:/src:ro", "-v",
             f"{GOMOD}:/gomod", "-e", "GOMODCACHE=/gomod", "-e", "GOFLAGS=-modcacherw",
             "-w", "/src", "golang:1", "--", "go", "mod", "download"]
    if subprocess.run(setup).returncode != 0:  # idempotent: one retry for a VM lost at boot
        subprocess.run(setup, check=True)
    subprocess.run(["cp", "-c", "-R", GOMOD, "gomod"], check=True)  # APFS clone: ~1 s
    if any(o.name == "machine" for o in opts):
        # Machines boot the image's /sbin/init: golang:1 (Debian, no
        # systemd) has none, the alpine variant has busybox's.
        subprocess.run(["container", "machine", "delete", MACHINE], capture_output=True)
        subprocess.run(["container", "machine", "create", "golang:1-alpine", "--name", MACHINE,
                        "--cpus", "2", "--memory", "2G", "--progress", "none"], check=True)
    if SHURU and any(o.name == "shuru" for o in opts):
        if "go127" not in subprocess.run([SHURU, "checkpoint", "list"], capture_output=True, text=True).stdout:
            subprocess.run([SHURU, "checkpoint", "create", "go127", "--allow-net", "--disk-size", "8192",
                            "--", "sh", "-c",
                            "curl -fsSL https://go.dev/dl/go1.27.1.linux-arm64.tar.gz | tar -C /usr/local -xz"
                            " && ln -sf /usr/local/go/bin/go /usr/local/bin/go"], check=True)

    results = {"load_start": os.getloadavg(), "rows": {}}
    try:
        if "boot" in rows:
            s = interleaved(opts, lambda o: o.boot, N_BOOT)
            report(f"boot → `true` → teardown (n={N_BOOT}, interleaved)", s)
            results["rows"]["boot"] = s
        if "job" in rows:
            s = interleaved(opts, lambda o: o.job, N_JOB)
            report(f"go vet + go test, cold GOCACHE (n={N_JOB}, interleaved)", s)
            results["rows"]["job"] = s
        if "fanout" in rows:
            s = fanout(opts, PAR)
            report(f"fan-out: {PAR} concurrent go jobs, wall (3 rounds)", s)
            results["rows"]["fanout"] = s
    finally:
        results["load_end"] = os.getloadavg()
        print(f"\nload: start {results['load_start']} end {results['load_end']}")
        if any(o.name == "machine" for o in opts):
            subprocess.run(["container", "machine", "delete", MACHINE], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)
        if args.json:
            with open(args.json, "w") as f:
                json.dump(results, f, indent=2)


if __name__ == "__main__":
    main()
