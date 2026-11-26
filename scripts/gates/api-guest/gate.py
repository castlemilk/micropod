#!/usr/bin/env python3
"""B24 gate driver: API-to-guest integration on a throwaway hvf machine.

Run by scripts/gates/api-guest.sh, which installs the machine, starts the
MicropodAPI binary on its own Unix socket and loopback port, exports the
environment read below and tears everything down afterwards. Nothing here is
mocked: each check asks the real MicropodAPI binary (socket and TCP), the
micropod CLI or the MicropodMCP server (stdio JSON-RPC), and compares the
answer with what the guest itself shows, measured from inside a container or
read from the guest engine's own Docker socket.

Sections (B24_SECTIONS, run in this order; default all):
  R  readiness: Ping/GetSystem while never started, running, stopped on
     request and booting (sampled against the guest's own _ping)
  S  cache summary: API, CLI and MCP inventories against file counts and
     sizes measured inside the guest
  P  prune: dry runs (MCP, REST, CLI) change nothing; apply removes what the
     dry run listed and only that
  H  policy hot-apply: default-trust flip and allowed scopes reach the next
     container without a restart, and its plan names the policy digest;
     malformed policies fail closed
  L  listing and waiting: 8 containers in one guest request (by the guest's
     own counter), WaitContainer exit code 7, its cost per poll and its
     timeout, CLI exec exit code
  X  exit codes: orderly stop, VMM --timeout, CLI start timeout, guest crash
     (kernel panic on OOM) and a crash loop; readiness never says running
  F  a frozen guest (VMM SIGSTOP: phase running, _ping unanswered) is not
     ready, is ready again once resumed, and the machine still stops
Z (safety) always runs: every process this gate started serves only the
throwaway root and holds nothing under ~/.micropod.

B24_SABOTAGE (comma list) breaks a precondition on purpose, to show the
checks can fail: prune-extra (grow the unit between dry run and apply),
policy-skip (never send the trust flip), stopped-boots (boot the machine
before the stopped-readiness checks), list-inspect (inspect each container on
the guest while the listing is being counted), guest-blind (the gate cannot
read the guest's cache policy: nothing may pass on a default),
expect-flip:<ID> (invert one check).

A run of fewer than all sections can fail but never passes: with no failed
check its verdict is "partial".
"""

import hashlib
import http.client
import json
import math
import os
import pathlib
import re
import signal
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcpclient import MCPError, MCPSession  # noqa: E402

E = os.environ
ROOT = E["B24_ROOT"]
HVF = E["MICROPOD_HVF_ROOT"]
WS = E["B24_WS"]
SOCK = os.path.join(HVF, "run", "docker.sock")
API_SOCK = E["MICROPOD_API_SOCK"]
API_PORT = int(E["MICROPOD_API_PORT"])
API_PID = int(E.get("B24_API_PID") or 0)
M = E["B24_MICROPOD"]
MCP_BIN = E["B24_MCP"]
RECEIPT = pathlib.Path(E["B24_RECEIPT"])
RUN = E["B24_RUN"]
IMAGE = E.get("B24_IMAGE", "alpine:3.20")
SECTIONS = E.get("B24_SECTIONS", "R S P H L X F").split()
SABOTAGE = [s for s in E.get("B24_SABOTAGE", "").split(",") if s]
FLIP = {s.split(":", 1)[1] for s in SABOTAGE if s.startswith("expect-flip:")}
ALL_SECTIONS = ["R", "S", "P", "H", "L", "X", "F"]
KNOWN_SABOTAGE = {"prune-extra", "policy-skip", "stopped-boots", "list-inspect", "guest-blind"}
for s in SABOTAGE:
    if s not in KNOWN_SABOTAGE and not s.startswith("expect-flip:"):
        sys.exit(f"b24: unknown sabotage mode {s!r}")
for s in SECTIONS:
    if s not in ALL_SECTIONS:
        sys.exit(f"b24: unknown section {s!r}")
RIG_LINK = os.path.expanduser("~/.micropod/docker.sock")
RIG_LINK_BEFORE = E.get("B24_RIG_LINK", "")
HOME_MICROPOD = os.path.realpath(os.path.expanduser("~/.micropod"))
POLICY_FILE = os.path.join(HVF, "run", "guest-config", "cache-policy.json")
MACHINE_JSON = os.path.join(HVF, "machine.json")
OUT_HOST = os.path.join(WS, "b24-out")
LOGS = RECEIPT / "logs"
EVID = RECEIPT / "evidence"

# --- the throwaway boundary, asserted again before anything runs ------------
for path in (ROOT, HVF, WS, API_SOCK):
    real = os.path.realpath(path)
    if not (real.startswith("/private/tmp/") or real.startswith("/tmp/")) or real.startswith(HOME_MICROPOD):
        sys.exit(f"b24: refusing to run: {path} is not under /tmp")
if not os.path.realpath(HVF).startswith(os.path.realpath(ROOT) + "/"):
    sys.exit("b24: refusing to run: the machine root is not inside the throwaway root")
if E.get("MICROPOD_LINK_DOCKER_SOCK") != "0":
    sys.exit("b24: refusing to run: MICROPOD_LINK_DOCKER_SOCK must be 0")

RESULTS = []
METRICS = {}
SECTION = "setup"
COMMANDS = open(LOGS / "commands.log", "a")


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} b24: {msg}", flush=True)


def short(v, n=300):
    s = v if isinstance(v, str) else json.dumps(v, sort_keys=True, default=str)
    return s if len(s) <= n else s[:n] + "…"


def evidence(name, obj):
    p = EVID / f"{name}.json"
    p.write_text(json.dumps(obj, indent=2, sort_keys=True, default=str))
    return str(p.relative_to(RECEIPT))


def check(cid, name, got, want=None, ok=None, ev=None):
    """Records one numbered check. ok defaults to got == want."""
    if ok is None:
        ok = got == want
    ok = bool(ok)
    flipped = cid in FLIP
    if flipped:
        ok = not ok
    RESULTS.append({"id": cid, "section": SECTION, "name": name, "ok": ok, "got": short(got, 600),
                    "want": short(want, 600), "flipped": flipped, "evidence": ev})
    mark = "✓" if ok else "✗"
    extra = "" if ok else f" — got {short(got)}, want {short(want)}"
    print(f"  {mark} [{cid}] {name}{extra}{' (expectation flipped by sabotage)' if flipped else ''}", flush=True)
    return ok


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


def request(method, path, body=None, *, unix=None, port=None, timeout=30):
    try:
        conn = UnixHTTP(unix, timeout) if unix else http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
        headers = {}
        data = None
        if body is not None:
            data = body if isinstance(body, bytes) else (body if isinstance(body, str) else json.dumps(body)).encode()
        if method in ("POST", "PUT", "PATCH") or data is not None:
            headers["Content-Type"] = "application/json"
        conn.request(method, path, body=data, headers=headers)
        r = conn.getresponse()
        raw = r.read()
        conn.close()
        return r.status, raw
    except (OSError, http.client.HTTPException) as e:
        return 0, str(e).encode()


def parse(raw):
    try:
        return json.loads(raw)
    except ValueError:
        return raw.decode(errors="replace")


def api(method, path, body=None, tcp=False, timeout=60):
    st, raw = request(method, path, body, unix=None if tcp else API_SOCK, port=API_PORT if tcp else None, timeout=timeout)
    return st, parse(raw)


def rpc(service, method, body=None, tcp=False, timeout=60):
    return api("POST", f"/api/micropod.v1.{service}/{method}", body if body is not None else {}, tcp, timeout)


def guest(method, path, body=None, timeout=30):
    st, raw = request(method, path, body, unix=SOCK, timeout=timeout)
    return st, parse(raw)


def docker_ping(timeout=1.0):
    st, raw = request("GET", "/_ping", unix=SOCK, timeout=timeout)
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


def mcp():
    return MCPSession(MCP_BIN, dict(E), LOGS / "mcp.jsonl", LOGS / "mcp.stderr")


def wait_for(fn, timeout, interval=0.25):
    deadline = time.time() + timeout
    while True:
        v = fn()
        if v:
            return v
        if time.time() >= deadline:
            return None
        time.sleep(interval)


