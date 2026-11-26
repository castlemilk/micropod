#!/usr/bin/env python3
"""B25 gate driver: the Phase C control plane on a throwaway hvf machine.

Run by scripts/gates/control-plane.sh, which installs the machine, starts
the real MicropodAPI binary on its own Unix socket and loopback port, builds
the cpbench client (cpbench/, the generated connect-go clients of sdk/go)
and exports the environment read below. Nothing is mocked: latencies are
calls to the real API, the MCP suite drives the real MicropodMCP over stdio,
and every effect is checked against the guest (its own Docker socket,
/micropod/caches, /micropod/metrics, files a container wrote through the
machine workspace) or the throwaway files the call was meant to change.

Sections (B25_SECTIONS, run in this order; default all):
  L  latency: Ping, GetSystem, ListContainers (0/8/64 containers), inspect,
     cache summary and explain; Unix socket vs TCP; binary proto, proto-JSON
     and REST; warm p50/p95/p99 over >= 200 samples, the cold first call,
     16 concurrent clients; connections opened per call (client dials,
     corroborated by the server's TIME_WAIT sockets on TCP); guest requests
     per listing; the MICROPOD_BINARY_PROTO opt-out; HTTP/2 and gRPC
  T  create -> start -> wait -> remove round trips; log stream, exec and
     attach time to first byte
  M  MCP over stdio: initialize, tools/list (typed schemas), every tool that
     is safe on a throwaway machine called and its effect verified, invalid
     arguments refused, cache_prune dry-run unless apply:true, no replay of a
     mutation after a dropped connection, tool latency and wire format
C (census calibration) and Z (safety) always run. A process-spawn census
(procwatch.py) samples the API's and every MCP process's children all run.

Checks compare a number with the plan's Phase C target where the plan (or
backlog B25/B39 for Phase C) states one; anything else is recorded under
metrics without a verdict. No check passes on a missing number, too few
samples, a failed instrument or an uncalibrated census.

B25_SABOTAGE (comma list) breaks a precondition on purpose so a check must
fail: list-inspect, prune-apply, replay-proxy, census-blind, few-samples,
expect-flip:<ID>. A sabotaged or partial run never passes.
"""

import bisect
import collections
import http.client
import json
import os
import pathlib
import re
import signal
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from apiproxy import Proxy  # noqa: E402
from mcpsession import MCPSession  # noqa: E402

E = os.environ
ROOT = E["B25_ROOT"]
HVF = E["MICROPOD_HVF_ROOT"]
WS = E["B25_WS"]
SOCK = os.path.join(HVF, "run", "docker.sock")
API_SOCK = E["MICROPOD_API_SOCK"]
API_PORT = int(E["MICROPOD_API_PORT"])
PROXY_PORT = int(E["B25_PROXY_PORT"])
API_BIN = E["B25_API"]
API_LOG = E["B25_API_LOG"]
API_PID_FILE = os.path.join(ROOT, "api.pid")
M = E["B25_MICROPOD"]
MCP_BIN = E["B25_MCP"]
CPBENCH = E["B25_CPBENCH"]
RECEIPT = pathlib.Path(E["B25_RECEIPT"])
RUN = E["B25_RUN"]
IMAGE = E.get("B25_IMAGE", "alpine:3.20")
PULL_IMAGE = E.get("B25_PULL_IMAGE", "busybox:1.36")
SANDBOX_ROOT = E["MICROPOD_SANDBOX_ROOT"]
SECTIONS = E.get("B25_SECTIONS", "L T M").split()
SABOTAGE = [s for s in E.get("B25_SABOTAGE", "").split(",") if s]
FLIP = {s.split(":", 1)[1] for s in SABOTAGE if s.startswith("expect-flip:")}
ALL_SECTIONS = ["L", "T", "M"]
KNOWN_SABOTAGE = {"list-inspect", "prune-apply", "replay-proxy", "census-blind", "few-samples"}
for s in SABOTAGE:
    if s not in KNOWN_SABOTAGE and not s.startswith("expect-flip:"):
        sys.exit(f"b25: unknown sabotage mode {s!r}")
for s in SECTIONS:
    if s not in ALL_SECTIONS:
        sys.exit(f"b25: unknown section {s!r}")
SAMPLES_MIN = 200  # the task's floor for a latency verdict
SAMPLES = int(E.get("B25_SAMPLES", "200"))
if "few-samples" in SABOTAGE:
    SAMPLES = 20
TARGET_US = 1000.0  # plan Phase C gate: < 1 ms p95
WATCH = os.path.join(ROOT, "procwatch.watch")
CENSUS = RECEIPT / "census.jsonl"
RIG_LINK = os.path.expanduser("~/.micropod/docker.sock")
RIG_LINK_BEFORE = E.get("B25_RIG_LINK", "")
HOME_MICROPOD = os.path.realpath(os.path.expanduser("~/.micropod"))
MACHINE_JSON = os.path.join(HVF, "machine.json")
RUNTIMES_JSON = E["MICROPOD_RUNTIMES_CONFIG"]
VOLUME_POLICY = E["MICROPOD_VOLUME_POLICY"]
K8S_CONFIG = os.path.join(ROOT, "k8s.json")
OUT_HOST = os.path.join(WS, "b25-out")
LOGS = RECEIPT / "logs"
EVID = RECEIPT / "evidence"
BENCH = RECEIPT / "bench"
SAMPLE_DIR = RECEIPT / "samples"

SRC_GATE = "plan §6 Phase C gate (binary Connect over the Unix socket, < 1 ms p95); backlog B25 acceptance"
SRC_GATE_RTT = "plan §6 Phase C gate (8 containers in 1 guest RTT); plan §3.1 (1 vsock round trip, not 1 + 2N)"
SRC_SUBPROC = "plan §3.1 (no subprocess shelling on the request path); backlog B25 (child-process count = 0)"
SRC_MCP_GATE = "plan §6 Phase C gate (full MCP tool E2E suite with zero CLI subprocess calls)"
SRC_CONN = "backlog B39 (Phase C transport: <= 2 connections opened per 2000 calls)"
SRC_H2 = "plan §6 Phase C deliverable 1 (HTTP/2 gRPC on api.sock)"
SRC_CACHE_RPC = "plan §6 Phase C deliverable 2 (CacheService protos) and gate (GetCacheStatus < 1 ms p95)"
SRC_MCP_TOOLS = "plan §6 Phase C deliverable 3 / §3.3 (MCP tool list)"
SRC_MCP_WIRE = "plan §3.3 (MCP over api.sock with binary Connect, persistent pooled client, sub-millisecond tools)"

for path in (ROOT, HVF, WS, API_SOCK, SANDBOX_ROOT):
    real = os.path.realpath(path)
    if not (real.startswith("/private/tmp/") or real.startswith("/tmp/")) or real.startswith(HOME_MICROPOD):
        sys.exit(f"b25: refusing to run: {path} is not under /tmp")
if not os.path.realpath(HVF).startswith(os.path.realpath(ROOT) + "/"):
    sys.exit("b25: refusing to run: the machine root is not inside the throwaway root")
if E.get("MICROPOD_LINK_DOCKER_SOCK") != "0":
    sys.exit("b25: refusing to run: MICROPOD_LINK_DOCKER_SOCK must be 0")

RESULTS = []
METRICS = {}
TABLE = []
SECTION = "setup"
WINDOWS = {}  # section -> [t0, t1]
COMMANDS = open(LOGS / "commands.log", "a")
API = {"pid": int(E["B25_API_PID"]), "proc": None}
WATCHED = {}  # label -> pid (the census's watch list)
CALIBRATED = {"ok": False}


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} b25: {msg}", flush=True)


def short(v, n=300):
    s = v if isinstance(v, str) else json.dumps(v, sort_keys=True, default=str)
    return s if len(s) <= n else s[:n] + "…"


def evidence(name, obj):
    p = EVID / f"{name}.json"
    p.write_text(json.dumps(obj, indent=2, sort_keys=True, default=str))
    return str(p.relative_to(RECEIPT))


def check(cid, name, got, want=None, ok=None, ev=None, source=None):
    """Records one numbered check. ok defaults to got == want."""
    if ok is None:
        ok = got == want
    ok = bool(ok)
    flipped = cid in FLIP
    if flipped:
        ok = not ok
    RESULTS.append({"id": cid, "section": SECTION, "name": name, "ok": ok, "got": short(got, 900),
                    "want": short(want, 600), "flipped": flipped, "evidence": ev, "source": source})
    mark = "✓" if ok else "✗"
    extra = "" if ok else f" — got {short(got)}, want {short(want)}"
    print(f"  {mark} [{cid}] {name}{extra}{' (expectation flipped by sabotage)' if flipped else ''}", flush=True)
    return ok


def section(name):
    global SECTION
    SECTION = name
    WINDOWS.setdefault(name, [time.time(), None])


def end_section(name):
    WINDOWS[name][1] = time.time()


# --- transports ---------------------------------------------------------------
class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self.unix_path = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.unix_path)
        self.sock = s


def request(method, path, body=None, *, unix=None, port=None, timeout=30, ctype=None):
    try:
        conn = UnixHTTP(unix, timeout) if unix else http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
        headers = {}
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else (body if isinstance(body, str) else json.dumps(body)).encode()
        if ctype:
            headers["Content-Type"] = ctype
        elif method in ("POST", "PUT", "PATCH") or data is not None:
            headers["Content-Type"] = "application/json"
        conn.request(method, path, body=data, headers=headers)
        r = conn.getresponse()
        raw = r.read()
        hdrs = dict(r.getheaders())
        conn.close()
        return r.status, raw, hdrs
    except (OSError, http.client.HTTPException) as e:
        return 0, str(e).encode(), {}


def parse(raw):
    try:
        return json.loads(raw)
    except ValueError:
        return raw.decode(errors="replace")


def api(method, path, body=None, tcp=False, timeout=60):
    st, raw, _ = request(method, path, body, unix=None if tcp else API_SOCK, port=API_PORT if tcp else None,
                         timeout=timeout)
    return st, parse(raw)


def guest(method, path, body=None, timeout=30):
    st, raw, _ = request(method, path, body, unix=SOCK, timeout=timeout)
    return st, parse(raw)


def guest_raw(method, path, body=None, timeout=30):
    st, raw, _ = request(method, path, body, unix=SOCK, timeout=timeout)
    return st, raw


def docker_ping(timeout=1.0):
    st, raw, _ = request("GET", "/_ping", unix=SOCK, timeout=timeout)
    return st == 200 and raw.strip() == b"OK"


def cli(*args, timeout=300):
    t = time.time()
    try:
        p = subprocess.run([M, *args], capture_output=True, text=True, timeout=timeout)
        rc, out, err = p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as e:
        rc, out, err = -1, e.stdout or "", f"timeout after {timeout}s"
        out = out if isinstance(out, str) else out.decode(errors="replace")
    COMMANDS.write(json.dumps({"t": round(t, 3), "s": round(time.time() - t, 3), "argv": ["micropod", *args],
                               "rc": rc, "stdout": out[-4000:], "stderr": err[-4000:]}) + "\n")
    COMMANDS.flush()
    return rc, out, err


def wait_for(fn, timeout, interval=0.25):
    deadline = time.time() + timeout
    while True:
        v = fn()
        if v:
            return v
        if time.time() >= deadline:
            return None
        time.sleep(interval)


def state():
    try:
        return json.load(open(os.path.join(HVF, "run", "state.json")))
    except (OSError, ValueError):
        return {}


def our_vmms():
    p = subprocess.run(["pgrep", "-f", f"^{HVF}/micropod-vmm .*--disk {HVF}/disk.ext4"], capture_output=True, text=True)
    return [int(x) for x in p.stdout.split()]


def running():
    return state().get("phase") == "running" and docker_ping(2)


def start_machine(timeout=180):
    return cli("machine", "start", "--timeout", str(timeout), timeout=timeout + 30)


def demux(raw):
    """A Docker multiplexed stream (8-byte frame headers) to text; raw text as is."""
    out, i = [], 0
    if len(raw) >= 8 and raw[0] in (0, 1, 2) and raw[1:4] == b"\0\0\0":
        while i + 8 <= len(raw):
            size = int.from_bytes(raw[i + 4:i + 8], "big")
            out.append(raw[i + 8:i + 8 + size])
            i += 8 + size
        return b"".join(out).decode(errors="replace")
    return raw.decode(errors="replace")


# --- the census -------------------------------------------------------------------
def write_watch():
    lines = []
    for label, pid in WATCHED.items():
        lines.append(f"{label} {99999999 if 'census-blind' in SABOTAGE else pid}")
    tmp = WATCH + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, WATCH)
    time.sleep(0.12)  # the census re-reads its watch list every 50 ms


