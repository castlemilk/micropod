#!/usr/bin/env python3
"""The scale gate's driver: many containers at once through the Docker CLI.

    driver.py SOCKET RECEIPT RUN IMAGE WORKLOADS

SOCKET is the machine's Docker socket, RECEIPT the receipt directory, RUN the
label value every object of this run carries (scale.run=RUN), IMAGE a small
image with /bin/sh, WORKLOADS a comma-separated list of:

    runN        N `docker run --rm` at once (N clients started together)
    aliveN      N containers alive at once, started over 16 streams
    buildN      N `docker build` at once, each with a step of its own
    composeN    one compose project of N services, up --wait then down
    churnN      N short `docker run --rm` over 16 streams
    netN        N per-job networks, each with a container on it, at once

It appends to RECEIPT/checks.tsv and RECEIPT/metrics.tsv. The only hard
checks are that no client failed and that nothing carrying the run label is
left; every number is a metric. Exit 0 when it ran (whatever the checks
said), 2 when it could not run.
"""
import concurrent.futures
import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.parse

DOCKER = os.environ.get("GATE_DOCKER_BIN", "docker")
STREAMS = int(os.environ.get("GATE_STREAMS", "16"))
TMP = os.environ.get("GATE_TMP", "/tmp")


class Unix(http.client.HTTPConnection):
    def __init__(self, path, timeout=30):
        super().__init__("d", timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def api(sock, method, path, body=None, timeout=30):
    c = Unix(sock, timeout)
    try:
        headers = {"Content-Type": "application/json"} if body is not None else {}
        c.request(method, path, json.dumps(body) if body is not None else None, headers)
        r = c.getresponse()
        data = r.read()
        return r.status, data
    finally:
        c.close()


def docker(args, timeout=600, cwd=None):
    begin = time.monotonic()
    try:
        p = subprocess.run([DOCKER] + args, capture_output=True, text=True, timeout=timeout, cwd=cwd)
        return p.returncode, p.stdout, p.stderr, time.monotonic() - begin
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ss" % timeout, time.monotonic() - begin


def pct(values, p):
    if not values:
        return 0.0
    s = sorted(values)
    return s[min(len(s) - 1, int(round(p / 100.0 * (len(s) - 1))))]


class Gate:
    def __init__(self, sock, receipt, run, image):
        self.sock, self.receipt, self.run, self.image = sock, receipt, run, image
        self.lock = threading.Lock()
        self.n = 0

    def metric(self, workload, name, value, unit=""):
        with self.lock, open(os.path.join(self.receipt, "metrics.tsv"), "a") as f:
            f.write("%s\t%s\t%s\t%s\n" % (workload, name, ("%.3f" % value) if isinstance(value, float) else value, unit))

    def check(self, workload, label, got, want, evidence=""):
        self.n += 1
        ok = "pass" if str(got) == str(want) else "fail"
        with self.lock, open(os.path.join(self.receipt, "checks.tsv"), "a") as f:
            f.write("W-%02d\t%s\t%s\t%s\t%s\t%s\t%s\n" % (self.n, workload, ok, label, got, want, evidence.replace("\t", " ").replace("\n", " | ")[:1500]))
        print("  %s %s: %s (got %s, want %s)" % ("ok  " if ok == "pass" else "FAIL", workload, label, got, want), flush=True)

    def engine(self):
        status, data = api(self.sock, "GET", "/micropod/metrics?host=1")
        return json.loads(data) if status == 200 else {}

    def labels(self):
        return ["--label", "scale.run=" + self.run]

    def left(self):
        """What carries the run label: containers, networks, volumes."""
        f = json.dumps({"label": ["scale.run=" + self.run]})
        out = {}
        for kind, path in (("containers", "/containers/json?all=1&filters="), ("networks", "/networks?filters="), ("volumes", "/volumes?filters=")):
            status, data = api(self.sock, "GET", path + urllib.parse.quote(f))
            body = json.loads(data) if status == 200 else None
            if kind == "volumes" and isinstance(body, dict):
                body = body.get("Volumes") or []
            out[kind] = len(body) if isinstance(body, list) else -1
        return out

    def measure(self, workload, fn):
        """Runs fn between two engine snapshots; fn returns (durations, failures)."""
        print("== %s" % workload, flush=True)
        before = self.engine()
        begin = time.monotonic()
        durations, failures = fn()
        wall = time.monotonic() - begin
        after = self.engine()
        self.metric(workload, "clients", len(durations) + len(failures))
        self.metric(workload, "wall_s", wall, "s")
        self.metric(workload, "p50_s", pct(durations, 50), "s")
        self.metric(workload, "p95_s", pct(durations, 95), "s")
        self.metric(workload, "max_s", max(durations) if durations else 0.0, "s")
        if wall > 0:
            self.metric(workload, "per_second", len(durations) / wall, "1/s")
        self.delta(workload, before, after, wall)
        self.check(workload, "no client failed", len(failures), 0, "; ".join(failures[:5]))
        left = self.left()
        self.check(workload, "nothing of the run is left", "%(containers)d containers, %(networks)d networks, %(volumes)d volumes" % left, "0 containers, 0 networks, 0 volumes")
        print("   %d ok, %d failed, wall %.2fs, p50 %.3fs, p95 %.3fs" % (len(durations), len(failures), wall, pct(durations, 50), pct(durations, 95)), flush=True)

    def delta(self, workload, before, after, wall):
        hb, ha = before.get("host") or {}, after.get("host") or {}
        cpus = ha.get("cpus") or 1
        for group in ("engine", "containerd", "buildkitd", "shims"):
            b, a = (hb.get("process_groups") or {}).get(group) or {}, (ha.get("process_groups") or {}).get(group) or {}
            if a:
                self.metric(workload, group + "_cpu_s", (a.get("cpu_usec", 0) - b.get("cpu_usec", 0)) / 1e6, "s")
                self.metric(workload, group + "_rss_mib", a.get("rss_bytes", 0) / 1048576.0, "MiB")
                if a.get("fds"):
                    self.metric(workload, group + "_fds", a["fds"])
        if "cpu_busy_usec" in ha and wall > 0:
            busy = (ha["cpu_busy_usec"] - hb.get("cpu_busy_usec", 0)) / 1e6
            self.metric(workload, "guest_cpu_busy_s", busy, "s")
            self.metric(workload, "guest_cpu_utilisation", busy / (wall * cpus), "fraction")
        for name in ("open_files", "conntrack_entries", "processes", "goroutines", "memory_available_bytes"):
            if name in ha:
                self.metric(workload, "after_" + name, ha[name])
        for name in ("containers_created", "create_ms_total", "pod_ms_total", "start_ms_total", "record_writes", "record_commits", "setup_wait_usec_total", "runtime_failures"):
            if name in after:
                self.metric(workload, "engine_" + name, after[name] - before.get(name, 0))
        ab, aa = before.get("api") or {}, after.get("api") or {}
        for name in ("errors_5xx", "conflicts_409", "slow_requests_total"):
            self.metric(workload, "api_" + name, aa.get(name, 0) - ab.get(name, 0))
        rb, ra = ab.get("routes") or {}, aa.get("routes") or {}
        for route in sorted(ra):
            count = ra[route]["count"] - (rb.get(route) or {}).get("count", 0)
            if count > 0 and not route.startswith("GET /micropod"):
                usec = ra[route]["duration_usec_total"] - (rb.get(route) or {}).get("duration_usec_total", 0)
                self.metric(workload, "route_mean_ms[%s]" % route, usec / count / 1000.0, "ms")
        bb, ba = (before.get("network") or {}).get("bridge") or {}, (after.get("network") or {}).get("bridge") or {}
        attaches = ba.get("attach_attempts", 0) - bb.get("attach_attempts", 0)
        if attaches > 0:
            self.metric(workload, "bridge_attach_mean_ms", (ba.get("attach_usec_total", 0) - bb.get("attach_usec_total", 0)) / attaches / 1000.0, "ms")

    # --- workloads ---

    def together(self, n, one, workers=None):
        durations, failures = [], []
        gate = threading.Barrier(workers or n) if not workers else None

        def call(i):
            if gate:
                gate.wait()
            return one(i)

        with concurrent.futures.ThreadPoolExecutor(max_workers=workers or n) as pool:
            for rc, out, err, took in pool.map(call, range(n)):
                if rc == 0:
                    durations.append(took)
                else:
                    failures.append("exit %d: %s" % (rc, (err or out).strip()[-300:]))
        return durations, failures

    def runs(self, n, workers=None):
        return self.together(n, lambda i: docker(["run", "--rm"] + self.labels() + [self.image, "sh", "-c", "echo ok"]), workers)

    def alive(self, n):
        name = lambda i: "scale-%s-a%d" % (self.run, i)
        durations, failures = self.together(n, lambda i: docker(["run", "-d", "--name", name(i)] + self.labels() + [self.image, "sleep", "3600"]), STREAMS)
        status, data = api(self.sock, "GET", "/containers/json?filters=" + urllib.parse.quote(json.dumps({"label": ["scale.run=" + self.run], "status": ["running"]})), timeout=120)
        running = len(json.loads(data)) if status == 200 else -1
        self.check("alive%d" % n, "all of them run at once", running, n)
        mid = self.engine().get("host") or {}
        w = "alive%d" % n
        for key in ("open_files", "processes", "memory_available_bytes", "conntrack_entries"):
            if key in mid:
                self.metric(w, "while_alive_" + key, mid[key])
        shims = (mid.get("process_groups") or {}).get("shims") or {}
        if shims:
            self.metric(w, "while_alive_shims_rss_mib", shims.get("rss_bytes", 0) / 1048576.0, "MiB")
        probe = docker(["run", "--rm"] + self.labels() + [self.image, "true"])
        self.metric(w, "one_more_run_s", probe[3], "s")
        if probe[0] != 0:
            failures.append("a run beside %d live containers: %s" % (n, probe[2].strip()[-300:]))
        begin = time.monotonic()
        ids = [name(i) for i in range(n)]
        for at in range(0, n, 50):
            rc, out, err, _ = docker(["rm", "-f"] + ids[at:at + 50], timeout=900)
            if rc != 0:
                failures.append("rm -f: " + err.strip()[-300:])
        self.metric(w, "remove_all_s", time.monotonic() - begin, "s")
        return durations, failures

    def build(self, n):
        root = os.path.join(TMP, "scale-build-" + self.run)
        shutil.rmtree(root, ignore_errors=True)
        for i in range(n):
            d = os.path.join(root, str(i))
            os.makedirs(d)
            with open(os.path.join(d, "Dockerfile"), "w") as f:
                f.write("FROM %s\nRUN echo %s-%d > /unique && dd if=/dev/zero of=/pad bs=1024 count=256 2>/dev/null\nCOPY Dockerfile /Dockerfile\n" % (self.image, self.run, i))
        tag = lambda i: "scale-%s-b%d:1" % (self.run, i)
        out = self.together(n, lambda i: docker(["build", "-q", "-t", tag(i)] + self.labels() + [os.path.join(root, str(i))], timeout=900))
        docker(["rmi", "-f"] + [tag(i) for i in range(n)])
        shutil.rmtree(root, ignore_errors=True)
        return out

    def compose(self, n):
        root = os.path.join(TMP, "scale-compose-" + self.run)
        shutil.rmtree(root, ignore_errors=True)
        os.makedirs(root)
        lines = ["services:"]
        for i in range(n):
            lines += ["  s%d:" % i, "    image: %s" % self.image, "    command: [\"sleep\", \"3600\"]", "    labels: {\"scale.run\": \"%s\"}" % self.run,
                      "    healthcheck: {test: [\"CMD\", \"true\"], interval: 1s, timeout: 2s, retries: 5}"]
            if i:
                lines += ["    depends_on: {s0: {condition: service_healthy}}"]
        lines += ["networks:", "  default:", "    labels: {\"scale.run\": \"%s\"}" % self.run]
        file = os.path.join(root, "compose.yaml")
        with open(file, "w") as f:
            f.write("\n".join(lines) + "\n")
        project = "scale" + self.run
        durations, failures = [], []
        up = docker(["compose", "-f", file, "-p", project, "up", "-d", "--wait"], timeout=900)
        (durations if up[0] == 0 else failures).append(up[3] if up[0] == 0 else "up: " + up[2].strip()[-400:])
        rc, out, _, _ = docker(["compose", "-f", file, "-p", project, "ps", "-q"])
        self.check("compose%d" % n, "every service runs", len(out.split()), n)
        down = docker(["compose", "-f", file, "-p", project, "down", "-v", "-t", "1"], timeout=900)
        self.metric("compose%d" % n, "down_s", down[3], "s")
        if down[0] != 0:
            failures.append("down: " + down[2].strip()[-400:])
        shutil.rmtree(root, ignore_errors=True)
        return durations, failures

    def net(self, n):
        """A GitHub runner job n times over: a network, a container on it with an alias, exec, rm, network rm."""
        def one(i):
            net, name = "scale-%s-n%d" % (self.run, i), "scale-%s-nc%d" % (self.run, i)
            begin = time.monotonic()
            for args in (["network", "create"] + self.labels() + [net],
                         ["run", "-d", "--name", name, "--network", net, "--network-alias", "svc"] + self.labels() + [self.image, "sleep", "600"],
                         ["exec", name, "sh", "-c", "getent hosts svc >/dev/null"],
                         ["rm", "-f", name],
                         ["network", "rm", net]):
                rc, out, err, _ = docker(args)
                if rc != 0:
                    docker(["rm", "-f", name])
                    docker(["network", "rm", net])
                    return rc, out, " ".join(args[:2]) + ": " + err, time.monotonic() - begin
            return 0, "", "", time.monotonic() - begin
        return self.together(n, one)


def main():
    if len(sys.argv) != 6:
        print(__doc__, file=sys.stderr)
        return 2
    sock, receipt, run, image, workloads = sys.argv[1:]
    g = Gate(sock, receipt, run, image)
    if api(sock, "GET", "/_ping")[0] != 200:
        print("the engine at %s does not answer" % sock, file=sys.stderr)
        return 2
    for w in [w for w in workloads.split(",") if w]:
        kind, n = w.rstrip("0123456789"), int(w[len(w.rstrip("0123456789")):] or 0)
        if n <= 0 or kind not in ("run", "alive", "build", "compose", "churn", "net"):
            print("unknown workload %r" % w, file=sys.stderr)
            return 2
        fn = {"run": lambda: g.runs(n), "alive": lambda: g.alive(n), "build": lambda: g.build(n), "compose": lambda: g.compose(n),
              "churn": lambda: g.runs(n, STREAMS), "net": lambda: g.net(n)}[kind]
        try:
            g.measure(w, fn)
        except Exception as e:  # a workload that could not run is a failed check, not a pass
            g.check(w, "the workload ran", "%s: %s" % (type(e).__name__, e), "ran")
        # Leave nothing for the next workload to trip over.
        rc, out, _, _ = docker(["ps", "-aq", "--filter", "label=scale.run=" + run])
        if out.split():
            docker(["rm", "-f"] + out.split(), timeout=900)
        rc, out, _, _ = docker(["network", "ls", "-q", "--filter", "label=scale.run=" + run])
        if out.split():
            docker(["network", "rm"] + out.split())
    return 0


if __name__ == "__main__":
    sys.exit(main())