def sha(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()
    except OSError:
        return "absent"


# --- machine state ---------------------------------------------------------------
def state():
    try:
        return json.load(open(os.path.join(HVF, "run", "state.json")))
    except (OSError, ValueError):
        return {}


def identity():
    s = state()
    return {"vmmPID": s.get("vmmPID"), "supervisorPID": s.get("supervisorPID"), "restartCount": s.get("restartCount"),
            "phase": s.get("phase")}


def our_vmms():
    """micropod-vmm processes of this root (the binary under it on its disk)."""
    p = subprocess.run(["pgrep", "-f", f"^{HVF}/micropod-vmm .*--disk {HVF}/disk.ext4"], capture_output=True, text=True)
    return [int(x) for x in p.stdout.split()]


def running():
    return state().get("phase") == "running" and docker_ping(2)


def set_machine_args(kernel=None, extra=None):
    cfg = json.load(open(MACHINE_JSON))
    if kernel is not None:
        cfg["kernelArguments"] = kernel
    if extra is not None:
        cfg["extraArguments"] = extra
    tmp = MACHINE_JSON + ".b24tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, MACHINE_JSON)


def start_machine(timeout=180):
    rc, out, err = cli("machine", "start", "--timeout", str(timeout), timeout=timeout + 30)
    return rc, out, err


def stop_machine():
    return cli("machine", "stop", timeout=120)


# --- readiness -----------------------------------------------------------------------
def readiness(call="Ping", tcp=False):
    st, d = rpc("SystemService", call, {}, tcp=tcp, timeout=15)
    if st != 200 or not isinstance(d, dict):
        return {"status": f"<http {st}>", "features": [], "state": None, "detail": short(d), "backend": None}
    comps = d.get("components") or []
    comp = next((c for c in comps if c.get("name") == "hvf-machine"), {}) or {}
    status = d.get("status") if call == "Ping" else (d.get("status") or {}).get("status")
    backend = d.get("runtimeBackend") if call == "Ping" else (d.get("status") or {}).get("runtimeBackend")
    return {"status": status, "features": d.get("features") or [], "state": comp.get("state"),
            "detail": comp.get("detail"), "backend": backend}


class Sampler(threading.Thread):
    """Ping and GetSystem in turn, each bracketed by the guest's own _ping."""

    def __init__(self, interval=0.03):
        super().__init__(daemon=True)
        self.interval = interval
        self.samples = []
        self.halt = threading.Event()
        self.t0 = time.time()

    def run(self):
        n = 0
        while not self.halt.is_set():
            call = "Ping" if n % 2 == 0 else "GetSystem"
            n += 1
            before = docker_ping(0.5)
            r = readiness(call)
            after = docker_ping(0.5)
            self.samples.append({"t": round(time.time() - self.t0, 3), "call": call, "status": r["status"],
                                 "detail": r["detail"], "features": r["features"], "guestBefore": before,
                                 "guestAfter": after, "phase": state().get("phase")})
            time.sleep(self.interval)

    def stop(self):
        self.halt.set()
        self.join(timeout=30)
        return self.samples


def saw_guest_down(samples):
    """Samples taken while the guest answered _ping neither just before nor
    just after: without one, a 'never said running while down' check has
    measured nothing."""
    return [s for s in samples if not s["guestBefore"] and not s["guestAfter"]]


def false_running(samples):
    """Samples that said running while the guest answered _ping neither just before nor just after."""
    return [s for s in samples if s["status"] == "running" and not s["guestBefore"] and not s["guestAfter"]]


def ready_features_while_not_running(samples):
    return [s for s in samples if s["status"] != "running" and ({"caches-v2", "buildkit"} & set(s["features"]))]


# --- containers ---------------------------------------------------------------------------
def inspect(name):
    st, d = guest("GET", f"/containers/{name}/json")
    return d if st == 200 and isinstance(d, dict) else None


def wait_exit(name, timeout=240):
    def done():
        d = inspect(name)
        return d if d and d.get("State", {}).get("Status") in ("exited", "dead") else None
    return wait_for(done, timeout, 0.2)


def job(name, script, labels=(), timeout=240, keep=False):
    """Runs `script` (sh) in a new container created with the micropod CLI;
    returns (exit code or None, output, guest inspect). Output goes to a
    file in the machine workspace, written last with its exit status. The
    container is removed afterwards unless `keep` (then: b24-<run>-<name>)."""
    cname = f"b24-{RUN}-{name}"
    body = (f"exec >/out/.{cname}.tmp 2>&1; ( {script} ); rc=$?; echo \"B24-RC $rc\"; "
            f"mv /out/.{cname}.tmp /out/{cname}.out")
    args = ["run", "--runtime", "hvf", "--name", cname]
    for label in labels:
        args += ["--label", label]
    args += ["-v", f"{OUT_HOST}:/out", IMAGE, "--", "sh", "-c", body]
    rc, out, err = cli(*args)
    if rc != 0:
        return None, f"micropod run exited {rc}: {err.strip()[-400:]}", None
    ins = wait_exit(cname, timeout)
    res = os.path.join(OUT_HOST, f"{cname}.out")
    text = wait_for(lambda: open(res).read() if os.path.exists(res) else None, 10, 0.1) or ""
    m = re.search(r"B24-RC (\d+)", text)
    code = int(m.group(1)) if m else None
    (EVID / "containers").mkdir(exist_ok=True)
    (EVID / "containers" / f"{name}.out").write_text(text)
    if ins:
        (EVID / "containers" / f"{name}.inspect.json").write_text(json.dumps(ins, indent=2))
    if not keep:
        cli("rm", "--force", cname)
    return code, text, ins


def writer(spec):
    """A script writing spec {store-subpath: [sizes]} below /micropod/cache."""
    lines = []
    for sub, sizes in spec.items():
        lines.append(f"mkdir -p /micropod/cache/{sub}/b24")
        for i, size in enumerate(sizes):
            lines.append(f"head -c {size} /dev/urandom > /micropod/cache/{sub}/b24/f{RUN}-{i}-{size}")
    return " && ".join(lines)


MEASURE = r"""
for d in {subs}; do
  p=/micropod/cache/$d
  if [ -d "$p" ]; then
    find "$p" -type f -exec stat -c '%s %b %B' {{}} + 2>/dev/null |
      awk -v d="$d" 'BEGIN {{ n = 0; l = 0; b = 0 }} {{ n++; l += $1; x = $2 * $3; if (x > 0) b += x; else b += $1 }} END {{ printf "FACT %s %d %d %d\n", d, n, l, b }}'
  else
    echo "FACT $d absent"
  fi
done
"""


def measure(scope, subs, name):
    """What a trusted container of `scope` finds in each store subpath:
    {sub: (files, logical bytes, disk bytes)} or {sub: None} when absent."""
    code, text, _ = job(name, MEASURE.format(subs=" ".join(subs)),
                        labels=[f"io.micropod.cache.scope={scope}", "io.micropod.cache.trust=trusted"])
    facts = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] == "FACT":
            facts[parts[1]] = None if parts[2] == "absent" else tuple(int(x) for x in parts[2:5])
    return code, facts


def inventory(tcp=False):
    st, d = api("GET", "/v1/caches", tcp=tcp, timeout=60)
    return d if st == 200 and isinstance(d, dict) else {"error": short(d), "status": st}


def unit_facts(units, scopes=None):
    """{scope/unit: (files, logicalBytes, bytes)} for comparison across surfaces."""
    out = {}
    for u in units or []:
        if scopes and u.get("scope") not in scopes:
            continue
        out[f"{u['scope']}/{u['unit']}"] = (u.get("files"), u.get("logicalBytes"), u.get("bytes"))
    return out


def sub_of(u):
    return u["path"].split("/", 2)[2]  # scopes/<scope>/<sub>


def wait_clean(scopes, timeout=90):
    """Until no unit of `scopes` is in use or marked dirty by the crash fence."""
    def clean():
        inv = inventory()
        units = [u for u in inv.get("units") or [] if u.get("scope") in scopes]
        return inv if units and not any(u.get("dirty") or u.get("inUse") for u in units) else None
    return wait_for(clean, timeout, 0.5)


def guest_policy():
    if "guest-blind" in SABOTAGE:
        return {}
    st, d = guest("GET", "/micropod/caches?stats=0", timeout=10)
    return d if st == 200 and isinstance(d, dict) else {}


def guest_trust():
    """The default tier in the guest's own policy answer, or None when the
    guest gave no policy (unreachable, an error, no digest). The guest omits
    defaultTrust when it is trusted; only a real answer may stand for that."""
    gp = guest_policy()
    pol = gp.get("policy")
    if not isinstance(pol, dict) or not gp.get("policyDigest"):
        return None
    return pol.get("defaultTrust") or "trusted"