def census_events():
    out = []
    try:
        with open(CENSUS) as f:
            for line in f:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


def children(label_prefix, t0, t1):
    """Processes first seen under a watched pid whose label starts with
    label_prefix, between t0 and t1, with the image they exec'd."""
    evs = census_events()
    execs = {}
    for e in evs:
        if e.get("event") == "exec":
            execs[e["pid"]] = (e.get("path"), e.get("argv"))
    kids = []
    for e in evs:
        if e.get("event") == "child" and str(e.get("watched", "")).startswith(label_prefix) and t0 <= e["t"] <= t1:
            path, argv = execs.get(e["pid"], (e.get("path"), e.get("argv")))
            kids.append({"t": e["t"], "pid": e["pid"], "ppid": e["ppid"], "watched": e["watched"], "depth": e["depth"],
                         "path": path, "argv": (argv or [])[:8]})
    return kids


def census_cadence():
    beats = [e for e in census_events() if e.get("event") in ("beat", "stop")]
    return beats[-1] if beats else {}


def kids_summary(kids):
    c = collections.Counter(os.path.basename(k["path"] or "?") for k in kids)
    return dict(c.most_common())


def zero_children(cid, name, label, t0, t1, source):
    kids = children(label, t0, t1)
    alive = label != "api" or bool(API["pid"])
    got = {"children": len(kids), "executables": kids_summary(kids), "censusCalibrated": CALIBRATED["ok"],
           "cadence": {k: census_cadence().get(k) for k in ("meanGapMs", "maxGapMs")}}
    ev = evidence(f"{cid}-children", kids)
    return check(cid, name, got, "0 children, with a calibrated census",
                 ok=CALIBRATED["ok"] and alive and len(kids) == 0, ev=ev, source=source), kids


# --- the API process --------------------------------------------------------------
def api_ready(timeout=60):
    def ok():
        st, raw, _ = request("GET", "/health", unix=API_SOCK, timeout=2)
        st2, _, _ = request("GET", "/health", port=API_PORT, timeout=2)
        return st == 200 and st2 == 200
    return wait_for(ok, timeout, 0.1)


def api_socket_accepts():
    """The socket accepts a connection (no request sent: the API closes it)."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1)
        s.connect(API_SOCK)
        s.close()
        t = socket.create_connection(("127.0.0.1", API_PORT), timeout=1)
        t.close()
        return True
    except OSError:
        return False


def api_restart():
    """Stops this gate's API (by pid, proven ours) and starts a fresh one."""
    old = API["pid"]
    cmd = subprocess.run(["ps", "-o", "command=", "-p", str(old)], capture_output=True, text=True).stdout.strip()
    if old and cmd.startswith(API_BIN):
        os.kill(old, signal.SIGTERM)
        if not wait_for(lambda: subprocess.run(["kill", "-0", str(old)], capture_output=True).returncode != 0, 15, 0.05):
            os.kill(old, signal.SIGKILL)
            time.sleep(0.5)
        if API["proc"] is not None:
            API["proc"].wait(timeout=10)
    logf = open(API_LOG, "a")
    p = subprocess.Popen([API_BIN], stdout=logf, stderr=logf, env=dict(E))
    API["pid"], API["proc"] = p.pid, p
    with open(API_PID_FILE, "w") as f:
        f.write(str(p.pid))
    WATCHED["api"] = p.pid
    write_watch()
    if not wait_for(api_socket_accepts, 60, 0.02):
        raise SystemExit("b25: a restarted API never accepted on its socket and port")
    return p.pid


# --- cpbench ------------------------------------------------------------------------
def target(transport):
    return f"unix:{API_SOCK}" if transport == "unix" else f"tcp:127.0.0.1:{API_PORT}"


def bench(case, mode, args, env=None, timeout=3600):
    samples = SAMPLE_DIR / f"{case}.jsonl"
    argv = [CPBENCH, mode, *args, "-samples", str(samples)] if mode != "probe" else [CPBENCH, mode, *args]
    t = time.time()
    p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env or dict(E))
    if p.returncode != 0:
        res = {"error": (p.stderr or p.stdout).strip()[-2000:], "argv": argv}
    else:
        try:
            res = json.loads(p.stdout)
        except ValueError:
            res = {"error": "cpbench printed no JSON", "stdout": p.stdout[-2000:]}
    res["case"] = case
    res["startedAt"] = t
    res["endedAt"] = time.time()
    (BENCH / f"{case}.json").write_text(json.dumps(res, indent=2))
    return res


def unary(case, rpc, transport, codec, *, containers=None, n=None, warmup=20, conc=1, id_=None,
          expect_prefix=None, expect_count=None, env=None, target_us=None, source=None, table=True):
    args = ["-target", target(transport), "-codec", codec, "-rpc", rpc, "-n", str(n or SAMPLES),
            "-warmup", str(warmup), "-concurrency", str(conc)]
    if id_:
        args += ["-id", id_]
    if expect_prefix:
        args += ["-expect-prefix", expect_prefix, "-expect-count", str(expect_count)]
    res = bench(case, "unary", args, env=env)
    res["containersListed"] = containers
    if table:
        st = res.get("stats") or {}
        TABLE.append({
            "case": case, "rpc": rpc, "containers": containers, "transport": transport, "codec": codec,
            "codecUsed": res.get("codecUsed"), "concurrency": conc, "n": st.get("n", 0), "errors": res.get("errors"),
            "p50Us": st.get("p50Us"), "p95Us": st.get("p95Us"), "p99Us": st.get("p99Us"), "maxUs": st.get("maxUs"),
            "firstCallUs": res.get("firstCallUs"), "callsPerSecond": res.get("callsPerSecond"),
            "dials": res.get("dials"), "requests": res.get("requests"), "reused": res.get("reusedConnections"),
            "targetP95Us": target_us, "source": source, "error": res.get("error"),
            "calls": (n or SAMPLES) + max(warmup, 1), "window": [res.get("startedAt"), res.get("endedAt")]})
    return res


def valid_samples(res, need_match=False):
    """Why a bench result cannot carry a verdict, or None when it can."""
    if not res or res.get("error"):
        return f"no measurement ({short((res or {}).get('error'), 200)})"
    st = res.get("stats")
    if not st or not st.get("n"):
        return "no successful samples"
    if st["n"] < SAMPLES_MIN:
        return f"{st['n']} samples < the {SAMPLES_MIN} a verdict needs"
    if res.get("errors"):
        return f"{res['errors']} calls failed ({short(res.get('errorSamples'), 200)})"
    if need_match and not res.get("everySampleMatched"):
        return "a sample listed the wrong containers"
    return None


def latency_check(cid, name, res, source, need_match=False):
    why = valid_samples(res, need_match)
    st = res.get("stats") or {}
    got = {"p50Us": st.get("p50Us"), "p95Us": st.get("p95Us"), "p99Us": st.get("p99Us"), "n": st.get("n"),
           "errors": res.get("errors"), "codecUsed": res.get("codecUsed"), "contentTypes": res.get("contentTypes")}
    if why:
        got["invalid"] = why
    return check(cid, name, got, f"p95 < {TARGET_US:.0f} µs over >= {SAMPLES_MIN} warm samples, no failed call",
                 ok=why is None and st["p95Us"] < TARGET_US, ev=f"bench/{res.get('case')}.json", source=source)


# --- guest containers -----------------------------------------------------------------
def guest_containers(prefix):
    st, d = guest("GET", "/containers/json?all=1", timeout=60)
    out = {}
    if st == 200 and isinstance(d, list):
        for c in d:
            for n in c.get("Names") or []:
                n = n.lstrip("/")
                if n.startswith(prefix):
                    out[n] = c.get("State")
    return out


def guest_run(name, cmd, labels=None, binds=None):
    body = {"Image": IMAGE, "Cmd": cmd, "Labels": labels or {}}
    if binds:
        body["HostConfig"] = {"Binds": binds}
    st, d = guest("POST", f"/containers/create?name={name}", body, timeout=120)
    if st != 201:
        return False, d
    st2, d2 = guest("POST", f"/containers/{name}/start", None, timeout=120)
    return st2 in (204, 304), d2


def set_containers(prefix, size):
    """Exactly `size` running containers named prefix001…, and no other of the prefix."""
    want = [f"{prefix}{i:03d}" for i in range(1, size + 1)]
    have = guest_containers(prefix)
    for n in have:
        if n not in want:
            guest("DELETE", f"/containers/{n}?force=1", timeout=60)
    todo = [n for n in want if have.get(n) != "running"]
    errors = []

    def worker(names):
        for n in names:
            if n in have:
                guest("DELETE", f"/containers/{n}?force=1", timeout=60)
            ok, d = guest_run(n, ["sleep", "3600"], labels={"b25.run": RUN, "b25.role": "listing"})
            if not ok:
                errors.append((n, short(d)))
    threads = [threading.Thread(target=worker, args=(todo[i::6],)) for i in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    def exact():
        g = guest_containers(prefix)
        return sorted(k for k, v in g.items() if v == "running") == want and len(g) == size
    done = wait_for(exact, 120, 0.5)
    if not done:
        raise SystemExit(f"b25: could not get exactly {size} running {prefix}* containers: {short(errors)}")
    return want


def guest_metrics():
    st, d = guest("GET", "/micropod/metrics")
    a = ((d or {}).get("api") or {}) if isinstance(d, dict) else {}
    routes = a.get("routes") or {}
    return a.get("requests_total"), {k: (v or {}).get("count") if isinstance(v, dict) else v for k, v in routes.items()}


def proto_list():
    """One binary-proto ListContainers over the socket, straight from Python."""
    st, raw, hdrs = request("POST", "/api/micropod.v1.ContainerService/ListContainers", b"", unix=API_SOCK,
                            timeout=60, ctype="application/proto")
    return st, hdrs.get("Content-Type"), len(raw)


def rtt_check(cid, size, prefix, calls=5):
    time.sleep(0.5)
    r0, routes0 = guest_metrics()
    answers = [proto_list() for _ in range(calls)]
    if "list-inspect" in SABOTAGE:
        log("SABOTAGE list-inspect: one guest inspect per container while the listing is counted")
        for n in guest_containers(prefix):
            guest("GET", f"/containers/{n}/json")
    r1, routes1 = guest_metrics()
    deltas = {k: (routes1.get(k) or 0) - (routes0.get(k) or 0) for k in set(routes0) | set(routes1)}
    deltas = {k: v for k, v in deltas.items() if v}
    counted = {k: v for k, v in deltas.items() if "metrics" not in k and "_ping" not in k}
    inspects = sum(v for k, v in counted.items() if re.search(r"/containers/[^/]+/json$", k))
    per_call = sum(counted.values()) / calls if calls else None
    METRICS.setdefault("guestRequestsPerListing", {})[str(size)] = per_call
    ok = (r0 is not None and all(a[0] == 200 for a in answers) and inspects == 0 and sum(counted.values()) == calls)
    return check(cid, f"ListContainers with {size} containers costs exactly 1 guest request per call and no "
                 "per-container inspect (guest's own counter, 5 binary calls)",
                 {"guestRequestsPerCall": per_call, "inspects": inspects, "routes": counted,
                  "status": sorted({a[0] for a in answers})}, "1 per call, 0 inspects",
                 ok=ok, ev=evidence(f"{cid}-guest-metrics", {"before": [r0, routes0], "after": [r1, routes1],
                                                             "answers": answers}), source=SRC_GATE_RTT)


def time_wait(port):
    """Closed loopback connections to `port` still in TIME_WAIT, by the
    client's ephemeral port, and how many the server's side holds. Whichever
    side closes first keeps the TIME_WAIT socket (both, on a simultaneous
    close), so a connection is counted once, by its client port."""
    out = subprocess.run(["netstat", "-an", "-p", "tcp"], capture_output=True, text=True).stdout
    me = f"127.0.0.1.{port}"
    conns, server_side = set(), 0
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 6 or parts[-1] != "TIME_WAIT":
            continue
        local, foreign = parts[3], parts[4]
        if local == me and foreign.startswith("127.0.0.1."):
            conns.add(foreign.rsplit(".", 1)[1])
            server_side += 1
        elif foreign == me and local.startswith("127.0.0.1."):
            conns.add(local.rsplit(".", 1)[1])
    return conns, server_side


# =================================================================================================
def section_C():
    section("C")
    log("C: calibrating the process census against a known spawner")
    script = ("import subprocess,time\ntime.sleep(0.6)\n"
              "for i in range(10):\n    subprocess.run(['/bin/sleep','0.02']); time.sleep(0.03)\n"
              "for i in range(10):\n    subprocess.run(['/usr/bin/true']); time.sleep(0.03)\n")
    t0 = time.time()
    cal = subprocess.Popen([sys.executable, "-c", script])
    WATCHED["calibration"] = cal.pid
    write_watch()
    cal.wait()
    time.sleep(0.3)
    kids = children("calibration", t0, time.time())
    del WATCHED["calibration"]
    write_watch()
    cad = census_cadence()
    METRICS["censusCadence"] = cad
    CALIBRATED["ok"] = check(
        "C01", "the census sees every child of a calibration process (10 × sleep 20 ms, 10 × /usr/bin/true)",
        {"seen": len(kids), "executables": kids_summary(kids), "meanGapMs": cad.get("meanGapMs"),
         "maxGapMs": cad.get("maxGapMs")}, "20 children seen",
        ok=len(kids) == 20, ev=evidence("C01-calibration", kids))
    end_section("C")


def section_Z():
    section("Z")
    log("Z: every process this gate started serves only the throwaway root")
    pids = {"api": API["pid"], "supervisor": state().get("supervisorPID"), "vmm": state().get("vmmPID")}
    held = {}
    for name, pid in pids.items():
        if not pid:
            held[name] = "no pid"
            continue
        p = subprocess.run(["lsof", "-nP", "-p", str(pid)], capture_output=True, text=True)
        held[name] = [ln for ln in p.stdout.splitlines()
                      if (HOME_MICROPOD in ln or "/.micropod/" in ln) and str(RECEIPT) not in ln]
    check("Z01", "no process this gate started (API, supervisor, VMM) holds a file under ~/.micropod "
          "(other than this receipt)", held, {k: [] for k in pids}, ev=evidence("Z01-lsof", {"pids": pids, "held": held}))
    p = subprocess.run(["lsof", "-nP", "-a", "-p", str(API["pid"]), "-iTCP", "-sTCP:LISTEN"], capture_output=True,
                       text=True)
    listens = sorted({ln.split()[8] for ln in p.stdout.splitlines()[1:] if len(ln.split()) > 8})
    check("Z02", f"the API listens on loopback port {API_PORT} only", listens, f"127.0.0.1/[::1]:{API_PORT}",
          ok=listens and all(x.endswith(f":{API_PORT}") and (x.startswith("127.0.0.1") or x.startswith("[::1]"))
                             for x in listens))
    st = os.lstat(API_SOCK)
    check("Z03", "the API's own socket is this root's, 0600", (oct(st.st_mode & 0o777), API_SOCK.startswith(ROOT)),
          ("0o600", True))
    s1, h1 = api("GET", "/v1/rig/health")
    check("Z04", "the API drives this root's machine", ((h1 or {}).get("hvf") or {}).get("root")
          if isinstance(h1, dict) else h1, HVF)
    vmms = our_vmms()
    check("Z05", "the running VMM that state.json names is this root's and the only one", vmms, [pids["vmm"]],
          ok=bool(pids["vmm"]) and vmms == [pids["vmm"]])
    end_section("Z")


def rig_link():
    try:
        return os.readlink(RIG_LINK)
    except OSError:
        return ""


def section_Z_final():
    section("Zf")
    now = rig_link()
    check("Z06", "the rig's ~/.micropod/docker.sock link points where it did before this gate started",
          now, RIG_LINK_BEFORE, ok=now == RIG_LINK_BEFORE and (not now or not now.startswith(ROOT)))
    pid = API["pid"]
    p = subprocess.run(["lsof", "-nP", "-p", str(pid)], capture_output=True, text=True)
    held = [ln for ln in p.stdout.splitlines() if (HOME_MICROPOD in ln or "/.micropod/" in ln) and str(RECEIPT) not in ln]
    check("Z07", "after the run, the API holds no file under ~/.micropod (it was started for a throwaway root)",
          held, [], ev=evidence("Z07-lsof-after", held))
    end_section("Zf")


# =================================================================================================
def section_L():
    section("L")
    t0 = time.time()
    prefix = f"b25-{RUN}-l"
    log(f"L: control-plane latency ({SAMPLES} warm samples per case)")
    lists = {}
    for size in (0, 8, 64):
        set_containers(prefix, size)
        rtt_check(f"L-RTT-{size}", size, prefix)
        for transport in ("unix", "tcp"):
            for codec in ("proto", "json", "rest"):
                case = f"list{size}-{transport}-{codec}"
                gate = size == 8 and transport == "unix" and codec == "proto"
                lists[case] = unary(case, "ListContainers", transport, codec, containers=size,
                                    expect_prefix=prefix, expect_count=size,
                                    target_us=TARGET_US if gate else None, source=SRC_GATE if gate else None)
        runs = {c: r for c, r in lists.items() if c.startswith(f"list{size}-")}
        bad = {c: (r.get("error") or ("mismatch" if not r.get("everySampleMatched") else None),
                   r.get("matchingContainers")) for c, r in runs.items()
               if r.get("error") or not r.get("everySampleMatched") or r.get("matchingContainers") != size}
        check(f"L-LIST-{size}", f"every ListContainers sample (3 codecs × 2 transports) listed exactly the {size} "
              "running containers the guest holds", bad, {},
              ok=not bad and all((r.get("stats") or {}).get("n") for r in runs.values()))
        if size == 8:
            latency_check("L-GATE-LIST8", "ListContainers (8 containers), binary Connect over api.sock: p95 < 1 ms",
                          lists["list8-unix-proto"], SRC_GATE, need_match=True)
            section_L_at8(prefix)
    set_containers(prefix, 0)
    end_section("L")
    zero_children("L-CENSUS", "no request in the latency runs made the API spawn a child process", "api",
                  t0, time.time(), SRC_SUBPROC)


def section_L_at8(prefix):
    ids = [f"{prefix}{i:03d}" for i in range(1, 9)]
    one = ids[0]
    res = {}
    for transport in ("unix", "tcp"):
        for codec in ("proto", "json"):
            res[f"ping-{transport}-{codec}"] = unary(
                f"ping-{transport}-{codec}", "Ping", transport, codec, containers=8,
                target_us=TARGET_US if (transport, codec) == ("unix", "proto") else None,
                source=SRC_GATE if (transport, codec) == ("unix", "proto") else None)
        for codec in ("proto", "json", "rest"):
            res[f"system-{transport}-{codec}"] = unary(f"system-{transport}-{codec}", "GetSystem", transport, codec,
                                                       containers=8)
        for codec in ("proto", "json"):
            res[f"inspect-{transport}-{codec}"] = unary(f"inspect-{transport}-{codec}", "GetContainer", transport,
                                                        codec, containers=8, id_=one)
        res[f"cache-{transport}-rest"] = unary(f"cache-{transport}-rest", "CacheSummary", transport, "rest",
                                               containers=8)
        res[f"explain-{transport}-rest"] = unary(f"explain-{transport}-rest", "CacheExplain", transport, "rest",
                                                 containers=8, id_=one)
    res["health-unix-rest"] = unary("health-unix-rest", "Health", "unix", "rest", containers=8)

    latency_check("L-GATE-PING", "Ping, binary Connect over api.sock: p95 < 1 ms", res["ping-unix-proto"], SRC_GATE)
    # GetCacheStatus over binary Connect: the RPC the gate names.
    st, raw, hdrs = request("POST", "/api/micropod.v1.CacheService/GetCacheStatus", b"", unix=API_SOCK,
                            ctype="application/proto")
    rest = (res["cache-unix-rest"].get("stats") or {})
    check("L-GATE-CACHE", "GetCacheStatus, binary Connect over api.sock: p95 < 1 ms",
          {"binaryConnectStatus": st, "body": short(raw.decode(errors="replace"), 160),
           "restGETv1cachesP95Us": rest.get("p95Us"), "restN": rest.get("n")},
          f"a CacheService.GetCacheStatus RPC answering with p95 < {TARGET_US:.0f} µs "
          "(if it now answers 200, cpbench must learn to measure it before this can pass)",
          ok=False, ev=evidence("L-GATE-CACHE-probe", {"status": st, "headers": hdrs,
                                                                              "body": raw.decode(errors="replace")}),
          source=SRC_CACHE_RPC)
    # Correctness of what was measured (not a latency verdict).
    wrong = {}
    for case, r in res.items():
        if r.get("error") or r.get("errors"):
            wrong[case] = r.get("error") or r.get("errorSamples")
    for case in ("ping-unix-proto", "ping-tcp-proto", "ping-unix-json"):
        if res[case].get("detail") != "running/hvf":
            wrong[case + ":detail"] = res[case].get("detail")
    for case in ("inspect-unix-proto", "inspect-tcp-json"):
        if not str(res[case].get("detail", "")).startswith(one):
            wrong[case + ":detail"] = res[case].get("detail")
    check("L-OK-8", "every Ping/GetSystem/inspect/cache case at 8 containers answered every call, Ping said "
          "running/hvf and inspect named the container asked for", wrong, {})

    # Connections opened per call.
    ping = res["ping-unix-proto"]
    METRICS["connections"] = {c: {"dials": r.get("dials"), "requests": r.get("requests"),
                                  "reused": r.get("reusedConnections")} for c, r in res.items() if not r.get("error")}
    check("L-CONN", f"binary Connect Ping over api.sock reuses its connection: <= 2 connections opened for "
          f"{ping.get('requests')} calls", {"dials": ping.get("dials"), "requests": ping.get("requests"),
                                           "reused": ping.get("reusedConnections")}, "dials <= 2",
          ok=not valid_samples(ping) and ping.get("dials") is not None and ping["dials"] <= 2, source=SRC_CONN)
    # Server-side corroboration on TCP: the API closes every connection, so
    # each one leaves a TIME_WAIT socket on its port.
    wait_for(lambda: not time_wait(API_PORT)[0], 45, 1)
    tw0, _ = time_wait(API_PORT)
    corr = unary("conn-tcp-proto", "Ping", "tcp", "proto", containers=8, warmup=0, table=False)
    tw1, server_side = time_wait(API_PORT)
    calls = (corr.get("requests") or 0) + 1  # + the first call
    dials = (corr.get("dials") or 0) + 1
    closed = len(tw1 - tw0)
    METRICS["serverTimeWait"] = {"before": len(tw0), "closedConnections": closed, "serverSideTimeWait": server_side,
                                 "clientDials": dials, "calls": calls}
    check("L-CONN-SERVER", "the kernel's count agrees with the client's: loopback connections to the API's port left "
          "in TIME_WAIT by a TCP run equal the connections the client opened",
          {"closedConnections": closed, "serverClosedFirst": server_side, "clientConnections": dials, "calls": calls},
          "within 5% (or 5)", ok=not corr.get("error") and not tw0 and abs(closed - dials) <= max(5, 0.05 * dials))

    # 16 concurrent clients.
    conc = {}
    n16 = max(2 * SAMPLES, 400) if "few-samples" not in SABOTAGE else SAMPLES
    for rpc, codec, case, idv in (("Ping", "proto", "c16-ping", None), ("ListContainers", "proto", "c16-list8", None),
                                  ("GetContainer", "proto", "c16-inspect", one),
                                  ("CacheSummary", "rest", "c16-cache", None)):
        conc[case] = unary(case, rpc, "unix", codec, containers=8, conc=16, n=n16, id_=idv,
                           expect_prefix=prefix if rpc == "ListContainers" else None,
                           expect_count=8 if rpc == "ListContainers" else None)
    METRICS["concurrency16"] = {c: {"stats": r.get("stats"), "callsPerSecond": r.get("callsPerSecond"),
                                    "dials": r.get("dials"), "errors": r.get("errors")} for c, r in conc.items()}
    bad = {c: r.get("error") or r.get("errorSamples") for c, r in conc.items() if r.get("error") or r.get("errors")}
    check("L-C16-OK", "16 concurrent clients: every call answered (Ping, ListContainers(8) listing all 8, inspect, "
          "cache summary)", bad, {}, ok=not bad and conc["c16-list8"].get("everySampleMatched"))

    # The MICROPOD_BINARY_PROTO opt-out (Cuttlefish's negotiation, mirrored by cpbench -codec auto).
    env_on = dict(E)
    env_on.pop("MICROPOD_BINARY_PROTO", None)
    env_off = dict(E, MICROPOD_BINARY_PROTO="0")
    opt = {}
    for rpc, tag in (("Ping", "ping"), ("ListContainers", "list8")):
        for env, label in ((env_on, "auto"), (env_off, "optout")):
            opt[f"{tag}-{label}"] = unary(f"{tag}-unix-{label}", rpc, "unix", "auto", containers=8, env=env,
                                          expect_prefix=prefix if rpc == "ListContainers" else None,
                                          expect_count=8 if rpc == "ListContainers" else None)
    got = {c: (r.get("advertisedCodecs"), r.get("codecUsed"), r.get("contentTypes")) for c, r in opt.items()}
    ok_on = all(opt[c].get("codecUsed") == "proto" and set((opt[c].get("contentTypes") or {})) == {"application/proto"}
                for c in ("ping-auto", "list8-auto"))
    ok_off = all(opt[c].get("codecUsed") == "json" and set((opt[c].get("contentTypes") or {})) == {"application/json"}
                 for c in ("ping-optout", "list8-optout"))
    check("L-OPTOUT", "codec negotiation: the API advertises proto and every call then answers in binary; with "
          "MICROPOD_BINARY_PROTO=0 every call stays proto-JSON", got, "auto → application/proto only; =0 → "
          "application/json only", ok=ok_on and ok_off and not any(r.get("errors") for r in opt.values()))

    # HTTP/2, gRPC and attach.
    probe = bench("probe-unix", "probe", ["-target", target("unix"), "-id", one])
    probe_tcp = bench("probe-tcp", "probe", ["-target", target("tcp"), "-id", one])
    METRICS["transport"] = {"unix": probe, "tcp": probe_tcp}
    check("L-H2-GRPC", "gRPC over HTTP/2 (h2c, prior knowledge) on api.sock: Ping answers",
          {"grpc": probe.get("grpcH2c"), "connectOverH2c": probe.get("connectH2c"),
           "http1": probe.get("httpVersion"), "connectionHeader": probe.get("connectionHeader")},
          "a PingResponse", ok=bool((probe.get("grpcH2c") or {}).get("status")), ev="bench/probe-unix.json",
          source=SRC_H2)

    # The cold first call: one fresh API per RPC, the call right after it accepts.
    cold = {}
    for rpc, codec, idv in (("Ping", "proto", None), ("GetSystem", "proto", None), ("ListContainers", "proto", None),
                            ("GetContainer", "proto", one), ("CacheSummary", "rest", None),
                            ("CacheExplain", "rest", one)):
        api_restart()
        r = unary(f"cold-{rpc}", rpc, "unix", codec, containers=8, n=1, warmup=0, id_=idv, table=False)
        cold[rpc] = {"firstCallUs": r.get("firstCallUs"), "codec": codec, "error": r.get("firstCallError") or r.get("error"),
                     "secondCallUs": (r.get("stats") or {}).get("p50Us")}
    METRICS["coldFirstCall"] = cold
    api_ready()
    check("L-COLD-OK", "a freshly started API answers its first call of each RPC", {k: v["error"] for k, v in cold.items()
                                                                                     if v["error"]}, {})


# =================================================================================================
def section_T():
    section("T")
    t0 = time.time()
    log("T: create→start→wait→remove round trips; log stream, exec and attach time to first byte")
    rts = {}
    for transport, codec, n in (("unix", "proto", 30), ("unix", "json", 15), ("tcp", "proto", 15)):
        if "few-samples" in SABOTAGE:
            n = 3
        case = f"roundtrip-{transport}-{codec}"
        rts[case] = bench(case, "roundtrip", ["-target", target(transport), "-codec", codec, "-n", str(n),
                                              "-image", IMAGE, "-prefix", f"b25-{RUN}-rt-{transport}-{codec}"])
    left = guest_containers(f"b25-{RUN}-rt-")
    bad = {c: r.get("error") or r.get("errors") for c, r in rts.items() if r.get("error") or r.get("errors")}
    codes = {c: r.get("exitCodes") for c, r in rts.items()}
    check("T01", "every create→start→wait→remove round trip completed, waited for exit code 0, and the guest holds "
          "none of those containers afterwards", {"failures": bad, "exitCodes": codes, "leftInGuest": sorted(left)},
          "no failures, exit 0 only, nothing left", ok=not bad and not left and all(
              list((r.get("exitCodes") or {}).keys()) == ["0"] and r.get("ok") == r.get("requested")
              for r in rts.values()))
    METRICS["roundtrip"] = {c: {"total": r.get("total"), "steps": r.get("steps"), "dials": r.get("dials"),
                                "requests": r.get("requests")} for c, r in rts.items()}
    for c, r in rts.items():
        tot = r.get("total") or {}
        TABLE.append({"case": c, "rpc": "Create+Start+Wait+Delete", "containers": None,
                      "transport": r.get("transport"), "codec": r.get("codec"), "concurrency": 1,
                      "n": tot.get("n", 0), "errors": len(r.get("errors") or []), "p50Us": tot.get("p50Us"),
                      "p95Us": tot.get("p95Us"), "p99Us": tot.get("p99Us"), "maxUs": tot.get("maxUs"),
                      "dials": r.get("dials"), "requests": r.get("requests"), "targetP95Us": None, "source": None,
                      "calls": r.get("requests"), "window": [r.get("startedAt"), r.get("endedAt")]})

    logger = f"b25-{RUN}-logger"
    ok, d = guest_run(logger, ["sh", "-c", "for i in $(seq 1 20); do echo b25-log-$i; done; sleep 3600"],
                      labels={"b25.run": RUN})
    st = wait_for(lambda: "b25-log-20" in demux(guest_raw("GET", f"/containers/{logger}/logs?stdout=1&stderr=1")[1]),
                  30, 0.2)
    if not (ok and st):
        raise SystemExit(f"b25: the logging container never logged its 20 lines: {short(d)}")
    streams = {}
    nlog = 50 if "few-samples" not in SABOTAGE else 5
    for transport, codec, n in (("unix", "proto", nlog), ("unix", "json", nlog), ("unix", "sse", nlog),
                                ("tcp", "proto", 30)):
        case = f"logs-{transport}-{codec}"
        streams[case] = bench(case, "logs", ["-target", target(transport), "-codec", codec, "-id", logger,
                                             "-n", str(n), "-tail", "5", "-expect", "b25-log-16"])
    execs = {}
    for codec in ("proto", "json"):
        case = f"exec-unix-{codec}"
        execs[case] = bench(case, "exec", ["-target", target("unix"), "-codec", codec, "-id", logger, "-n", str(nlog)])
    for c, r in list(streams.items()) + list(execs.items()):
        tt = r.get("ttfb") or {}
        TABLE.append({"case": c, "rpc": "StreamContainerLogs TTFB" if c.startswith("logs") else "Exec (unary)",
                      "containers": None, "transport": r.get("transport"), "codec": r.get("codec"), "concurrency": 1,
                      "n": tt.get("n", 0), "errors": len(r.get("errors") or []), "p50Us": tt.get("p50Us"),
                      "p95Us": tt.get("p95Us"), "p99Us": tt.get("p99Us"), "maxUs": tt.get("maxUs"),
                      "dials": r.get("dials"), "requests": r.get("requested"), "targetP95Us": None, "source": None,
                      "calls": r.get("requested"), "window": [r.get("startedAt"), r.get("endedAt")]})
    bad = {c: (r.get("error"), r.get("ok"), r.get("matchedExpected"), r.get("requested"), r.get("firstChunk"))
           for c, r in streams.items() if r.get("error") or r.get("matchedExpected") != r.get("requested")}
    check("T02", "every log stream (Connect binary, proto-JSON, SSE; socket and TCP) delivered the tail's first line "
          "(b25-log-16 of 20) as its first chunk", bad, {})
    bad = {c: (r.get("error"), r.get("matchedExpected"), r.get("requested"), r.get("errors")[:2] if r.get("errors") else None)
           for c, r in execs.items() if r.get("error") or r.get("matchedExpected") != r.get("requested")}
    check("T03", "every Exec (binary and proto-JSON) echoed its own marker with exit code 0", bad, {})
    probe = bench("probe-attach", "probe", ["-target", target("unix"), "-id", logger])
    METRICS["streams"] = {c: {"ttfb": r.get("ttfb"), "total": r.get("total"), "contentType": r.get("contentType")}
                          for c, r in list(streams.items()) + list(execs.items())}
    METRICS["attach"] = {"supported": (probe.get("attach") or {}).get("status") == "200",
                         "probe": probe.get("attach"),
                         "note": "no AttachContainer RPC (plan §3.2.3, backlog B39): no time to first byte to measure"}
    guest("DELETE", f"/containers/{logger}?force=1")
    end_section("T")
    zero_children("T-CENSUS", "no round trip, log stream or exec made the API spawn a child process", "api",
                  t0, time.time(), SRC_SUBPROC)


# =================================================================================================
SAFE_GUEST, SAFE_FILES, SAFE_SANDBOX, REFUSAL, HOST_READ, UNSAFE = (
    "verified-guest", "verified-throwaway-files", "verified-sandbox", "verified-refusal", "host-read", "unsafe")

# Why a tool is not called with valid arguments on a throwaway machine.
UNSAFE_TOOLS = {
    "runtime_manage": "drives Apple's dedicated runtime through the approved helper (install/stop/restart): host-wide",
    "push": "pushes an image to a registry from the host's Apple store",
    "compose_up": "creates containers on the host's Apple runtime (ComposeService has no hvf path)",
    "compose_down": "deletes the host's Apple containers by compose label",
    "update_apply": "quits the Micropod app to install an update",
    "k8s_up": "creates a k3s cluster VM on the host's Apple runtime",
    "k8s_kubeconfig": "returns ~/.micropod/k8s/kubeconfig (cluster credentials) into the receipt; the path is fixed",
    "machine_logs": "reads an Apple machine's logs; there is no throwaway Apple machine to name",
}
# Read-only calls against the host's Apple runtime or app state: answered, not verifiable against the guest.
HOST_READ_TOOLS = {"status", "runtime_status", "stats", "list_machines", "machine_stats", "df", "list_networks",
                   "compose_ps", "metrics_history"}
PLAN_TOOLS = ["cache_status", "cache_ls", "cache_explain", "cache_dedupe", "cache_prune", "cache_policy_set",
              "runtime_mode", "machine_status", "machine_control", "update_hvf_status", "update_hvf_apply",
              "update_hvf_rollback", "sandbox_run", "sandbox_exec", "sandbox_files", "sandbox_checkpoint",
              "sandbox_status", "telemetry_health", "telemetry_issues", "telemetry_traces"]


def mcp_env(sock=None, port=None):
    env = dict(E)
    env["MICROPOD_K8S_CONFIG"] = K8S_CONFIG
    env["MICROPOD_SHAREDFS_SOCKET"] = os.path.join(ROOT, "sharedfs.sock")  # never started
    if sock:
        env["MICROPOD_API_SOCK"] = sock
    if port:
        env["MICROPOD_API_PORT"] = str(port)
    return env


MCP_N = {"n": 0}


def mcp_open(env=None):
    MCP_N["n"] += 1
    label = f"mcp-{MCP_N['n']}"
    s = MCPSession(MCP_BIN, env or mcp_env(), LOGS / "mcp.jsonl", LOGS / "mcp.stderr")
    s.label = label
    WATCHED[label] = s.pid
    write_watch()
    return s


def mcp_close(s):
    s.close()
    WATCHED.pop(s.label, None)
    write_watch()


def runtimes_file():
    try:
        return json.load(open(RUNTIMES_JSON))
    except (OSError, ValueError):
        return None


def guest_inspect(name):
    st, d = guest("GET", f"/containers/{name}/json")
    return d if st == 200 and isinstance(d, dict) else None


def guest_logs(name, tail):
    """The guest engine's own log of a container, its last `tail` lines (the
    guest's logs route has no tail selection; it answers 400 to one)."""
    st, raw = guest_raw("GET", f"/containers/{name}/logs?stdout=1&stderr=1")
    return [ln for ln in demux(raw).splitlines() if ln][-tail:] if st == 200 else None


def guest_caches(stats=True):
    st, d = guest("GET", "/micropod/caches" + ("" if stats else "?stats=0"), timeout=60)
    return d if st == 200 and isinstance(d, dict) else {}


def unit_facts(inv, scopes=None):
    return {f"{u['scope']}/{u['unit']}": (u.get("files"), u.get("logicalBytes"), u.get("bytes"))
            for u in (inv.get("units") or []) if not scopes or u.get("scope") in scopes}


def schema_problems(tool):
    sch = tool.get("inputSchema")
    out = []
    if not isinstance(sch, dict) or sch.get("type") != "object":
        return ["inputSchema is not {type: object}"]
    props = sch.get("properties")
    if not isinstance(props, dict):
        out.append("no properties map")
        props = {}
    if sch.get("additionalProperties") is not False:
        out.append("additionalProperties is not false")
    for name, p in props.items():
        t = p.get("type") if isinstance(p, dict) else None
        types = t if isinstance(t, list) else [t]
        if not t or not all(x in ("string", "boolean", "integer", "number", "array", "object") for x in types):
            out.append(f"{name}: untyped ({t!r})")
        if not (p or {}).get("description"):
            out.append(f"{name}: no description")
        if "array" in types and not isinstance(p.get("items"), dict):
            out.append(f"{name}: array without items")
    for r in sch.get("required") or []:
        if r not in props:
            out.append(f"required {r} is not a property")
    return out


def bad_value(p):
    """A value of the wrong JSON type (or out of range) for a property schema."""
    t = p.get("type")
    types = t if isinstance(t, list) else [t]
    if p.get("enum"):
        return "b25-not-a-choice"
    if types == ["string"]:
        return 12345
    if types == ["boolean"]:
        return "perhaps"
    if types == ["integer"]:
        return "twelve"
    if types == ["number"]:
        return "lots"
    if "array" in types:
        return {"not": "a list"}
    if "integer" in types:  # size / duration
        return "12 parsecs"
    return None


def section_M():
    section("M")
    t0 = time.time()
    log("M: MCP end to end over stdio")
    os.makedirs(OUT_HOST, exist_ok=True)
    os.chmod(OUT_HOST, 0o777)
    os.makedirs(os.path.join(ROOT, "build-cache-empty"), exist_ok=True)
    # The E2E session goes through a recording pass-through proxy (socket and
    # TCP fallback) so every request it makes of the API is on record.
    rec_sock = os.path.join(ROOT, "mcp-rec.sock")
    rec_unix = Proxy("record-unix", ("unix", rec_sock), ("unix", API_SOCK)).start()
    rec_tcp = Proxy("record-tcp", ("tcp", PROXY_PORT), ("tcp", API_PORT)).start()
    s = mcp_open(mcp_env(sock=rec_sock, port=PROXY_PORT))
    calls = []
    try:
        init = s.init.get("result") or {}
        check("M01", "initialize: protocol 2024-11-05, serverInfo micropod, a tools capability",
              (init.get("protocolVersion"), (init.get("serverInfo") or {}).get("name"), "tools" in (init.get("capabilities") or {})),
              ("2024-11-05", "micropod", True), ev=evidence("M01-initialize", s.init))
        listing = s.request("tools/list", {})
        tools = (listing.get("result") or {}).get("tools") or []
        names = [t.get("name") for t in tools]
        METRICS["mcpTools"] = {"count": len(names), "names": names}
        problems = {t.get("name"): schema_problems(t) for t in tools if schema_problems(t)}
        check("M02", f"tools/list: {len(names)} tools, every one with a typed inputSchema (object, typed and described "
              "properties, additionalProperties false, required ⊆ properties)", problems, {},
              ok=len(names) > 0 and not problems and len(set(names)) == len(names),
              ev=evidence("M02-tools-list", listing))
        missing = [t for t in PLAN_TOOLS if t not in names]
        check("M03", "every MCP tool the plan names for Phase C is listed", missing, [], source=SRC_MCP_TOOLS)
        by = {t["name"]: t for t in tools}
        results = mcp_tools(s, by, calls)
        mcp_invalid(s, by, calls)
        mcp_prune(s, calls)
    finally:
        mcp_close(s)
        rec_unix.stop()
        rec_tcp.stop()
    snap = {"unix": rec_unix.snapshot(), "tcp": rec_tcp.snapshot()}
    evidence("M-wire-record", snap)
    reqs = snap["unix"]["requests"] + snap["tcp"]["requests"]
    ctypes_ = collections.Counter(r.get("contentType") or "(none)" for r in reqs if r.get("method"))
    paths = collections.Counter(f"{r.get('method')} {str(r.get('path', '')).split('?')[0]}" for r in reqs if r.get("method"))
    METRICS["mcpWire"] = {"requests": len(reqs), "connections": snap["unix"]["connections"] + snap["tcp"]["connections"],
                          "contentTypes": dict(ctypes_), "routes": dict(paths.most_common()),
                          "toolCalls": len(calls), "tcpFallbackRequests": len(snap["tcp"]["requests"])}
    binary = sum(v for k, v in ctypes_.items() if "proto" in k)
    check("M-WIRE", "MicropodMCP talks binary Connect to the API over a persistent connection (requests in "
          "application/proto, far fewer connections than requests)",
          {"requests": len(reqs), "binaryRequests": binary, "connections": METRICS["mcpWire"]["connections"],
           "contentTypes": dict(ctypes_), "overTcpWhileTheSocketServed": [
               f"{r.get('method')} {str(r.get('path', '')).split('?')[0]}" for r in snap["tcp"]["requests"]]},
          "every request application/proto; connections <= 2",
          ok=reqs and binary == len([r for r in reqs if r.get("method")]) and METRICS["mcpWire"]["connections"] <= 2,
          source=SRC_MCP_WIRE)
    mcp_replay()
    mcp_latency()
    end_section("M")
    t1 = time.time()
    _, kids = zero_children("M-CENSUS-MCP", "the MCP suite made no CLI/subprocess call (children of every "
                            "MicropodMCP process)", "mcp-", t0, t1, SRC_MCP_GATE)
    METRICS["mcpChildrenByTool"] = by_tool(kids, calls)
    _, api_kids = zero_children("M-CENSUS-API", "the MCP suite made the API spawn no child process", "api", t0, t1,
                                SRC_SUBPROC)
    METRICS["apiChildrenByMcpTool"] = by_tool(api_kids, calls)
    summary = collections.Counter(r["class"] for r in results.values())
    METRICS["mcpCoverage"] = {"listed": len(names), "byClass": dict(summary),
                              "unsafe": {k: v for k, v in UNSAFE_TOOLS.items() if k in names},
                              "hostRead": sorted(HOST_READ_TOOLS & set(names)),
                              "verified": sorted(k for k, r in results.items() if r["class"] != HOST_READ
                                                 and r["class"] != UNSAFE and r.get("ok"))}


def by_tool(kids, calls):
    """{tool: {executable: count}}: each child under the tool call whose window
    holds the moment the census first saw it (else the nearest call, marked ?)."""
    out = collections.defaultdict(collections.Counter)
    for k in kids:
        inside = [c for c in calls if c["t0"] <= k["t"] <= c["t1"]]
        if inside:
            tool = inside[-1]["tool"]
        elif calls:
            tool = min(calls, key=lambda c: min(abs(k["t"] - c["t0"]), abs(k["t"] - c["t1"])))["tool"] + "?"
        else:
            tool = "?"
        out[tool][" ".join(([os.path.basename(k["path"] or "?")] + (k.get("argv") or [])[1:4]))] += 1
    return {t: dict(c) for t, c in out.items()}


def call(s, calls, tool, args, timeout=600):
    r = s.call(tool, args, timeout=timeout)
    r["tool"] = tool
    r["args"] = args
    calls.append(r)
    return r


def mcp_tools(s, by, calls):
    """Calls every tool that is safe here with valid arguments and verifies
    what it did; returns {tool: {class, ok, detail}}."""
    results = {}
    names = set(by)
    known = set(UNSAFE_TOOLS) | HOST_READ_TOOLS
    c = f"b25-{RUN}-mcp"
    marker = f"b25-run-{RUN}"

    def record(tool, cls, ok, got, want, ev_obj=None):
        results[tool] = {"class": cls, "ok": bool(ok), "got": got}
        cid = f"M-T-{tool}"
        check(cid, f"MCP {tool}: {want}", got, want, ok=ok,
              ev=evidence(cid, ev_obj) if ev_obj is not None else None)

    def has(tool):
        known.add(tool)
        return tool in names

    # --- containers on the hvf machine ---
    if has("run"):
        r = call(s, calls, "run", {"image": IMAGE, "name": c, "runtime": "hvf",
                                   "command": f"echo {marker}-1; echo {marker}-2; echo {marker}-3; sleep 600"})
        ins = wait_for(lambda: (lambda d: d if d and (d.get("State") or {}).get("Running") else None)(guest_inspect(c)), 30, 0.2)
        record("run", SAFE_GUEST, not r["error"] and ins and (ins.get("Config") or {}).get("Cmd")[-1].startswith(f"echo {marker}-1"),
               {"reply": short(r["text"], 120), "guestRunning": bool(ins), "guestCmd": (ins or {}).get("Config", {}).get("Cmd")},
               "starts the container on the hvf machine with that command (guest inspect)", {"reply": r, "inspect": ins})
    wait_for(lambda: len(guest_logs(c, 3) or []) == 3, 20, 0.2)
    if has("list_containers"):
        r = call(s, calls, "list_containers", {})
        mine = {ln.split("\t")[0]: ln.split("\t")[1] for ln in r["text"].splitlines() if "\t" in ln and ln.endswith("[hvf]")}
        g = {k: v for k, v in guest_containers(f"b25-{RUN}").items() if v == "running"}
        record("list_containers", SAFE_GUEST, not r["error"] and g and all(mine.get(k) == "running" for k in g),
               {"hvfListed": mine, "guestRunning": g}, "lists every running hvf container the guest holds, as running",
               r)
    if has("inspect"):
        r = call(s, calls, "inspect", {"id": c})
        ins = guest_inspect(c) or {}
        p = r["parsed"] if isinstance(r["parsed"], dict) else {}
        record("inspect", SAFE_GUEST, not r["error"] and p.get("id") == c and p.get("state") == "running" and
               (p.get("image") or "").endswith(IMAGE.split("/")[-1]) and ins.get("Id"),
               {"id": p.get("id"), "state": p.get("state"), "image": p.get("image"),
                "guestState": (ins.get("State") or {}).get("Status")}, "describes the container as the guest does",
               {"reply": r, "guest": ins})
    if has("logs"):
        r = call(s, calls, "logs", {"id": c, "lines": 3})
        g = guest_logs(c, 3)
        record("logs", SAFE_GUEST, not r["error"] and g == [f"{marker}-{i}" for i in (1, 2, 3)] and r["text"].splitlines() == g,
               {"reply": r["text"].splitlines(), "guest": g}, "returns the guest's last 3 log lines", r)
    if has("exec"):
        f = f"/out/exec-{RUN}.txt"
        r = call(s, calls, "exec", {"id": c, "command": f"echo b25-exec-{RUN} > /tmp/x && cat /tmp/x"})
        g = None
        st, d = guest("POST", f"/containers/{c}/exec", {"Cmd": ["cat", "/tmp/x"], "AttachStdout": True})
        if st == 201:
            st2, raw = guest_raw("POST", f"/exec/{d['Id']}/start", {"Detach": False, "Tty": False})
            g = demux(raw).strip()
        record("exec", SAFE_GUEST, not r["error"] and r["text"].strip() == f"b25-exec-{RUN}" and g == f"b25-exec-{RUN}",
               {"reply": r["text"].strip(), "guestReadsBack": g}, "runs in the container: the file it wrote is "
               "there when the guest's own exec reads it", {"reply": r, "file": f})
    if has("cache_explain"):
        r = call(s, calls, "cache_explain", {"id": c})
        p = r["parsed"] if isinstance(r["parsed"], dict) else {}
        ins = guest_inspect(c) or {}
        gplan = ins.get("MicropodCache") or {}
        record("cache_explain", SAFE_GUEST, not r["error"] and p.get("containerId") == ins.get("Id") and
               sorted((p.get("cache") or {}).get("tools") or {}) == sorted(gplan.get("tools") or {}) and ins.get("Id"),
               {"containerId": short(p.get("containerId"), 20), "tools": sorted((p.get("cache") or {}).get("tools") or {}),
                "guestTools": sorted(gplan.get("tools") or {})}, "explains the cache plan the guest recorded for it",
               {"reply": r, "guestPlan": gplan})
    # Lifecycle, on that container.
    if has("stop"):
        r = call(s, calls, "stop", {"id": c})
        g = (guest_inspect(c) or {}).get("State") or {}
        record("stop", SAFE_GUEST, not r["error"] and g.get("Status") == "exited", {"reply": r["text"], "guest": g.get("Status")},
               "stops it (guest: exited)", r)
    if has("start"):
        r = call(s, calls, "start", {"id": c})
        g = wait_for(lambda: (lambda x: x if x.get("Running") else None)((guest_inspect(c) or {}).get("State") or {}), 15, 0.2) or {}
        record("start", SAFE_GUEST, not r["error"] and g.get("Running"), {"reply": r["text"], "guest": g.get("Status")},
               "starts it again (guest: running)", r)
    if has("restart"):
        before = ((guest_inspect(c) or {}).get("State") or {}).get("StartedAt")
        time.sleep(1.1)
        r = call(s, calls, "restart", {"id": c})
        g = wait_for(lambda: (lambda x: x if x.get("Running") and x.get("StartedAt") != before else None)(
            (guest_inspect(c) or {}).get("State") or {}), 20, 0.2) or {}
        record("restart", SAFE_GUEST, not r["error"] and g.get("Running") and g.get("StartedAt") != before,
               {"reply": r["text"], "startedBefore": before, "startedAfter": g.get("StartedAt")},
               "restarts it (guest: running, a new StartedAt)", r)
    if has("kill"):
        r = call(s, calls, "kill", {"id": c})
        g = wait_for(lambda: (lambda x: x if x.get("Status") == "exited" else None)((guest_inspect(c) or {}).get("State") or {}), 15, 0.2) or {}
        record("kill", SAFE_GUEST, not r["error"] and g.get("Status") == "exited",
               {"reply": r["text"], "guest": g.get("Status"), "exitCode": g.get("ExitCode")}, "kills it (guest: exited)", r)
    if has("delete"):
        r = call(s, calls, "delete", {"id": c})
        st, _ = guest("GET", f"/containers/{c}/json")
        record("delete", SAFE_GUEST, not r["error"] and st == 404, {"reply": r["text"], "guestInspectStatus": st},
               "removes it (guest: 404)", r)
    # --- images and volumes ---
    if has("list_images"):
        r = call(s, calls, "list_images", {})
        st, gi = guest("GET", "/images/json")
        tags = {t for i in (gi if isinstance(gi, list) else []) for t in i.get("RepoTags") or []}
        hv = [ln.split("\t")[0] for ln in r["text"].splitlines() if ln.endswith("[hvf]")]
        in_guest = any(t.endswith(IMAGE) for t in tags)
        record("list_images", SAFE_GUEST, not r["error"] and in_guest and any(h.endswith(IMAGE) for h in hv),
               {"hvfListed": hv, "guestTags": sorted(tags)}, f"lists {IMAGE}, which the guest holds, as [hvf]", r)
    if has("pull"):
        r = call(s, calls, "pull", {"reference": PULL_IMAGE, "runtime": "hvf"}, timeout=900)
        st, gi = guest("GET", "/images/json")
        tags = {t for i in (gi if isinstance(gi, list) else []) for t in i.get("RepoTags") or []}
        record("pull", SAFE_GUEST, not r["error"] and any(t.endswith(PULL_IMAGE) for t in tags),
               {"reply": r["text"], "guestHas": sorted(t for t in tags if PULL_IMAGE.split(":")[0] in t)},
               f"pulls {PULL_IMAGE} into the guest's image store", r)
    if has("list_volumes"):
        vol = f"b25-{RUN}-vol"
        st, _ = guest("POST", "/volumes/create", {"Name": vol})
        r = call(s, calls, "list_volumes", {})
        hv = [ln.split("\t")[0] for ln in r["text"].splitlines() if ln.endswith("[hvf]")]
        record("list_volumes", SAFE_GUEST, not r["error"] and st == 201 and vol in hv,
               {"created": st, "hvfListed": hv}, "lists a volume created on the guest's own socket", r)
        guest("DELETE", f"/volumes/{vol}")
    # --- caches and the machine ---
    if has("cache_status"):
        seed = f"b25-{RUN}-cs"
        guest_run(seed, ["sh", "-c", "mkdir -p /micropod/cache/npm/b25 && head -c 12345 /dev/urandom > "
                                     "/micropod/cache/npm/b25/x && sync"],
                  labels={"io.micropod.cache.scope": f"b25s-{RUN}", "b25.run": RUN})
        wait_for(lambda: ((guest_inspect(seed) or {}).get("State") or {}).get("Status") == "exited", 60, 0.3)
        guest("DELETE", f"/containers/{seed}?force=1")
        wait_for(lambda: any(u.get("scope") == f"b25s-{RUN}" and not u.get("inUse") and not u.get("dirty")
                             for u in guest_caches().get("units") or []), 60, 0.5)
        r = call(s, calls, "cache_status", {})
        g = guest_caches()
        p = r["parsed"] if isinstance(r["parsed"], dict) else {}
        record("cache_status", SAFE_GUEST, not r["error"] and unit_facts(g) and unit_facts(p) == unit_facts(g) and
               f"b25s-{RUN}/npm" in unit_facts(g) and
               p.get("policyDigest") == g.get("policyDigest") and g.get("policyDigest"),
               {"units": len(unit_facts(p)), "guestUnits": len(unit_facts(g)), "digest": p.get("policyDigest"),
                "guestDigest": g.get("policyDigest")}, "reports the guest's units and policy digest", {"reply": p, "guest": g})
    if has("cache_dedupe"):
        r = call(s, calls, "cache_dedupe", {"buckets": 4})
        st, g = guest("GET", "/micropod/caches/dedupe?buckets=4", timeout=60)
        p = r["parsed"] if isinstance(r["parsed"], dict) else {}
        same = isinstance(g, dict) and p == g and p.get("bucketsSampled") == 4
        record("cache_dedupe", SAFE_GUEST, not r["error"] and st == 200 and same,
               {"keys": sorted(p), "guestKeys": sorted(g) if isinstance(g, dict) else g, "guestStatus": st},
               "samples dedupe as the guest's own /micropod/caches/dedupe does (same fields, same buckets)",
               {"reply": p, "guest": g})
    if has("cache_policy"):
        r = call(s, calls, "cache_policy", {})
        p = r["parsed"] if isinstance(r["parsed"], dict) else {}
        gp = (guest_caches(stats=False).get("policy") or {})
        common = sorted(set(p) & set(gp))
        differ = {k: (p.get(k), gp.get(k)) for k in common if p.get(k) != gp.get(k)}
        record("cache_policy", SAFE_GUEST, not r["error"] and len(common) >= 4 and not differ and "tools" in common,
               {"fieldsCompared": common, "differ": differ}, "shows the policy the guest is running (every field both "
               "carry is equal)", {"reply": p, "guest": gp})
    if has("cache_policy_set"):
        r = call(s, calls, "cache_policy_set", {"max_age_days": 41})
        gp = wait_for(lambda: (lambda x: x if x.get("maxAgeDays") == 41 else None)(
            guest_caches(stats=False).get("policy") or {}), 10, 0.2) or {}
        cfg = json.load(open(MACHINE_JSON)).get("cache") or {}
        record("cache_policy_set", SAFE_GUEST, not r["error"] and gp.get("maxAgeDays") == 41 and cfg.get("maxAgeDays") == 41,
               {"guestMaxAgeDays": gp.get("maxAgeDays"), "machineJson": cfg.get("maxAgeDays")},
               "hot-applies max_age_days 41: the guest's policy and machine.json say 41", r)
    if has("rig_health"):
        r = call(s, calls, "rig_health", {})
        h = (r["parsed"] or {}).get("hvf") or {} if isinstance(r["parsed"], dict) else {}
        record("rig_health", SAFE_GUEST, not r["error"] and h.get("root") == HVF and h.get("phase") == state().get("phase") == "running",
               {"root": h.get("root"), "phase": h.get("phase"), "statePhase": state().get("phase")},
               "names this root and its live phase", r)
    if has("update_hvf_status"):
        r = call(s, calls, "update_hvf_status", {})
        p = r["parsed"] if isinstance(r["parsed"], dict) else {}
        vdir = os.path.join(HVF, "versions")
        versions = sorted(x for x in (os.listdir(vdir) if os.path.isdir(vdir) else []) if not x.startswith("."))
        cur = os.path.join(HVF, "current")
        cur_real = os.path.realpath(cur) if os.path.lexists(cur) else None
        loaded = state().get("loadedPayloadPath") or HVF  # a flat install runs its root
        running_path = p.get("runningPath")
        record("update_hvf_status", SAFE_FILES, not r["error"] and "availableVersions" in p and running_path and
               p["availableVersions"] == versions and os.path.realpath(running_path) == os.path.realpath(loaded) and
               (p.get("currentPath") and os.path.realpath(p["currentPath"])) == cur_real and p.get("updatePending") is False,
               {"availableVersions": p.get("availableVersions"), "versionsOnDisk": versions,
                "runningPath": running_path, "supervisorLoaded": loaded, "currentPath": p.get("currentPath"),
                "currentOnDisk": cur_real, "updatePending": p.get("updatePending")},
               "reports the payload store on disk and the payload the supervisor runs", p)
    if has("update_hvf_rollback"):
        vmm0 = state().get("vmmPID")
        r = call(s, calls, "update_hvf_rollback", {}, timeout=600)
        time.sleep(1)
        action = ((r["parsed"] or {}).get("result") or {}).get("action") if isinstance(r["parsed"], dict) else None
        same = state().get("vmmPID") == vmm0 and running()
        # A fresh machine has nothing to roll back to: a refusal (no
        # known-good) or a no-op, and either way the same VMM keeps running.
        record("update_hvf_rollback", SAFE_GUEST, same and ((r["error"] and ("known-good" in r["text"] or "deferred" in r["text"]
                                                                            or "not restarting" in r["text"]))
                                                           or (not r["error"] and action == "noop")),
               {"reply": short(r["text"], 200), "isError": r["error"], "action": action, "vmmBefore": vmm0,
                "vmmAfter": state().get("vmmPID")},
               "on a machine with nothing to roll back to, refuses (or is a no-op) and the same VMM keeps running", r)
    # --- engines and modes (throwaway runtimes.json) ---
    if has("runtimes"):
        r = call(s, calls, "runtimes", {})
        f = runtimes_file() or {}
        line = next((ln for ln in r["text"].splitlines() if ln[2:].startswith("hvf\t")), "")
        record("runtimes", SAFE_FILES, not r["error"] and line.startswith("*") and "\tenabled" in line and f.get("default") == "hvf",
               {"hvfLine": line, "fileDefault": f.get("default")}, "lists hvf as the enabled default, as runtimes.json says", r)
    if has("runtime_set_default"):
        r = call(s, calls, "runtime_set_default", {"name": "sandbox"})
        f1 = (runtimes_file() or {}).get("default")
        m = call(s, calls, "runtime_mode", {}) if "runtime_mode" in names else {"parsed": {}}
        mode = (m["parsed"] or {}).get("mode") if isinstance(m.get("parsed"), dict) else None
        r2 = call(s, calls, "runtime_mode", {"mode": "container"}) if "runtime_mode" in names else {"error": True}
        f2 = (runtimes_file() or {}).get("default")
        record("runtime_set_default", SAFE_FILES, not r["error"] and f1 == "sandbox", {"reply": r["text"], "fileDefault": f1},
               "sets the default engine: runtimes.json says sandbox", r)
        if "runtime_mode" in names:
            known.add("runtime_mode")
            record("runtime_mode", SAFE_FILES, mode == "sandbox" and not r2["error"] and f2 == "hvf",
                   {"modeWhileSandbox": mode, "afterSwitch": f2}, "shows mode sandbox, then switching to container "
                   "makes runtimes.json's default hvf again", {"show": m, "switch": r2})
    if has("runtime_update"):
        def engines():
            e = (runtimes_file() or {}).get("engines") or {}
            return e if isinstance(e, dict) else {x.get("name"): x for x in e if isinstance(x, dict)}
        # sandbox: an engine the throwaway file names, enabled, and not the default.
        name = "sandbox"
        was = (engines().get(name) or {}).get("enabled")
        r = call(s, calls, "runtime_update", {"name": name, "enabled": False})
        now = (engines().get(name) or {}).get("enabled")
        r2 = call(s, calls, "runtime_update", {"name": name, "enabled": True})
        back = (engines().get(name) or {}).get("enabled")
        record("runtime_update", SAFE_FILES, was is True and not r["error"] and now is False and not r2["error"] and back is True,
               {"engine": name, "was": was, "afterDisable": now, "afterEnable": back},
               "disables the sandbox engine in runtimes.json, then enables it again", {"disable": r, "enable": r2})
    if has("volume_policy_set"):
        r = call(s, calls, "volume_policy_set", {"mode": "goldens", "goldens": [f"b25-golden-{RUN}"], "cache": "off"})
        try:
            vp = json.load(open(VOLUME_POLICY))
        except (OSError, ValueError):
            vp = None
        txt = json.dumps(vp or {})
        record("volume_policy_set", SAFE_FILES, not r["error"] and vp and f"b25-golden-{RUN}" in txt and "goldens" in txt,
               {"reply": r["text"], "file": vp}, "writes mode goldens and the golden volume to the policy file", r)
    if has("volume_policy"):
        r = call(s, calls, "volume_policy", {})
        record("volume_policy", SAFE_FILES, not r["error"] and "cloneMode: goldens" in r["text"] and f"b25-golden-{RUN}" in r["text"],
               {"reply": r["text"].splitlines()[:3]}, "shows the policy file as written", r)
    if has("build_cache_stats"):
        empty = os.path.join(ROOT, "build-cache-empty")
        r = call(s, calls, "build_cache_stats", {"path": empty})
        record("build_cache_stats", SAFE_FILES, not r["error"] and "entries: 0" in r["text"] and not os.listdir(empty),
               {"reply": r["text"].splitlines()[:2]}, "scans the (empty) directory named: 0 entries, nothing written", r)
    # --- k8s, guarded by the throwaway config (MICROPOD_K8S_CONFIG) ---
    if has("k8s_enable"):
        r = call(s, calls, "k8s_enable", {"cpus": 2})
        cfg = json.load(open(K8S_CONFIG)) if os.path.exists(K8S_CONFIG) else {}
        record("k8s_enable", SAFE_FILES, not r["error"] and cfg.get("enabled") is True,
               {"reply": r["text"], "file": cfg}, "enables the engine in the throwaway k8s config (no cluster made)", r)
    if has("k8s_disable"):
        r = call(s, calls, "k8s_disable", {})
        cfg = json.load(open(K8S_CONFIG)) if os.path.exists(K8S_CONFIG) else {}
        record("k8s_disable", SAFE_FILES, not r["error"] and cfg.get("enabled") is False,
               {"reply": r["text"], "file": cfg}, "disables it again in that config", r)
    for tool, args in (("k8s_status", {}), ("k8s_images", {}), ("k8s_load_image", {"ref": IMAGE}), ("k8s_down", {})):
        if not has(tool):
            continue
        r = call(s, calls, tool, args)
        if tool == "k8s_status":
            record(tool, SAFE_FILES, not r["error"] and "enabled=false" in r["text"], {"reply": r["text"].splitlines()[:2]},
                   "reports the throwaway config's engine as disabled", r)
        else:
            record(tool, REFUSAL, r["error"] and "disabled" in r["text"], {"reply": r["text"]},
                   "refuses while the engine is disabled (nothing touched)", r)
    # --- no backing service in a throwaway environment: a clean refusal ---
    for tool, args, needle in (("share_list", {}, "shared-fs daemon is not running"),
                               ("share_mount", {"src": WS}, "shared-fs daemon is not running"),
                               ("share_unmount", {"id": "b25"}, "shared-fs daemon is not running"),
                               ("share_sync", {"id": "b25"}, "shared-fs daemon is not running"),
                               ("share_gc", {}, "shared-fs daemon is not running"),
                               ("update_check", {}, "not running"), ("update_status", {}, "not running")):
        if not has(tool):
            continue
        r = call(s, calls, tool, args)
        record(tool, REFUSAL, r["error"] and needle in r["text"], {"reply": r["text"]},
               "refuses cleanly with no daemon/app behind it (throwaway socket)", r)
    # --- the standalone sandbox (throwaway MICROPOD_SANDBOX_ROOT) ---
    if has("sandbox_status"):
        r = call(s, calls, "sandbox_status", {})
        p = r["parsed"] if isinstance(r["parsed"], dict) else {}
        record("sandbox_status", SAFE_SANDBOX, not r["error"] and p.get("root") == SANDBOX_ROOT,
               {"root": p.get("root"), "ready": p.get("standaloneReady"), "kernelOrigin": p.get("kernelOrigin"),
                "kernelPath": p.get("kernelPath")}, "reports the throwaway sandbox root", r)
    ckpt = f"b25-{RUN}-ckpt"
    if has("sandbox_run"):
        r = call(s, calls, "sandbox_run", {"command": f"echo b25-sbx-{RUN}; uname -s", "image": IMAGE, "memory": 512},
                 timeout=900)
        record("sandbox_run", SAFE_SANDBOX, not r["error"] and r["text"].startswith("exit 0") and f"b25-sbx-{RUN}" in r["text"]
               and "Linux" in r["text"], {"reply": short(r["text"], 300)}, "runs the command in a fresh micro-VM: "
               "exit 0, its output, a Linux kernel", r)
    if has("sandbox_checkpoint_create"):
        r = call(s, calls, "sandbox_checkpoint_create", {"name": ckpt, "command": "echo b25 > /b25-ckpt", "image": IMAGE,
                                                         "memory": 512}, timeout=900)
        cdir = os.path.join(SANDBOX_ROOT, "checkpoints")
        on_disk = sorted(os.listdir(cdir)) if os.path.isdir(cdir) else []
        record("sandbox_checkpoint_create", SAFE_SANDBOX, not r["error"] and any(ckpt in x for x in on_disk),
               {"reply": short(r["text"], 200), "checkpointsOnDisk": on_disk}, "keeps the disk as a named checkpoint "
               "under the throwaway sandbox root", r)
    if has("sandbox_checkpoints"):
        r = call(s, calls, "sandbox_checkpoints", {})
        cdir = os.path.join(SANDBOX_ROOT, "checkpoints")
        on_disk = sorted(os.listdir(cdir)) if os.path.isdir(cdir) else []
        record("sandbox_checkpoints", SAFE_SANDBOX, not r["error"] and (ckpt in r["text"]) == any(ckpt in x for x in on_disk)
               and on_disk, {"reply": short(r["text"], 200), "onDisk": on_disk}, "lists the checkpoints on disk", r)
    if has("sandbox_checkpoint_delete"):
        r = call(s, calls, "sandbox_checkpoint_delete", {"name": ckpt})
        cdir = os.path.join(SANDBOX_ROOT, "checkpoints")
        on_disk = sorted(os.listdir(cdir)) if os.path.isdir(cdir) else []
        record("sandbox_checkpoint_delete", SAFE_SANDBOX, not r["error"] and not any(ckpt in x for x in on_disk),
               {"reply": short(r["text"], 200), "onDisk": on_disk}, "removes that checkpoint from disk", r)
    # --- read-only against the host's Apple runtime / app state: answered, not verifiable here ---
    for tool in sorted(HOST_READ_TOOLS & names):
        args = {"kind": "system", "range": "15m"} if tool == "metrics_history" else (
            {"name": "b25-none"} if tool == "compose_ps" else {})
        r = call(s, calls, tool, args, timeout=120)
        results[tool] = {"class": HOST_READ, "ok": None, "isError": r["error"], "reply": short(r["text"], 160)}
    for tool in sorted(set(UNSAFE_TOOLS) & names):
        results[tool] = {"class": UNSAFE, "ok": None, "reason": UNSAFE_TOOLS[tool]}
    if has("cache_prune"):
        results["cache_prune"] = {"class": SAFE_GUEST, "ok": None, "note": "verified by M-PRUNE-*"}
    unclassified = sorted(names - set(results))
    stale = sorted(known - names - {"cache_prune"})
    check("M04", "every listed tool was either called and verified here, called read-only against the host, or is "
          "named unsafe with a reason (a new tool must be classified)", {"unclassified": unclassified, "stale": stale},
          {"unclassified": [], "stale": []}, ev=evidence("M04-coverage", results))
    return results


def mcp_invalid(s, by, calls):
    """Invalid arguments: an unknown key, a wrong type, a missing required
    argument. Each must be a tool error naming the problem, and a refused
    mutation must leave the guest as it was."""
    failures = {}
    tried = 0
    for name, tool in sorted(by.items()):
        sch = tool.get("inputSchema") or {}
        props = sch.get("properties") or {}
        cases = [("unknown", {"b25_bogus": 1}, "unknown argument")]
        req = sch.get("required") or []
        if req:
            cases.append(("missing", {}, f"requires {req[0]}"))
        if name not in UNSAFE_TOOLS:
            for pname, p in props.items():
                v = bad_value(p)
                if v is not None:
                    args = {k: ("b25" if (props[k].get("type") == "string") else 1) for k in req if k != pname}
                    args[pname] = v
                    want = "Unknown" if p.get("enum") else pname
                    cases.append((f"type:{pname}", args, want))
                    break
        for label, args, needle in cases:
            tried += 1
            r = call(s, calls, name, args, timeout=60)
            if not (r["error"] and needle.lower() in r["text"].lower()):
                failures[f"{name} {label}"] = {"args": args, "isError": r["error"], "reply": short(r["text"], 200)}
    # Protocol-level refusals.
    r = s.request("tools/call", {"name": "b25_no_such_tool", "arguments": {}})
    if (r.get("error") or {}).get("code") != -32601:
        failures["unknown tool"] = r
    r = s.request("tools/call", {"arguments": {}})
    if (r.get("error") or {}).get("code") != -32602:
        failures["malformed call"] = r
    tried += 2
    check("M-INV", f"{tried} invalid calls (unknown argument, wrong type or range, missing required, unknown tool, "
          "malformed call) were each refused with an error naming the problem", failures, {},
          ev=evidence("M-INV-failures", failures))
    # Refused mutations change nothing in the guest.
    c = f"b25-{RUN}-inv"
    ok, _ = guest_run(c, ["sleep", "600"], labels={"b25.run": RUN})
    pol0 = guest_caches(stats=False).get("policy") or {}
    inv0 = unit_facts(guest_caches())
    rt0 = runtimes_file()
    refusals = [call(s, calls, "stop", {"id": 12}), call(s, calls, "kill", {"id": c, "signal": 9}),
                call(s, calls, "cache_policy_set", {"max_age_days": -1}),
                call(s, calls, "cache_policy_set", {"max_age_days": 3, "b25_bogus": True}),
                call(s, calls, "cache_prune", {"apply": "perhaps"}),
                call(s, calls, "cache_prune", {"apply": True}),  # an unselected apply needs all: true
                call(s, calls, "runtime_set_default", {"name": 7})]
    time.sleep(1)
    after = {"running": ((guest_inspect(c) or {}).get("State") or {}).get("Running"),
             "policy": guest_caches(stats=False).get("policy") or {}, "units": unit_facts(guest_caches()),
             "runtimes": runtimes_file()}
    check("M-INV-NOEFFECT", "refused mutating calls (stop/kill with bad arguments, an out-of-range or unknown-key "
          "policy, a non-boolean apply, an unselected apply, a numeric runtime name) left the guest and runtimes.json "
          "unchanged", {"allRefused": all(r["error"] for r in refusals), "stillRunning": after["running"],
                        "policySame": after["policy"] == pol0, "unitsSame": after["units"] == inv0,
                        "runtimesSame": after["runtimes"] == rt0},
          {"allRefused": True, "stillRunning": True, "policySame": True, "unitsSame": True, "runtimesSame": True},
          ok=ok and all(r["error"] for r in refusals) and after["running"] and after["policy"] == pol0 and
          after["units"] == inv0 and after["runtimes"] == rt0 and pol0,
          ev=evidence("M-INV-NOEFFECT", {"refusals": refusals, "before": {"policy": pol0, "units": inv0}, "after": after}))
    guest("DELETE", f"/containers/{c}?force=1")


def mcp_prune(s, calls):
    """cache_prune is a dry run unless apply: true."""
    scope = f"b25p-{RUN}"
    c = f"b25-{RUN}-seed"
    script = ("mkdir -p /micropod/cache/gomod/b25 && head -c 40000 /dev/urandom > /micropod/cache/gomod/b25/a && "
              "head -c 30000 /dev/urandom > /micropod/cache/gomod/b25/b && sync")
    ok, d = guest_run(c, ["sh", "-c", script], labels={"io.micropod.cache.scope": scope, "b25.run": RUN})
    wait_for(lambda: ((guest_inspect(c) or {}).get("State") or {}).get("Status") == "exited", 60, 0.3)
    guest("DELETE", f"/containers/{c}?force=1")

    def units():
        return {k: v for k, v in unit_facts(guest_caches()).items() if k.startswith(scope + "/")}
    base = wait_for(lambda: (lambda u: u if u and not any(
        x.get("inUse") or x.get("dirty") for x in (guest_caches().get("units") or []) if x.get("scope") == scope) else None)(units()), 60, 0.5) or units()
    check("M-PRUNE-SEED", "a container seeded a cache scope the guest now lists", base, "a non-empty scope", ok=bool(base))
    replies = {}
    for label, args in (("{}", {}), ("dry_run:true", {"dry_run": True}), ('dry_run:"true"', {"dry_run": "true"}),
                        ("scope", {"scope": scope}), ("scope+max_bytes", {"scope": scope, "max_bytes": 1})):
        if label == "{}" and "prune-apply" in SABOTAGE:
            log("SABOTAGE prune-apply: the first dry run is sent as apply: true")
            args = {"apply": True, "scope": scope}
        r = call(s, calls, "cache_prune", args, timeout=600)
        p = r["parsed"] if isinstance(r["parsed"], dict) else {}
        replies[label] = {"isError": r["error"], "dryRun": p.get("dryRun"), "evicted": len(p.get("evicted") or p.get("units") or []),
                          "reply": short(r["text"], 200)}
    after_dry = units()
    check("M-PRUNE-DRY", "cache_prune without apply: true ({}, dry_run true, \"true\", a scope, a budget) is a dry run "
          "every time: each reply says dryRun and the guest still holds the scope byte for byte",
          {"replies": {k: (v["isError"], v["dryRun"]) for k, v in replies.items()}, "same": after_dry == base},
          "dryRun true ×5, units unchanged",
          ok=base and after_dry == base and all(not v["isError"] and v["dryRun"] is True for v in replies.values()),
          ev=evidence("M-PRUNE-DRY", {"base": base, "after": after_dry, "replies": replies}))
    r = call(s, calls, "cache_prune", {"apply": True, "scope": scope}, timeout=600)
    wait_for(lambda: not units(), 10, 0.5)
    left = units()
    check("M-PRUNE-APPLY", "cache_prune apply: true with that scope evicts it in the guest",
          {"isError": r["error"], "leftInGuest": left, "reply": short(r["text"], 200)}, "the scope's units gone",
          ok=not r["error"] and base and not left)


def mcp_replay():
    """A mutation whose reply is lost is not resent, over the socket or TCP."""
    rep_sock = os.path.join(ROOT, "mcp-rep.sock")
    rules_exec = {"POST /api/micropod.v1.ContainerService/Exec":
                  "replay" if "replay-proxy" in SABOTAGE else "drop-after"}
    if "replay-proxy" in SABOTAGE:
        log("SABOTAGE replay-proxy: the proxy sends the Exec to the API twice")
    px = Proxy("replay-unix", ("unix", rep_sock), ("unix", API_SOCK), rules_exec).start()
    pt = Proxy("replay-tcp", ("tcp", PROXY_PORT), ("tcp", API_PORT)).start()
    c = f"b25-{RUN}-rp"
    out = os.path.join(OUT_HOST, f"replay-{RUN}.txt")
    rc, o, e = cli("run", "--runtime", "hvf", "--name", c, "-v", f"{OUT_HOST}:/out", IMAGE, "--", "sleep", "600")
    wait_for(lambda: ((guest_inspect(c) or {}).get("State") or {}).get("Running"), 30, 0.2)
    s = mcp_open(mcp_env(sock=rep_sock, port=PROXY_PORT))
    calls = []
    try:
        r = call(s, calls, "exec", {"id": c, "command": f"echo once >> /out/replay-{RUN}.txt"}, timeout=300)
        time.sleep(2)
        lines = open(out).read().splitlines() if os.path.exists(out) else None
        ex_unix = px.routes("POST /api/micropod.v1.ContainerService/Exec")
        ex_tcp = pt.routes("POST /api/micropod.v1.ContainerService/Exec")
        check("M-REPLAY-EXEC", "an exec whose reply the socket drops (the daemon ran it) is reported as not resent, "
              "reached the API once, never over TCP, and ran exactly once in the container",
              {"isError": r["error"], "saysNotResent": "not resent" in r["text"], "socketExecs": len(ex_unix),
               "tcpExecs": len(ex_tcp), "linesInContainerFile": lines},
              {"isError": True, "saysNotResent": True, "socketExecs": 1, "tcpExecs": 0, "linesInContainerFile": ["once"]},
              ok=r["error"] and "not resent" in r["text"] and len(ex_unix) == 1 and not ex_tcp and lines == ["once"] and rc == 0,
              ev=evidence("M-REPLAY-EXEC", {"reply": r, "proxyUnix": px.snapshot(), "proxyTcp": pt.snapshot()}))
        px.rules = {"PUT /v1/caches/policy": "drop-before"}
        pol0 = (guest_caches(stats=False).get("policy") or {}).get("maxAgeDays")
        r = call(s, calls, "cache_policy_set", {"max_age_days": 77})
        time.sleep(1.5)
        pol1 = (guest_caches(stats=False).get("policy") or {}).get("maxAgeDays")
        cfg = (json.load(open(MACHINE_JSON)).get("cache") or {}).get("maxAgeDays")
        pu, ptc = px.routes("PUT /v1/caches/policy"), pt.routes("PUT /v1/caches/policy")
        check("M-REPLAY-POLICY", "a policy write whose connection dies before the daemon reads it is reported, not "
              "resent over TCP, and the guest's policy is unchanged",
              {"isError": r["error"], "socketPuts": len(pu), "tcpPuts": len(ptc), "guestMaxAgeDays": [pol0, pol1],
               "machineJson": cfg}, {"isError": True, "socketPuts": 1, "tcpPuts": 0, "guestMaxAgeDays": "unchanged"},
              ok=r["error"] and len(pu) == 1 and not ptc and pol0 == pol1 and cfg != 77 and pol0 is not None,
              ev=evidence("M-REPLAY-POLICY", {"reply": r, "proxyUnix": px.snapshot(), "proxyTcp": pt.snapshot()}))
    finally:
        mcp_close(s)
        px.stop()
        pt.stop()
        guest("DELETE", f"/containers/{c}?force=1")


def nearest_rank(sorted_us, q):
    """The nearest-rank quantile, as cpbench computes it (p95 of 200 is the 190th)."""
    if not sorted_us:
        return None
    rank = max(0, min(len(sorted_us) - 1, -(-int(q * 1000) * len(sorted_us) // 1000) - 1))
    return round(sorted_us[rank], 1)


def mcp_latency():
    s = mcp_open()
    try:
        res = {}
        for tool in ("cache_policy", "runtime_mode"):
            lat = []
            errs = 0
            for i in range(SAMPLES + 20):
                t = time.perf_counter()
                r = s.call(tool, {})
                d = (time.perf_counter() - t) * 1e6
                if i >= 20:
                    lat.append(d)
                    errs += 1 if r["error"] else 0
            lat.sort()
            q = {p: nearest_rank(lat, p) for p in (.5, .95, .99)}
            res[tool] = {"n": len(lat), "p50Us": q[.5], "p95Us": q[.95], "p99Us": q[.99], "errors": errs}
            TABLE.append({"case": f"mcp-{tool}", "rpc": f"MCP tools/call {tool} (stdio → api.sock)", "containers": None,
                          "transport": "stdio+unix", "codec": "json-rpc/json", "concurrency": 1, "n": len(lat),
                          "errors": errs, "p50Us": q[.5], "p95Us": q[.95], "p99Us": q[.99],
                          "maxUs": round(lat[-1], 1) if lat else None, "targetP95Us": TARGET_US, "source": SRC_MCP_WIRE})
        METRICS["mcpLatency"] = res
        r = res["cache_policy"]
        check("M-LAT", "MCP tool latency (cache_policy, stdio → API): p95 < 1 ms over >= 200 warm calls",
              res, f"p95 < {TARGET_US:.0f} µs, n >= {SAMPLES_MIN}, no errors",
              ok=r["n"] >= SAMPLES_MIN and not r["errors"] and r["p95Us"] < TARGET_US and
              res["runtime_mode"]["n"] >= SAMPLES_MIN and res["runtime_mode"]["p95Us"] < TARGET_US, source=SRC_MCP_WIRE)
    finally:
        mcp_close(s)


# =================================================================================================
def attribute_children():
    """API children the census saw during each measured case, and per call."""
    evs = census_events()
    starts = sorted(e["t"] for e in evs if e.get("event") == "child" and e.get("watched") == "api")
    for r in TABLE:
        w = r.get("window") or [None, None]
        if w[0] is None or w[1] is None:
            continue
        n = bisect.bisect_right(starts, w[1]) - bisect.bisect_left(starts, w[0])
        r["apiChildren"] = n
        r["apiChildrenPerCall"] = round(n / r["calls"], 2) if r.get("calls") else None


def write_table():
    attribute_children()
    cols = ["case", "rpc", "containers", "transport", "codec", "concurrency", "n", "errors", "p50Us", "p95Us", "p99Us",
            "maxUs", "firstCallUs", "dials", "requests", "apiChildrenPerCall", "targetP95Us"]
    with open(RECEIPT / "latency.tsv", "w") as f:
        f.write("\t".join(cols) + "\n")
        for r in TABLE:
            f.write("\t".join("" if r.get(c) is None else str(r.get(c)) for c in cols) + "\n")


def write_result(started, error):
    try:
        versions = json.load(open(RECEIPT / "versions.json"))
    except (OSError, ValueError):
        versions = {}
    passed = sum(1 for r in RESULTS if r["ok"])
    failed = [r["id"] for r in RESULTS if not r["ok"]]
    complete = all(s in SECTIONS for s in ALL_SECTIONS) and not SABOTAGE and SAMPLES >= SAMPLES_MIN
    result = {
        "gate": "B25 control-plane", "run": RUN, "root": ROOT, "apiSocket": API_SOCK, "apiPort": API_PORT,
        "versions": versions, "receipt": str(RECEIPT), "sections": SECTIONS, "sabotage": SABOTAGE,
        "samplesPerCase": SAMPLES, "seconds": round(time.time() - started, 1),
        "checks": len(RESULTS), "passed": passed, "failed": len(failed), "failedIds": failed,
        "harnessError": error, "metrics": METRICS, "latencyTable": TABLE, "windows": WINDOWS, "results": RESULTS,
        "complete": complete,
        "verdict": ("pass" if complete else "partial") if not failed and not error and RESULTS else "fail",
    }
    tmp = RECEIPT / "result.json.tmp"
    tmp.write_text(json.dumps(result, indent=2, default=str))
    os.replace(tmp, RECEIPT / "result.json")
    with open(RECEIPT / "checks.tsv", "w") as f:
        for r in RESULTS:
            f.write("\t".join([r["id"], "pass" if r["ok"] else "fail", r["section"], r["name"], r["got"], r["want"],
                               r.get("source") or ""]) + "\n")
    write_table()
    return result


def on_signal(signum, frame):
    raise SystemExit(f"b25: terminated by signal {signum}")


def main():
    started = time.time()
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGHUP, on_signal)
    for d in (BENCH, SAMPLE_DIR):
        d.mkdir(parents=True, exist_ok=True)
    os.makedirs(OUT_HOST, exist_ok=True)
    os.chmod(OUT_HOST, 0o777)
    WATCHED["api"] = API["pid"]
    write_watch()
    census = subprocess.Popen([sys.executable, os.path.join(HERE, "procwatch.py"), WATCH, str(CENSUS), "1"])
    time.sleep(0.3)
    error = None
    try:
        section_C()
        section("setup")
        if not running():
            rc, out, err = start_machine()
            if rc != 0 or not running():
                raise SystemExit(f"b25: the machine did not start: {err.strip()[-400:]}")
        rc, out, err = cli("pull", "--runtime", "hvf", IMAGE, timeout=600)
        if rc != 0:
            raise SystemExit(f"b25: could not pull {IMAGE}: {err.strip()}")
        if not wait_for(lambda: (lambda st, d: st == 200 and isinstance(d, dict) and d.get("status") == "running")(
                *api("POST", "/api/micropod.v1.SystemService/Ping", {})), 30, 0.25):
            raise SystemExit("b25: the API never reported the machine running")
        end_section("setup")
        section_Z()
        write_result(started, None)
        for name, fn in (("L", section_L), ("T", section_T), ("M", section_M)):
            if name in SECTIONS:
                if not running():
                    start_machine()
                fn()
                write_result(started, None)
        section_Z_final()
    except SystemExit as e:
        error = str(e)
        log(error)
    except Exception as e:  # a harness fault is reported, never a pass
        import traceback
        error = f"harness error in section {SECTION}: {e!r}"
        traceback.print_exc()
    finally:
        census.send_signal(signal.SIGTERM)
        try:
            census.wait(timeout=10)
        except subprocess.TimeoutExpired:
            census.kill()
    result = write_result(started, error)
    failed = result["failedIds"]
    print(f"\n{result['passed']} passed, {len(failed)} failed{' (' + ', '.join(failed) + ')' if failed else ''}"
          f"{'; harness error: ' + error if error else ''}", flush=True)
    if result["verdict"] == "partial":
        print(f"partial run (sections {' '.join(SECTIONS)}{', sabotaged' if SABOTAGE else ''}): not a gate pass",
              flush=True)
    sys.exit(0 if result["verdict"] in ("pass", "partial") else (2 if error else 1))


if __name__ == "__main__":
    main()