def time_until(pred, timeout=10, interval=0.05, since=None):
    """Seconds from `since` (default now) until pred holds, else None. Pass
    the time a request was sent as `since`, so the request itself counts."""
    t = since if since is not None else time.time()
    ok = wait_for(pred, timeout, interval)
    return round(time.time() - t, 3) if ok else None


def plan(ins):
    c = (ins or {}).get("MicropodCache") or {}
    gm = (c.get("tools") or {}).get("gomod") or {}
    # The guest omits trust for a trusted plan; no plan at all is not "trusted".
    trust = (c.get("trust") or "trusted") if c.get("tools") else None
    return {"trust": trust, "trustFrom": c.get("trustFrom"), "gomodAccess": gm.get("access"),
            "scope": c.get("scope")}


# =================================================================================================
def section_R():
    global SECTION
    SECTION = "R"
    log("R: readiness while never started, running, stopped on request and booting")
    first = readiness("Ping")
    st0 = state()
    check("R01", "a never-started default machine: Ping reports starting (a start on demand), not running",
          first["status"], "starting", ev=evidence("R01-ping", first))
    up = wait_for(running, 180, 0.25)
    check("R02", "…and that start is real: the machine reaches running (supervisor up, guest answers _ping)",
          bool(up), True, ev=evidence("R02-state", {"before": st0, "after": state()}))
    if not up:
        raise SystemExit("b24: the machine never became ready; nothing else can be measured")
    rc, out, err = cli("pull", "--runtime", "hvf", IMAGE, timeout=600)
    if rc != 0:
        raise SystemExit(f"b24: could not pull {IMAGE} into the machine: {err.strip()}")
    manifest = json.load(open(os.path.join(HVF, "tools", "runner", "manifest.json")))
    for cid, call, tcp in (("R03", "Ping", False), ("R04", "GetSystem", False), ("R05", "Ping", True)):
        r = wait_for(lambda: (lambda x: x if x["status"] == "running" else None)(readiness(call, tcp)), 10, 0.2) or \
            readiness(call, tcp)
        want_feats = {"caches-v2", "buildkit"} if call == "Ping" else set()
        got = (r["status"], r["state"], r["backend"], sorted(want_feats & set(r["features"])))
        check(cid, f"running: {call} over {'TCP' if tcp else 'the socket'} says running, hvf-machine component running"
              + (", advertises caches-v2 and buildkit (the bundle ships both)" if call == "Ping" else ""),
              got, ("running", "running", "hvf", sorted(want_feats)),
              ev=evidence(f"{cid}-{call}", {"readiness": r, "manifest": manifest}))
    with_mcp = mcp()
    try:
        err, text, d = with_mcp.call("rig_health", {})
    finally:
        with_mcp.close()
    hv = (d or {}).get("hvf") or {}
    check("R06", "running: MCP rig_health (through this API) names this root and phase running",
          (err, hv.get("root"), hv.get("phase")), (False, HVF, "running"), ev=evidence("R06-rig-health", d or text))

    rc, out, err = stop_machine()
    check("R07", "`micropod machine stop` exits 0", rc, 0)
    if "stopped-boots" in SABOTAGE:
        log("SABOTAGE stopped-boots: booting the machine again before the stopped-readiness checks")
        start_machine()
    pings = [readiness("Ping"), readiness("GetSystem"), readiness("Ping", tcp=True)]
    check("R08", "stopped on request: Ping, GetSystem and Ping over TCP all say stopped",
          [p["status"] for p in pings], ["stopped"] * 3, ev=evidence("R08-stopped", pings))
    check("R09", "stopped: no caches-v2/buildkit advertised and the hvf-machine component is stopped",
          (sorted({"caches-v2", "buildkit"} & set(pings[0]["features"])), pings[0]["state"]), ([], "stopped"))
    time.sleep(4)
    again = readiness("Ping")
    check("R10", "stopped: those reads did not boot it (phase stopped, no micropod-vmm for this root, Ping still stopped)",
          (state().get("phase"), our_vmms(), again["status"]), ("stopped", [], "stopped"))
    with_mcp = mcp()
    try:
        err, text, d = with_mcp.call("rig_health", {})
    finally:
        with_mcp.close()
    check("R11", "stopped: MCP rig_health reports phase stopped", ((d or {}).get("hvf") or {}).get("phase"), "stopped")

    sampler = Sampler()
    sampler.start()
    time.sleep(0.3)
    proc = subprocess.Popen([M, "machine", "start"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = proc.communicate(timeout=240)
    wait_for(lambda: readiness("Ping")["status"] == "running", 20, 0.2)
    time.sleep(0.5)
    samples = sampler.stop()
    ev = evidence("R12-boot-samples", samples)
    statuses = [s["status"] for s in samples]
    seen = []
    for s in statuses:
        if not seen or seen[-1] != s:
            seen.append(s)
    METRICS["bootStatusSequence"] = seen
    METRICS["bootSamples"] = len(samples)
    check("R12", "booting: `micropod machine start` exits 0", proc.returncode, 0, ev=ev)
    bad = false_running(samples)
    check("R13", "booting: no Ping/GetSystem sample says running while the guest does not answer _ping",
          (len(bad), len(saw_guest_down(samples)) > 0), (0, True), ev=ev)
    first_run = next((i for i, s in enumerate(statuses) if s == "running"), None)
    check("R14", "booting: starting is reported before running (the status sequence while it boots)",
          seen, "contains 'starting' before 'running'",
          ok=first_run is not None and "starting" in statuses[:first_run], ev=ev)
    check("R15", "booting: caches-v2/buildkit are advertised only by samples that say running",
          len(ready_features_while_not_running(samples)), 0, ev=ev)
    check("R16", "booting: it ends running (Ping and the guest agree)",
          (readiness("Ping")["status"], docker_ping()), ("running", True))


def section_F():
    global SECTION
    SECTION = "F"
    log("F: a frozen guest (phase running, _ping unanswered) is not ready; the machine still stops afterwards")
    # Only this root's VMM, by the pid state.json names, proven ours.
    vmm = state().get("vmmPID")
    if not (vmm and vmm in our_vmms()):
        check("F01", "frozen guest: this root's VMM pid is known", vmm, "a micropod-vmm of this root", ok=False)
        return
    os.kill(vmm, signal.SIGSTOP)
    try:
        time.sleep(3.5)  # past the 3 s a _ping answer stands for the guest
        frozen = [readiness("Ping"), readiness("GetSystem")]
        phase = state().get("phase")
        guest_up = docker_ping(1.0)
    finally:
        os.kill(vmm, signal.SIGCONT)
    check("F01", "frozen guest (phase still running, _ping unanswered): Ping and GetSystem are not running "
          "and advertise no caches-v2/buildkit",
          (phase, guest_up, [f["status"] for f in frozen], sorted({"caches-v2", "buildkit"} & set(frozen[0]["features"]))),
          ("running", False, ["not-ready", "not-ready"], []), ev=evidence("F01-frozen", frozen))
    back = wait_for(lambda: readiness("Ping")["status"] == "running", 30, 0.5)
    check("F02", "…and running again once the guest answers", bool(back), True)
    t = time.time()
    rc, out, err = stop_machine()
    took = round(time.time() - t, 1)
    s = state()
    alive = vmm in our_vmms()
    sup_log = os.path.join(HVF, "logs", "supervisor.log")
    try:
        tail = open(sup_log).read()[-3000:]
    except OSError:
        tail = ""
    check("F03", "a VMM that was frozen and resumed still stops: `machine stop` exits 0, phase stopped, VMM gone",
          (rc, s.get("phase"), alive), (0, "stopped", False),
          ev=evidence("F03-stop-after-freeze", {"rc": rc, "stdout": out, "stderr": err, "seconds": took, "state": s,
                                                "vmmStillAlive": alive, "supervisorLogTail": tail}))
    if alive:
        # Recovery, not a check: end this root's VMM ourselves so the
        # supervisor observes the exit and the gate can tear down.
        log(f"recovering: SIGKILL to this root's micropod-vmm pid {vmm} (machine stop could not end it)")
        os.kill(vmm, signal.SIGKILL)
        wait_for(lambda: state().get("phase") == "stopped", 60, 0.5)


def section_Z():
    global SECTION
    SECTION = "Z"
    log("Z: every process this gate started serves only the throwaway root")
    pids = {"api": API_PID, "supervisor": state().get("supervisorPID"), "vmm": state().get("vmmPID")}
    held = {}
    for name, pid in pids.items():
        if not pid:
            held[name] = "no pid"
            continue
        p = subprocess.run(["lsof", "-nP", "-p", str(pid)], capture_output=True, text=True)
        # The receipt (~/.micropod/gates/b24/…) is the one path this gate writes there.
        held[name] = [ln for ln in p.stdout.splitlines()
                      if (HOME_MICROPOD in ln or "/.micropod/" in ln) and str(RECEIPT) not in ln]
    check("Z01", "no process this gate started (API, supervisor, VMM) holds a file under ~/.micropod "
          "(other than this receipt)",
          held, {k: [] for k in pids}, ev=evidence("Z01-lsof", {"pids": pids, "held": held}))
    p = subprocess.run(["lsof", "-nP", "-a", "-p", str(API_PID), "-iTCP", "-sTCP:LISTEN"], capture_output=True, text=True)
    listens = sorted({ln.split()[8] for ln in p.stdout.splitlines()[1:] if len(ln.split()) > 8})
    check("Z02", f"the API listens on loopback port {API_PORT} only",
          listens, sorted({f"127.0.0.1:{API_PORT}", f"[::1]:{API_PORT}"}), ok=listens and all(
              x.endswith(f":{API_PORT}") and (x.startswith("127.0.0.1") or x.startswith("[::1]")) for x in listens))
    st = os.lstat(API_SOCK)
    check("Z03", "the API's own socket is this root's, 0600", (oct(st.st_mode & 0o777), API_SOCK.startswith(ROOT)),
          ("0o600", True))
    s1, h1 = api("GET", "/v1/rig/health")
    s2, h2 = api("GET", "/v1/rig/health", tcp=True)
    check("Z04", "the API (socket and TCP) drives this root's machine",
          ((h1 or {}).get("hvf", {}).get("root") if isinstance(h1, dict) else h1,
           (h2 or {}).get("hvf", {}).get("root") if isinstance(h2, dict) else h2), (HVF, HVF))
    # Without this the "no VMM for this root" checks (R10, F03) and the
    # teardown could be looking for a command line no VMM ever has.
    vmms = our_vmms()
    check("Z05", "the running VMM that state.json names is found by this root's binary and disk on its command line, "
          "and it is the only one", vmms, [pids["vmm"]], ok=bool(pids["vmm"]) and vmms == [pids["vmm"]])


def rig_link():
    try:
        return os.readlink(RIG_LINK)
    except OSError:
        return ""


def section_Z_final():
    global SECTION
    SECTION = "Z"
    now = rig_link()
    check("Z06", "the rig's ~/.micropod/docker.sock link points where it did before this gate started anything",
          now, RIG_LINK_BEFORE, ok=now == RIG_LINK_BEFORE and (not now or not now.startswith(ROOT)))


def section_S():
    global SECTION
    SECTION = "S"
    log("S: the cache summary against what the guest holds")
    scope = f"b24s-{RUN}"
    spec = {"gomod": [3017, 6017, 9017, 12017, 15017], "gobuild": [1000, 70000, 4096], "npm": [12345, 1]}
    code, text, _ = job("s-write", writer(spec), labels=[f"io.micropod.cache.scope={scope}"])
    check("S01", "a container on the machine wrote known files into three of the scope's stores", code, 0)
    wait_clean([scope])
    inv0 = inventory()
    units = [u for u in inv0.get("units") or [] if u.get("scope") == scope]
    subs = sorted({sub_of(u) for u in units})
    code, facts = measure(scope, subs, "s-measure")
    inv = wait_clean([scope]) or inventory()
    units = [u for u in inv.get("units") or [] if u.get("scope") == scope]
    ev = evidence("S-inventory-and-facts", {"inventory": inv, "guestFacts": facts, "spec": spec})
    check("S02", "the API lists the scope with its gomod, gobuild and npm units",
          sorted(u["unit"] for u in units), "⊇ gobuild, gomod, npm",
          ok={"gomod", "gobuild", "npm"} <= {u["unit"] for u in units} and scope in (inv.get("scopes") or {}), ev=ev)
    check("S03", "a measuring container saw every store the API lists", code == 0 and sorted(facts), subs,
          ok=code == 0 and sorted(facts) == subs, ev=ev)
    mismatched = {}
    for u in units:
        f = facts.get(sub_of(u))
        rep = (u.get("files"), u.get("logicalBytes"), u.get("bytes"))
        if f != rep:
            mismatched[u["unit"]] = {"api": rep, "guest": f}
    check("S04", "every unit's files, logical bytes and disk bytes equal what the guest measures (find/stat)",
          mismatched, {}, ev=ev)
    by = {u["unit"]: u for u in units}
    known = {k: (len(v), sum(v)) for k, v in spec.items()}
    got = {k: (by.get(k, {}).get("files"), by.get(k, {}).get("logicalBytes")) for k in spec}
    check("S05", "the written content is reported exactly (file count and logical bytes per store)", got, known, ev=ev)
    all_units = inv.get("units") or []
    t = inv.get("totals") or {}
    sums = {"totalFiles": sum(u["files"] for u in all_units), "totalBytes": sum(u["bytes"] for u in all_units),
            "logicalBytes": sum(u["logicalBytes"] for u in all_units), "unitCount": len(all_units),
            "scopeCount": len(inv.get("scopes") or {}),
            "l0Bytes": sum(u["bytes"] for u in all_units if u.get("layer") != "L1"),
            "l1Bytes": sum(u["bytes"] for u in all_units if u.get("layer") == "L1")}
    check("S06", "the totals are the sum of the units", {k: t.get(k) for k in sums}, sums, ev=ev)
    want = unit_facts(all_units)
    rc, out, err = cli("cache", "status", "--json")
    cs = parse(out.encode()) if rc == 0 else {}
    check("S07", "`micropod cache status --json` reports the same units and totals",
          (unit_facts((cs or {}).get("units") if isinstance(cs, dict) else None),
           {k: (cs.get("totals") or {}).get(k) for k in sums} if isinstance(cs, dict) else None),
          (want, {k: t.get(k) for k in sums}), ev=evidence("S07-cli-status", cs))
    rc, out, err = cli("cache", "ls", "--scope", scope, "--json")
    ls = parse(out.encode()) if rc == 0 else []
    check("S08", "`micropod cache ls --scope` reports the same units for the scope",
          unit_facts(ls if isinstance(ls, list) else None), unit_facts(all_units, {scope}), ev=evidence("S08-cli-ls", ls))
    session = mcp()
    try:
        err, text, d = session.call("cache_status", {})
    finally:
        session.close()
    check("S09", "MCP cache_status reports the same units and totals",
          (err, unit_facts((d or {}).get("units")), {k: ((d or {}).get("totals") or {}).get(k) for k in sums}),
          (False, want, {k: t.get(k) for k in sums}), ev=evidence("S09-mcp-status", d or text))
    tcp = inventory(tcp=True)
    check("S10", "the API over loopback TCP reports what it reports on its socket",
          unit_facts(tcp.get("units")), want)
    gp = guest_policy()
    check("S11", "the summary's policy digest is the guest's own", inv.get("policyDigest"), gp.get("policyDigest"),
          ok=bool(gp.get("policyDigest")) and inv.get("policyDigest") == gp.get("policyDigest"))


def section_P():
    global SECTION
    SECTION = "P"
    log("P: prune dry run changes nothing; apply removes what the dry run listed and only that")
    P, Q = f"b24p-{RUN}", f"b24q-{RUN}"
    for name, scope, spec in (("p-write", P, {"gomod": [20000, 30000, 40000], "gobuild": [5000, 6000]}),
                              ("q-write", Q, {"gomod": [11111, 22222]})):
        code, _, _ = job(name, writer(spec), labels=[f"io.micropod.cache.scope={scope}"])
        check("P01" if scope == P else "P02", f"seeded scope {scope}", code, 0)
    wait_clean([P, Q])
    code_p, g0p = measure(P, ["gomod", "gobuild"], "p-measure0")
    code_q, g0q = measure(Q, ["gomod"], "q-measure0")
    inv0 = wait_clean([P, Q]) or inventory()
    i0 = unit_facts(inv0.get("units"))
    ev0 = inv0.get("evictions") or {}
    target = f"{P}/gomod"
    tu = next((u for u in inv0.get("units") or [] if f"{u['scope']}/{u['unit']}" == target), {})

    session = mcp()
    try:
        err, text, dry = session.call("cache_prune", {"scope": P, "tool": "gomod"})
    finally:
        session.close()
    dry = dry or {}
    acts = sorted((a["scope"], a["unit"], a["action"]) for a in dry.get("actions") or [])
    ev = evidence("P-dry-mcp", {"reply": dry or text, "inventoryBefore": inv0})
    check("P03", "MCP cache_prune without apply is a dry run listing exactly the selected unit",
          (err, dry.get("dryRun"), acts), (False, True, [(P, "gomod", "would-evict")]), ev=ev)
    check("P04", "the dry-run estimate is the unit's reported size", (dry.get("freedBytes"), dry.get("freedFiles")),
          (tu.get("bytes"), tu.get("files")), ok=dry.get("freedBytes") == tu.get("bytes") and tu.get("bytes", 0) > 0
          and dry.get("freedFiles") == tu.get("files"), ev=ev)
    st, rest = api("POST", "/v1/caches/prune", {"scope": P, "tool": "gomod"}, timeout=120)
    rest = rest if isinstance(rest, dict) else {}
    check("P05", "REST POST /v1/caches/prune naming no dryRun is a dry run with the same plan",
          (st, rest.get("dryRun"), sorted((a["scope"], a["unit"]) for a in rest.get("actions") or []), rest.get("freedBytes")),
          (200, True, [(P, "gomod")], dry.get("freedBytes")), ev=evidence("P05-dry-rest", rest))
    rc, out, err = cli("cache", "prune", "--scope", P, "--tool", "gomod", "--dry-run", "--json")
    c = parse(out.encode()) if rc == 0 else {}
    c = c if isinstance(c, dict) else {}
    check("P06", "`micropod cache prune --dry-run` reports the same plan",
          (rc, c.get("dryRun"), sorted((a["scope"], a["unit"]) for a in c.get("actions") or []), c.get("freedBytes")),
          (0, True, [(P, "gomod")], dry.get("freedBytes")), ev=evidence("P06-dry-cli", c or out + err))
    inv1 = wait_clean([P, Q]) or inventory()
    check("P07", "after three dry runs the API inventory is unchanged and nothing was evicted",
          (unit_facts(inv1.get("units")), (inv1.get("evictions") or {}).get("evictedUnits")),
          (i0, ev0.get("evictedUnits")), ev=evidence("P07-inventory-after-dry", inv1))
    code_p1, g1p = measure(P, ["gomod", "gobuild"], "p-measure1")
    code_q1, g1q = measure(Q, ["gomod"], "q-measure1")
    check("P08", "…and the guest still holds every file (measured in the guest)", (g1p, g1q), (g0p, g0q),
          ok=code_p == code_q == code_p1 == code_q1 == 0 and (g1p, g1q) == (g0p, g0q)
          and (g0p.get("gomod") or (0,))[0] == 3)
    wait_clean([P, Q])
    if "prune-extra" in SABOTAGE:
        log("SABOTAGE prune-extra: growing the selected unit between the dry run and the apply")
        job("p-extra", writer({"gomod": [65536, 65536]}), labels=[f"io.micropod.cache.scope={P}"])
        wait_clean([P, Q])
    before_apply = unit_facts(inventory().get("units"))
    session = mcp()
    try:
        err, text, app = session.call("cache_prune", {"scope": P, "tool": "gomod", "apply": True})
    finally:
        session.close()
    app = app or {}
    ev = evidence("P-apply", {"dry": dry, "apply": app or text})
    METRICS["pruneDryRunFreedBytes"] = dry.get("freedBytes")
    METRICS["pruneApplyFreedBytes"] = app.get("freedBytes")
    check("P09", "MCP cache_prune apply evicts exactly the units the dry run listed",
          (err, app.get("dryRun"), sorted((a["scope"], a["unit"], a["action"]) for a in app.get("actions") or [])),
          (False, False, [(s, u, "evicted") for s, u, _ in acts]), ev=ev)
    est, freed = dry.get("freedBytes") or 0, app.get("freedBytes")
    check("P10", "apply freed the dry-run estimate (within 5%)", freed, f"{est} ±5%",
          ok=isinstance(freed, int) and est > 0 and abs(freed - est) <= 0.05 * est, ev=ev)
    inv2 = inventory()
    i2 = unit_facts(inv2.get("units"))
    gone = i2.get(target)
    check("P11", "the API no longer lists content in the pruned unit", gone, "absent or 0 files",
          ok=gone is None or gone[0] == 0, ev=evidence("P11-inventory-after-apply", inv2))
    others0 = {k: v for k, v in before_apply.items() if k != target and k.split("/")[0] in (P, Q)}
    others2 = {k: v for k, v in i2.items() if k != target and k.split("/")[0] in (P, Q)}
    check("P12", "every other unit of both scopes is unchanged", others2, others0)
    code_p2, g2p = measure(P, ["gomod", "gobuild"], "p-measure2")
    code_q2, g2q = measure(Q, ["gomod"], "q-measure2")
    check("P13", "in the guest: the pruned store is empty, the other two stores keep every file",
          (g2p.get("gomod"), g2p.get("gobuild"), g2q.get("gomod")), ((0, 0, 0), g0p.get("gobuild"), g0q.get("gomod")),
          ok=code_p2 == code_q2 == 0 and (g2p.get("gomod") in (None, (0, 0, 0))) and g2p.get("gobuild") == g0p.get("gobuild")
          and g2q.get("gomod") == g0q.get("gomod") and (g0p.get("gobuild") or (0,))[0] == 2
          and (g0q.get("gomod") or (0,))[0] == 2)
    # Reported against actual: what the guest held in that store before the
    # apply (find/stat in a container) less what it holds now.
    held = (g1p.get("gomod") or (0, 0, 0))[2]
    left = (g2p.get("gomod") or (0, 0, 0))[2]
    actual = held - left
    METRICS["pruneActualFreedBytes"] = actual
    check("P17", "apply's reported freed bytes are what actually left the guest's store (measured before − after, within 5%)",
          freed, f"{actual} ±5%", ok=code_p1 == code_p2 == 0 and isinstance(freed, int) and actual > 0
          and abs(freed - actual) <= 0.05 * actual, ev=evidence("P17-actual", {"before": g1p, "after": g2p, "apply": app}))
    ev2 = inventory().get("evictions") or {}
    check("P14", "the eviction counters grew by what apply reported",
          ((ev2.get("evictedUnits") or 0) - (ev0.get("evictedUnits") or 0),
           (ev2.get("evictedBytes") or 0) - (ev0.get("evictedBytes") or 0)),
          (app.get("evictedUnits"), app.get("freedBytes")))
    snap = unit_facts(inventory().get("units"))
    st, body = api("POST", "/v1/caches/prune", {"dryRun": False}, timeout=60)
    after = unit_facts(inventory().get("units"))
    check("P15", "REST apply with no selector is refused (400) and evicts nothing", (st, after == snap), (400, True),
          ev=evidence("P15-unselected-apply", body))
    session = mcp()
    try:
        err, text, _ = session.call("cache_prune", {"scope": Q, "dry_run": False})
    finally:
        session.close()
    check("P16", "MCP cache_prune {dry_run: false} without apply is refused and evicts nothing",
          (err, unit_facts(inventory().get("units")) == after), (True, True), ev=evidence("P16-mcp-dry-false", text))


def section_H():
    global SECTION
    SECTION = "H"
    log("H: policy hot-apply to the next container, no restart; malformed policies fail closed")
    S = f"b24h-{RUN}"
    lab = f"io.micropod.cache.scope={S}"
    G = "/micropod/cache/gomod/b24"
    code, _, _ = job("h-seed", f"mkdir -p {G} && echo seed > {G}/seed", labels=[lab])
    check("H01", "a trusted container (the shipped default) seeded the scope's gomod store", code, 0)
    wait_clean([S])
    base = identity()
    g0 = guest_policy()
    check("H02", "baseline: the guest's policy trusts unlabeled containers", guest_trust(), "trusted")
    digest0 = g0.get("policyDigest")

    def reader(name, files):
        code, text, _ = job(name, "; ".join(f"if [ -e {G}/{f} ]; then echo {f}=$(cat {G}/{f}); else echo {f}=absent; fi"
                                            for f in files), labels=[lab, "io.micropod.cache.trust=trusted"])
        return {k: v for k, v in (ln.split("=", 1) for ln in text.splitlines() if "=" in ln and not ln.startswith("B24"))}

    def planter(name, fname, keep=False):
        script = (f"echo poisoned > {G}/seed 2>/dev/null && echo overwrote=yes; "
                  f"echo planted > {G}/{fname} 2>/dev/null && echo planted=yes; echo seen=$(cat {G}/seed)")
        return job(name, script, labels=[lab], keep=keep)

    session = mcp()
    try:
        if "policy-skip" in SABOTAGE:
            log("SABOTAGE policy-skip: the trust flip is never sent")
            sent = time.time()
            err, text, saved = False, "{}", {"defaultTrust": "untrusted"}
        else:
            sent = time.time()
            err, text, saved = session.call("cache_policy_set", {"default_trust": "untrusted"})
        lat = time_until(lambda: guest_trust() == "untrusted", since=sent)
        METRICS["policyVisibleSecondsTrustFlip"] = lat
        check("H03", "MCP cache_policy_set default_trust=untrusted is accepted and saved",
              (err, (saved or {}).get("defaultTrust")), (False, "untrusted"), ev=evidence("H03-mcp-set", saved or text))
        check("H04", "the running guest applies it within 3 s of the request being sent "
              "(GET /micropod/caches on the guest's socket)", lat,
              "<= 3 s", ok=lat is not None and lat <= 3.0)
        digest1 = guest_policy().get("policyDigest")
        check("H05", "…with a new policy digest", (bool(digest0), bool(digest1), digest1 != digest0), (True, True, True))
        code, text, ins = planter("h-untrusted", "planted-u", keep=True)
        p = plan(ins)
        check("H06", "the next unlabeled container is untrusted by the policy default; gomod is copy-on-write",
              (p["trust"], p["trustFrom"], p["gomodAccess"]), ("untrusted", "policy-default", "copy-on-write"),
              ev=evidence("H06-plan", p))
        # The plan names the policy it was decided under (backlog B24: assert
        # the new policy in the container's MicropodCache plan), as the API's
        # `cache explain` reports it.
        st, ex = api("GET", f"/v1/caches/explain/b24-{RUN}-h-untrusted")
        cache = (ex or {}).get("cache") or {} if isinstance(ex, dict) else {}
        check("H07", "API cache explain for that container names its tier and the policy digest now in force",
              (st, cache.get("trust"), cache.get("policyDigest")), (200, "untrusted", digest1),
              ok=bool(digest1) and (st, cache.get("trust"), cache.get("policyDigest")) == (200, "untrusted", digest1),
              ev=evidence("H07-explain", {"explain": ex, "guestDigest": digest1,
                                          "guestInspectMicropodCache": (ins or {}).get("MicropodCache")}))
        cli("rm", "--force", f"b24-{RUN}-h-untrusted")
        check("H08", "…it could write in its own view", "overwrote=yes" in text and "seen=poisoned" in text, True)
        seen = reader("h-read1", ["seed", "planted-u"])
        check("H09", "…and nothing reached the store (a trusted reader sees the seed and no planted file)",
              seen, {"seed": "seed", "planted-u": "absent"})
        sent = time.time()
        err, text, saved = session.call("cache_policy_set", {"default_trust": "trusted"})
        lat2 = time_until(lambda: guest_trust() == "trusted", since=sent)
        METRICS["policyVisibleSecondsTrustRestore"] = lat2
        check("H10", "flipping back through MCP reaches the guest within 3 s", (err, lat2), "(False, <= 3 s)",
              ok=not err and lat2 is not None and lat2 <= 3.0)
        code, text, ins = planter("h-trusted", "planted-t")
        p = plan(ins)
        seen = reader("h-read2", ["seed", "planted-t"])
        check("H11", "the next unlabeled container is trusted again and its writes reach the store",
              (p["trust"], seen), ("trusted", {"seed": "poisoned", "planted-t": "planted"}), ev=evidence("H11-plan", p))
    finally:
        session.close()

    ok_scope, no_scope = f"b24ok-{RUN}", f"b24no-{RUN}"
    # The default scope must stay allowed (the API refuses a policy without it).
    sent = time.time()
    st, body = api("PUT", "/v1/caches/policy", {"allowedScopes": ["b24ok-*", "default"]})
    lat3 = time_until(lambda: "b24ok-*" in ((guest_policy().get("policy") or {}).get("allowedScopes") or []), since=sent)
    METRICS["policyVisibleSecondsAllowedScopes"] = lat3
    check("H12", "REST PUT allowedScopes is accepted and the guest applies it within 3 s", (st, lat3), "(200, <= 3 s)",
          ok=st == 200 and lat3 is not None and lat3 <= 3.0, ev=evidence("H12-put", body))
    base_req = {"image": IMAGE, "detach": False, "arguments": ["true"], "runtime": "hvf"}
    st, body = rpc("ContainerService", "CreateContainer",
                   dict(base_req, name=f"b24-{RUN}-hno", labels={"io.micropod.cache.scope": no_scope}))
    check("H13", "the next container naming a scope outside allowedScopes is refused (API CreateContainer)",
          (st != 200, "not allowed" in short(body, 2000)), (True, True), ev=evidence("H13-refused", body))
    st, body = rpc("ContainerService", "CreateContainer",
                   dict(base_req, name=f"b24-{RUN}-hok", labels={"io.micropod.cache.scope": ok_scope}))
    check("H14", "…and one naming an allowed scope is created", st, 200, ev=evidence("H14-created", body))
    rpc("ContainerService", "DeleteContainer", {"id": f"b24-{RUN}-hok", "force": True})
    st, body = api("PUT", "/v1/caches/policy", {"allowedScopes": ["*"]})
    time_until(lambda: (guest_policy().get("policy") or {}).get("allowedScopes") == ["*"])

    hashes = (sha(MACHINE_JSON), sha(POLICY_FILE))
    digest = guest_policy().get("policyDigest")
    replies = []
    for bad in ({"defaultTrust": "sometimes"}, {"bogusField": 1}, {"mode": "sideways"}, {}, "not json"):
        st, body = api("PUT", "/v1/caches/policy", bad)
        replies.append((st, short(body, 200)))
    check("H15", "malformed policy bodies are refused with 400 (bad tier, unknown key, bad mode, empty, not JSON)",
          [r[0] for r in replies], [400] * 5, ev=evidence("H15-malformed", replies))
    session = mcp()
    try:
        err, text, _ = session.call("cache_policy_set", {"default_trust": "sometimes"})
    finally:
        session.close()
    check("H16", "MCP cache_policy_set with a bad tier is a tool error", err, True)
    time.sleep(2.5)
    check("H17", "nothing was written: machine.json, the guest's policy file and the guest's digest are unchanged",
          ((sha(MACHINE_JSON), sha(POLICY_FILE)), guest_policy().get("policyDigest")), (hashes, digest),
          ok=bool(digest) and "absent" not in hashes
          and ((sha(MACHINE_JSON), sha(POLICY_FILE)), guest_policy().get("policyDigest")) == (hashes, digest))

    with open(POLICY_FILE, "w") as f:
        f.write('{"mode": "auto", "defaultTrust": ')
    lat4 = time_until(lambda: guest_trust() == "untrusted")
    METRICS["policyFailClosedSeconds"] = lat4
    check("H18", "a malformed policy file in the guest's config share fails closed (untrusted) within 3 s",
          lat4, "<= 3 s", ok=lat4 is not None and lat4 <= 3.0, ev=evidence("H18-guest-policy", guest_policy()))
    code, text, ins = planter("h-closed", "planted-c")
    p = plan(ins)
    seen = reader("h-read3", ["seed", "planted-c"])
    check("H19", "…the next unlabeled container is untrusted and nothing it writes reaches the store",
          (p["trust"], p["trustFrom"], seen), ("untrusted", "policy-default", {"seed": "poisoned", "planted-c": "absent"}),
          ev=evidence("H19-plan", p))
    sent = time.time()
    st, body = api("PUT", "/v1/caches/policy", {"defaultTrust": "trusted"})
    lat5 = time_until(lambda: guest_trust() == "trusted", since=sent)
    try:
        valid = json.load(open(POLICY_FILE)).get("version") is not None
    except (OSError, ValueError):
        valid = False
    check("H20", "a policy write through the API repairs it (valid file, guest trusts again within 3 s)",
          (st, valid, lat5 is not None and lat5 <= 3.0), (200, True, True))
    after = identity()
    check("H21", "none of it restarted the machine (same VMM and supervisor, no restarts)", after, base,
          ev=evidence("H21-identity", {"before": base, "after": after}))


def section_L():
    global SECTION
    SECTION = "L"
    log("L: 8 containers in one guest request; WaitContainer exit code and timeout; exec exit code")
    names = [f"b24-{RUN}-l{i}" for i in range(1, 9)]
    created = []
    for n in names:
        st, body = rpc("ContainerService", "RunContainer",
                       {"image": IMAGE, "name": n, "detach": True, "arguments": ["sleep", "600"], "runtime": "hvf",
                        "labels": {"b24.run": RUN}}, timeout=120)
        created.append(st)
    check("L01", "8 containers started through the API (RunContainer, runtime hvf)", created, [200] * 8)
    wait_for(lambda: all((inspect(n) or {}).get("State", {}).get("Running") for n in names), 60, 0.5)

    def metrics():
        st, d = guest("GET", "/micropod/metrics")
        a = (d or {}).get("api") or {} if isinstance(d, dict) else {}
        routes = a.get("routes") or {}
        return a.get("requests_total"), {k: (v or {}).get("count") if isinstance(v, dict) else v for k, v in routes.items()}

    time.sleep(1)
    r0, routes0 = metrics()
    st, listing = rpc("ContainerService", "ListContainers", {})
    if "list-inspect" in SABOTAGE:
        log("SABOTAGE list-inspect: one guest inspect per container while the listing is counted")
        for n in names:
            inspect(n)
    r1, routes1 = metrics()
    cs = (listing or {}).get("containers") or [] if isinstance(listing, dict) else []
    mine = {c.get("id"): (c.get("runtime"), c.get("state")) for c in cs if c.get("id") in names}
    check("L02", "ListContainers lists all 8 as hvf and running", mine, {n: ("hvf", "running") for n in names},
          ev=evidence("L02-list", listing))
    delta = (r1 or 0) - (r0 or 0)
    per = (routes1.get("GET /containers/{id}/json") or 0) - (routes0.get("GET /containers/{id}/json") or 0)
    METRICS["listContainersGuestRequests"] = delta
    check("L03", "…at a cost of at most one guest Docker API request and no per-container inspect",
          (delta, per), "(<= 1, 0)", ok=r0 is not None and delta <= 1 and per == 0,
          ev=evidence("L03-metrics", {"before": [r0, routes0], "after": [r1, routes1]}))
    # Backlog B24 acceptance, as written: the guest's request counter shows
    # that listing as exactly one request (one guest round trip).
    check("L04", "…and the guest's request counter counts that listing as exactly 1 request (B24 acceptance)",
          delta, 1, ev=evidence("L04-metrics", {"before": [r0, routes0], "after": [r1, routes1]}))
    st, listing2 = rpc("ContainerService", "ListContainers", {}, tcp=True)
    ids2 = {c.get("id") for c in (listing2 or {}).get("containers") or []} if isinstance(listing2, dict) else set()
    check("L05", "the same 8 over loopback TCP", set(names) <= ids2, True)
    rc, out, err = cli("--json", "ps")
    ps = parse(out.encode()) if rc == 0 else []
    psm = {c.get("id"): c.get("runtime") for c in ps if isinstance(c, dict) and c.get("id") in names} \
        if isinstance(ps, list) else {}
    check("L06", "`micropod ps --json` lists the 8 on hvf", psm, {n: "hvf" for n in names})
    session = mcp()
    try:
        err, text, _ = session.call("list_containers", {})
    finally:
        session.close()
    check("L07", "MCP list_containers lists the 8", (err, sorted(n for n in names if n in text)), (False, sorted(names)),
          ev=evidence("L07-mcp-list", text))
    # The listing is the guest's own, not a host-side record of what the API
    # created: a container made on the guest's socket directly is listed too.
    direct = f"b24-{RUN}-direct"
    st_c, made = guest("POST", f"/containers/create?name={direct}", {"Image": IMAGE, "Cmd": ["true"]}, timeout=60)
    st, listing3 = rpc("ContainerService", "ListContainers", {"all": True})
    ids3 = {c.get("id") for c in (listing3 or {}).get("containers") or []} if isinstance(listing3, dict) else set()
    check("L13", "a container created on the guest's own socket, behind the API's back, is in the next ListContainers",
          (st_c, direct in ids3), (201, True), ev=evidence("L13-direct", {"create": made, "listing": listing3}))
    guest("DELETE", f"/containers/{direct}?force=1")
    e7 = f"b24-{RUN}-exit7"
    st, body = rpc("ContainerService", "RunContainer",
                   {"image": IMAGE, "name": e7, "detach": True, "arguments": ["sh", "-c", "sleep 1; exit 7"],
                    "runtime": "hvf"}, timeout=120)
    t = time.time()
    st, w = rpc("ContainerService", "WaitContainer", {"id": e7, "timeoutSeconds": 60}, timeout=90)
    METRICS["waitExit7Seconds"] = round(time.time() - t, 3)
    w = w if isinstance(w, dict) else {}
    check("L08", "WaitContainer on a container exiting 7 returns exited, known, exitCode 7",
          (st, w.get("exited"), w.get("known"), w.get("exitCode")), (200, True, True, 7), ev=evidence("L08-wait", w))
    check("L09", "…which is what the guest recorded", (inspect(e7) or {}).get("State", {}).get("ExitCode"), 7)
    time.sleep(0.5)
    r0, routes0 = metrics()
    rpc("ContainerService", "WaitContainer", {"id": e7, "timeoutSeconds": 5}, timeout=30)
    r1, routes1 = metrics()
    # Recorded, not checked: an exited container costs an ownership probe,
    # one state poll and one exit-code read.
    METRICS["waitExitedGuestRequests"] = (r1 or 0) - (r0 or 0)
    time.sleep(0.5)
    r0, routes0 = metrics()
    t = time.time()
    st, w = rpc("ContainerService", "WaitContainer", {"id": names[0], "timeoutSeconds": 2}, timeout=30)
    took = round(time.time() - t, 3)
    r1, routes1 = metrics()
    METRICS["waitTimeoutSeconds"] = took
    METRICS["waitRunning2sGuestRequests"] = (r1 or 0) - (r0 or 0)
    # B15: one guest request per poll. HVF has no state-change parking, so a
    # wait polls every 150 ms: one ownership probe (the batched listing,
    # counted since it is a caller's request) plus at most ceil(took / 0.15)
    # + 1 polls; resolving the owner per poll doubles it. That count is
    # exact, not a ceiling: the wait always polls once more at its
    # deadline, so a 2 s wait makes 1 + 15 requests, and so does the bound
    # for any took in (2.0, 2.1]. The counter is the guest's, shared by
    # every caller, so the bound allows one request that is not the wait's
    # (another client's listing or _ping in the same 2 s) and still fails
    # the per-poll regression by a wide margin.
    bound = 3 + math.ceil(took / 0.15)
    check("L10", "WaitContainer on a running container costs one guest request per 150 ms poll (B15)",
          (r1 or 0) - (r0 or 0), f"<= {bound} in {took} s", ok=r0 is not None and 0 < (r1 or 0) - r0 <= bound,
          ev=evidence("L10-wait-metrics", {"reply": w, "seconds": took, "bound": bound,
                                            "before": [r0, routes0], "after": [r1, routes1]}))
    w = w if isinstance(w, dict) else {}
    check("L11", "WaitContainer with timeoutSeconds 2 on a running container returns after ~2 s, not exited",
          (st, bool(w.get("exited")), w.get("state"), took), "(200, False, running, 2–8 s)",
          ok=st == 200 and not w.get("exited") and w.get("state") == "running" and 2.0 <= took <= 8.0,
          ev=evidence("L11-wait-timeout", {"reply": w, "seconds": took}))
    rc, out, err = cli("exec", names[0], "--", "sh", "-c", "exit 7")
    check("L12", "`micropod exec … exit 7` exits 7", rc, 7)
    for n in names + [e7]:
        rpc("ContainerService", "DeleteContainer", {"id": n, "force": True})


def section_X():
    global SECTION
    SECTION = "X"
    log("X: exit codes for orderly stop, timeout and guest crash; readiness never lies")
    original = json.load(open(MACHINE_JSON))
    try:
        if not running():
            start_machine()
        rc, out, err = stop_machine()
        s = state()
        check("X01", "orderly stop: `micropod machine stop` exits 0", (rc, out.strip()), (0, "hvf machine stopped"))
        check("X02", "…the VMM exited 0, an orderly guest poweroff",
              (s.get("phase"), s.get("lastExitCode"), s.get("lastExitMeaning"), "exit_reason=poweroff" in (s.get("lastExitReason") or "")),
              ("stopped", 0, "orderly guest poweroff", True), ev=evidence("X02-state", s))
        rc, out, err = cli("--json", "machine", "status")
        ms = parse(out.encode()) if rc == 0 else {}
        check("X03", "…and `machine status --json` says so", ((ms or {}).get("state") or {}).get("lastExitCode")
              if isinstance(ms, dict) else ms, 0, ev=evidence("X03-status", ms))
        rc, out, err = stop_machine()
        check("X04", "stopping a stopped machine exits 0 and says it was not running", (rc, out.strip()),
              (0, "hvf machine was not running"))

        # VMM --timeout through the supervisor.
        set_machine_args(extra=["--timeout", "15"])
        rc, out, err = start_machine()
        sampler = Sampler(0.05)
        sampler.start()
        r0 = state().get("restartCount") or 0
        hit = wait_for(lambda: (state().get("restartCount") or 0) > r0 and state().get("lastExitCode") is not None, 60, 0.25)
        s = state()
        rc2, out2, _ = cli("--json", "machine", "status")
        ms = parse(out2.encode()) if rc2 == 0 else {}
        samples = sampler.stop()
        check("X05", "VMM --timeout (machine.json extraArguments): the VMM exits 5, timeout elapsed",
              (rc, bool(hit), s.get("lastExitCode"), s.get("lastExitMeaning"), "exit_reason=timeout" in (s.get("lastExitReason") or "")),
              (0, True, 5, "timeout elapsed", True), ev=evidence("X05-state", {"state": s, "status": ms}))
        mst = ((ms or {}).get("state") or {}) if isinstance(ms, dict) else {}
        check("X06", "…`machine status --json` reports that exit (code 5, timeout elapsed)",
              (mst.get("lastExitCode"), mst.get("lastExitMeaning")), (5, "timeout elapsed"))
        down = len(saw_guest_down(samples))
        check("X07", "…and no readiness sample said running while the guest was down (samples taken while it was down: "
              f"{down})", (len(false_running(samples)), down > 0), (0, True), ev=evidence("X07-samples", samples))
        stop_machine()
        set_machine_args(extra=original.get("extraArguments") or [])

        # A guest crash on a running machine: kernel panic on OOM.
        set_machine_args(kernel=["sysctl.vm.panic_on_oom=2"])
        rc, out, err = start_machine()
        before = identity()
        check("X08", "a machine whose guest panics on OOM boots and serves", (rc, running()), (0, True))
        sampler = Sampler(0.05)
        sampler.start()
        console = os.path.join(HVF, "logs", "console.log")
        mark = os.path.getsize(console) if os.path.exists(console) else 0
        cli("run", "--runtime", "hvf", "--name", f"b24-{RUN}-oom", IMAGE, "--", "sh", "-c", "tail /dev/zero")
        crashed = wait_for(lambda: (state().get("restartCount") or 0) > (before["restartCount"] or 0), 90, 0.25)
        s = state()
        back = wait_for(running, 120, 0.25)
        samples = sampler.stop()
        try:
            with open(console, "rb") as f:
                f.seek(mark)
                tail = f.read().decode(errors="replace")
        except OSError:
            tail = ""
        check("X09", "guest crash: a workload exhausting memory panics the guest kernel (console)",
              "Kernel panic" in tail, True, ev=evidence("X09-console", tail[-6000:]))
        check("X10", "…the VMM exits 3, the guest crashed or reset",
              (bool(crashed), s.get("lastExitCode"), s.get("lastExitMeaning"), "exit_reason=reboot" in (s.get("lastExitReason") or "")),
              (True, 3, "the guest crashed or reset", True), ev=evidence("X10-state", s))
        after = identity()
        check("X11", "…and the supervisor relaunched it: a new VMM serves again",
              (bool(back), after["vmmPID"] != before["vmmPID"], readiness("Ping")["status"]), (True, True, "running"))
        check("X12", "…no readiness sample said running while the crashed guest was down",
              (len(false_running(samples)), len(ready_features_while_not_running(samples)),
               len(saw_guest_down(samples)) > 0), (0, 0, True), ev=evidence("X12-samples", samples))
        METRICS["crashStatusSequence"] = [s2["status"] for i, s2 in enumerate(samples)
                                          if i == 0 or samples[i - 1]["status"] != s2["status"]]
        stop_machine()

        # A crash loop: the guest panics at every boot (no init).
        set_machine_args(kernel=["rdinit=/b24-no-such-init"])
        sampler = Sampler(0.05)
        sampler.start()
        rc, out, err = start_machine(timeout=4)
        check("X13", "CLI timeout: `machine start --timeout 4` on a machine that cannot get ready exits 1 (deadlineExceeded)",
              (rc, "deadlineExceeded" in err), (1, True), ev=evidence("X13-cli", {"rc": rc, "stderr": err}))
        failed = wait_for(lambda: state().get("phase") == "failed", 90, 0.1)
        s = state()
        samples = sampler.stop()
        gs = readiness("GetSystem")
        check("X14", "crash loop: the supervisor gives up (failed) on guest crashes (exit 3) after its rapid-failure budget",
              (bool(failed), s.get("phase"), s.get("lastExitCode"), s.get("restartCount")),
              (True, "failed", 3, 4), ev=evidence("X14-state", s))
        check("X15", "crash loop: no Ping/GetSystem sample said running or advertised caches-v2/buildkit",
              (len([x for x in samples if x["status"] == "running"]), len(ready_features_while_not_running(samples)),
               len(samples) >= 10), (0, 0, True), ev=evidence("X15-samples", samples))
        check("X16", "crash loop: after it failed, GetSystem is not running and says why",
              (gs["status"] != "running", "crashed" in (gs["detail"] or "")), (True, True), ev=evidence("X16-getsystem", gs))
        METRICS["crashLoopStatusSequence"] = [x["status"] for i, x in enumerate(samples)
                                              if i == 0 or samples[i - 1]["status"] != x["status"]]
        stop_machine()
    finally:
        if state().get("phase") not in (None, "stopped"):
            stop_machine()
        set_machine_args(kernel=original.get("kernelArguments") or [], extra=original.get("extraArguments") or [])


def write_result(started, error):
    try:
        versions = json.load(open(RECEIPT / "versions.json"))
    except (OSError, ValueError):
        versions = {}
    passed = sum(1 for r in RESULTS if r["ok"])
    failed = [r["id"] for r in RESULTS if not r["ok"]]
    # Only a run of every section, unsabotaged, can pass.
    complete = all(s in SECTIONS for s in ALL_SECTIONS) and not SABOTAGE
    result = {
        "gate": "B24 api-guest", "run": RUN, "root": ROOT, "apiSocket": API_SOCK, "apiPort": API_PORT,
        "versions": versions, "receipt": str(RECEIPT),
        "sections": SECTIONS, "sabotage": SABOTAGE, "seconds": round(time.time() - started, 1),
        "checks": len(RESULTS), "passed": passed, "failed": len(failed), "failedIds": failed,
        "harnessError": error, "metrics": METRICS, "results": RESULTS,
        "complete": complete,
        "verdict": ("pass" if complete else "partial") if not failed and not error and RESULTS else "fail",
    }
    tmp = RECEIPT / "result.json.tmp"
    tmp.write_text(json.dumps(result, indent=2, default=str))
    os.replace(tmp, RECEIPT / "result.json")
    with open(RECEIPT / "checks.tsv", "w") as f:
        for r in RESULTS:
            f.write("\t".join([r["id"], "pass" if r["ok"] else "fail", r["section"], r["name"], r["got"], r["want"]]) + "\n")
    return result


def on_signal(signum, frame):
    raise SystemExit(f"b24: terminated by signal {signum}")


def main():
    global SECTION
    started = time.time()
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGHUP, on_signal)
    os.makedirs(OUT_HOST, exist_ok=True)
    os.chmod(OUT_HOST, 0o777)
    error = None
    try:
        if "R" in SECTIONS:
            section_R()
        else:
            if not running():
                start_machine()
            cli("pull", "--runtime", "hvf", IMAGE, timeout=600)
        if not running():
            start_machine()
        section_Z()
        write_result(started, None)
        for name, fn in (("S", section_S), ("P", section_P), ("H", section_H), ("L", section_L), ("X", section_X),
                         ("F", section_F)):
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
    result = write_result(started, error)
    failed = result["failedIds"]
    print(f"\n{result['passed']} passed, {len(failed)} failed{' (' + ', '.join(failed) + ')' if failed else ''}"
          f"{'; harness error: ' + error if error else ''}", flush=True)
    if result["verdict"] == "partial":
        print(f"partial run (sections {' '.join(SECTIONS)}{', sabotaged' if SABOTAGE else ''}): not a gate pass", flush=True)
    sys.exit(0 if result["verdict"] in ("pass", "partial") else (2 if error else 1))


if __name__ == "__main__":
    main()
