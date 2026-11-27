#!/usr/bin/env python3
"""The records-crash gate's driver (scripts/gates/records-crash.sh runs it).

  driver.py ROOT RECEIPT RUN_ID OFFSETS_MS IMAGE

ROOT is the throwaway machine root (run/docker.sock, run/state.json,
disk.ext4), RECEIPT the receipt directory: every check is appended to
RECEIPT/checks.tsv as id, section, status, label, got, want, evidence.

Each trial creates objects through the guest's Docker API (host side, the
machine's own socket): every kind but the trial's own, then, after a quiet
GATE_QUIET_S (6 s, longer than ext4's journal commit interval, so all of that
is on the disk), the trial's kind last, alone, and kills this root's VMM with
SIGKILL the trial's offset after its answer: only that kind's own syncs can
have made it durable. The kinds rotate across trials; then it waits for the
supervisor's relaunch and checks what the engine recovered:

  created    docker create (labels, env, cmd): present, created, same config
  exited     create, start, wait (exit 7): present, exited 7, and it starts
             again after the crash (its retained rootfs recovered) to exit 7
  running    create, start (sleep): present, not running, never created and
             never a success (recovery's dead, exit -1)
  burst      six creates at once (one journal commit can serve them all):
             every answered one present, same config
  rm-created create with AutoRemove, never started: absent, or present whole
  rm-started create with AutoRemove and start (sleep): absent (cleaned up)
  volume     a named volume with labels: present, same labels
  network    a bridge network with labels: present, same labels, and a
             container started on it runs and reads a resolver
  on-network create attached to that network: present, on that network

The engine must answer _ping after every relaunch: recovery refuses a torn or
empty record, so an engine that does not come back fails the trial. Nothing
but this root's micropod-vmm (its binary, on its disk) is ever signalled.
"""
import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time

ROOT, RECEIPT, RUN, OFFSETS, IMAGE = sys.argv[1:6]
SOCK = os.path.join(ROOT, "run", "docker.sock")
STATE = os.path.join(ROOT, "run", "state.json")
CHECKS = os.path.join(RECEIPT, "checks.tsv")
EVID = os.path.join(RECEIPT, "evidence")
os.makedirs(EVID, exist_ok=True)
counters = {}


def log(msg):
    print(time.strftime("%H:%M:%S") + " records-crash: " + msg, flush=True)


def record(section, label, got, want, ok, evidence=""):
    n = counters[section] = counters.get(section, 0) + 1
    cid = "%s-%02d" % (section, n)
    line = "\t".join(str(x).replace("\t", " ").replace("\n", " ") for x in
                     (cid, section, "pass" if ok else "fail", label, got, want, evidence))
    with open(CHECKS, "a") as f:
        f.write(line + "\n")
    print(("  ✓ " if ok else "  ✗ ") + cid + " " + label + ("" if ok else " — got '%s', want %s" % (got, want)), flush=True)
    return ok


class Unix(http.client.HTTPConnection):
    def __init__(self, timeout):
        super().__init__("docker", timeout=timeout)

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(SOCK)


def call(method, url, body=None, timeout=60):
    c = Unix(timeout)
    try:
        data = json.dumps(body).encode() if body is not None else None
        c.request(method, "/v1.47" + url, body=data, headers={"Content-Type": "application/json"} if data else {})
        r = c.getresponse()
        payload = r.read()
        return r.status, payload
    finally:
        c.close()


def jcall(method, url, body=None, want=(200,), timeout=60):
    st, p = call(method, url, body, timeout)
    if st not in want:
        raise RuntimeError("%s %s: %d %s" % (method, url, st, p[:300]))
    return json.loads(p) if p else None


def ping():
    try:
        st, p = call("GET", "/_ping", timeout=3)
        return st == 200 and p.strip() == b"OK"
    except OSError:
        return False


def state():
    try:
        return json.load(open(STATE))
    except (OSError, ValueError):
        return {}


def my_vmm():
    pid = state().get("vmmPID")
    if not isinstance(pid, int):
        return None
    cmd = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    roots = {ROOT, os.path.realpath(ROOT)}
    if any(cmd.startswith(r + "/micropod-vmm ") and ("--disk " + r + "/disk.ext4") in cmd for r in roots):
        return pid
    return None


def supervisor_gave_up():
    try:
        with open(os.path.join(ROOT, "logs", "supervisor.log"), errors="replace") as f:
            return "giving up after" in f.read()[-20000:]
    except OSError:
        return False


def engine_error():
    """The last error the guest engine printed on the console, if any."""
    try:
        with open(os.path.join(ROOT, "logs", "console.log"), errors="replace") as f:
            lines = [l.strip() for l in f.read()[-400000:].splitlines() if l.startswith('{"error":')]
        return lines[-1] if lines else ""
    except OSError:
        return ""


def wait_engine(old_pid, budget=300):
    end = time.time() + budget
    while time.time() < end:
        s = state()
        if s.get("vmmPID") not in (None, old_pid) and ping():
            return True
        if supervisor_gave_up():
            return False
        time.sleep(0.2)
    return False


def labels(kind, trial):
    return {"rc-run": RUN, "rc-trial": str(trial), "rc-kind": kind, "rc-note": "x" * 64}


def container_body(kind, trial, cmd, auto_remove=False, network=None):
    body = {"Image": IMAGE, "Cmd": cmd, "Env": ["RC_KIND=" + kind, "RC_TRIAL=%d" % trial],
            "Labels": labels(kind, trial), "HostConfig": {"AutoRemove": auto_remove}}
    if network:
        body["HostConfig"]["NetworkMode"] = network
    body["Labels"]["io.micropod.cache"] = "off"
    return body


def create(name, body):
    return jcall("POST", "/containers/create?name=" + name, body, want=(201,))["Id"]


def start(cid):
    st, p = call("POST", "/containers/%s/start" % cid)
    if st != 204:
        raise RuntimeError("start %s: %d %s" % (cid, st, p[:300]))


def frames(raw):
    out, i = b"", 0
    while i + 8 <= len(raw):
        n = int.from_bytes(raw[i + 4:i + 8], "big")
        out += raw[i + 8:i + 8 + n]
        i += 8 + n
    return out.decode(errors="replace")


KINDS = ["created", "exited", "running", "burst", "rm-created", "rm-started", "volume", "network", "on-network"]
QUIET = float(os.environ.get("GATE_QUIET_S", "6"))


def trial_objects(trial):
    """(batch, last): every kind once, the trial's own kind last."""
    last = KINDS[(trial - 1) % len(KINDS)]
    batch = [k for k in KINDS if k != last and not (last == "network" and k == "on-network")]
    return batch, last


def run_trial(trial, offset_ms):
    t = "%s-%d" % (RUN, trial)
    answered = {}
    batch, last_kind = trial_objects(trial)
    order = batch + [last_kind]
    # Proven this root's VMM before the trial (ps is slow); state.json must
    # still name the same pid at the kill.
    vmm = my_vmm()
    if vmm is None:
        raise RuntimeError("this root's VMM is not running")
    for kind in order:
        if kind == last_kind:
            # Everything before is on the disk by now (ext4 commits its
            # journal every 5 s): only the last kind's own syncs can keep it.
            time.sleep(QUIET)
        if kind == "volume":
            v = jcall("POST", "/volumes/create", {"Name": "rcv-" + t, "Labels": labels("volume", trial)}, want=(201,))
            answered["volume"] = v["Name"]
        elif kind == "network":
            n = jcall("POST", "/networks/create", {"Name": "rcn-" + t, "Driver": "bridge", "Labels": labels("network", trial)}, want=(201,))
            answered["network"] = n["Id"]
        elif kind == "created":
            answered["created"] = create("rcc-" + t, container_body("created", trial, ["sh", "-c", "exit 3"]))
        elif kind == "exited":
            cid = create("rce-" + t, container_body("exited", trial, ["sh", "-c", "echo ran > /rc-ran; exit 7"]))
            start(cid)
            w = jcall("POST", "/containers/%s/wait" % cid, timeout=120)
            answered["exited"] = (cid, w.get("StatusCode"))
        elif kind == "running":
            cid = create("rcr-" + t, container_body("running", trial, ["sleep", "600"]))
            start(cid)
            answered["running"] = cid
        elif kind == "burst":
            ids, errs = [None] * 6, []

            def one(i):
                try:
                    ids[i] = create("rcb%d-%s" % (i, t), container_body("burst", trial, ["true"]))
                except Exception as e:  # noqa: BLE001 - recorded below
                    errs.append(str(e))
            th = [threading.Thread(target=one, args=(i,)) for i in range(6)]
            for x in th:
                x.start()
            for x in th:
                x.join()
            if errs:
                raise RuntimeError("burst create: " + errs[0])
            answered["burst"] = ids
        elif kind == "rm-created":
            answered["rm-created"] = create("rcq-" + t, container_body("rm-created", trial, ["true"], auto_remove=True))
        elif kind == "rm-started":
            cid = create("rcs-" + t, container_body("rm-started", trial, ["sleep", "600"], auto_remove=True))
            start(cid)
            answered["rm-started"] = cid
        elif kind == "on-network":
            answered["on-network"] = create("rco-" + t, container_body("on-network", trial, ["true"], network="rcn-" + t))
    last = time.perf_counter()
    while (time.perf_counter() - last) * 1000 < offset_ms:
        time.sleep(0.0005)
    if state().get("vmmPID") != vmm:
        raise RuntimeError("the VMM changed during the trial")
    os.kill(vmm, signal.SIGKILL)
    actual = (time.perf_counter() - last) * 1000
    log("trial %d: killed VMM %d %.1f ms after the last answer (%s last)" % (trial, vmm, actual, order[-1]))
    return answered, vmm, actual, order


def same_config(info, kind, trial):
    cfg = info.get("Config") or {}
    want_labels = labels(kind, trial)
    got = {k: (cfg.get("Labels") or {}).get(k) for k in want_labels}
    env = cfg.get("Env") or []
    return got == want_labels and ("RC_KIND=" + kind) in env and cfg.get("Image") == IMAGE


def inspect(cid):
    st, p = call("GET", "/containers/%s/json" % cid)
    return json.loads(p) if st == 200 else None


def verify(trial, answered, vmm, actual, order):
    sec = "T%02d" % trial
    t = "%s-%d" % (RUN, trial)
    up = wait_engine(vmm)
    if not record(sec, "after kill -9 at +%.0f ms (%s last) the relaunched engine answers _ping (recovery found every record whole)" % (actual, order[-1]),
                  "up" if up else "no answer: " + (engine_error() or "?"), "up", up, "logs/console.log"):
        return None
    listed = jcall("GET", "/containers/json?all=1&filters=" + json.dumps({"label": ["rc-run=" + RUN, "rc-trial=%d" % trial]}).replace(" ", ""))
    json.dump(listed, open(os.path.join(EVID, "trial-%02d-containers.json" % trial), "w"), indent=1)
    by_id = {c["Id"]: c for c in listed}
    ok = True
    if "created" in answered:
        info = inspect(answered["created"])
        good = info is not None and info["State"]["Status"] == "created" and same_config(info, "created", trial)
        ok &= record(sec, "an answered docker create survives, still created, with its labels, env and image",
                     info and (info["State"]["Status"], same_config(info, "created", trial)), "('created', True)", good)
    if "exited" in answered:
        cid, code = answered["exited"]
        info = inspect(cid)
        got = info and (info["State"]["Status"], info["State"]["ExitCode"])
        ok &= record(sec, "a container whose wait answered exit 7 survives as exited 7", got, "('exited', 7)",
                     code == 7 and got == ("exited", 7))
        if info:
            start(cid)
            w = jcall("POST", "/containers/%s/wait" % cid, timeout=120)
            ok &= record(sec, "it starts again after the crash (its retained rootfs and record recovered) and exits 7",
                         w.get("StatusCode"), 7, w.get("StatusCode") == 7)
    if "running" in answered:
        info = inspect(answered["running"])
        got = info and (info["State"]["Status"], info["State"]["Running"], info["State"]["ExitCode"])
        good = info is not None and not info["State"]["Running"] and info["State"]["Status"] != "created" and info["State"]["ExitCode"] != 0
        ok &= record(sec, "a container whose start answered is present, not running, and neither created nor a success", got,
                     "(dead|exited, False, nonzero)", good)
    if "burst" in answered:
        missing = [i for i in answered["burst"] if not (inspect(i) and same_config(inspect(i), "burst", trial))]
        ok &= record(sec, "all six concurrent creates survive whole", "%d of 6 missing or changed" % len(missing), "0 of 6", not missing)
    if "rm-created" in answered:
        info = inspect(answered["rm-created"])
        good = info is None or (info["State"]["Status"] == "created" and same_config(info, "rm-created", trial))
        ok &= record(sec, "an AutoRemove container never started is gone or whole", "absent" if info is None else (info["State"]["Status"], same_config(info, "rm-created", trial)),
                     "absent or ('created', True)", good)
    if "rm-started" in answered:
        info = inspect(answered["rm-started"])
        ok &= record(sec, "an AutoRemove container that was running is cleaned up", "absent" if info is None else info["State"]["Status"], "absent", info is None)
    if "volume" in answered:
        st, p = call("GET", "/volumes/" + answered["volume"])
        v = json.loads(p) if st == 200 else {}
        good = st == 200 and {k: (v.get("Labels") or {}).get(k) for k in labels("volume", trial)} == labels("volume", trial)
        ok &= record(sec, "an answered volume create survives with its labels", st if st != 200 else "labels " + ("same" if good else "changed"), "labels same", good)
    if "network" in answered:
        st, p = call("GET", "/networks/" + answered["network"])
        n = json.loads(p) if st == 200 else {}
        good = st == 200 and {k: (n.get("Labels") or {}).get(k) for k in labels("network", trial)} == labels("network", trial)
        ok &= record(sec, "an answered network create survives with its labels", st if st != 200 else "labels " + ("same" if good else "changed"), "labels same", good)
        if st == 200:
            gw = ((n.get("IPAM") or {}).get("Config") or [{}])[0].get("Gateway", "?")
            cid = create("rcd-" + t, container_body("resolver", trial, ["cat", "/etc/resolv.conf"], network="rcn-" + t))
            start(cid)
            jcall("POST", "/containers/%s/wait" % cid, timeout=120)
            st2, raw = call("GET", "/containers/%s/logs?stdout=1&stderr=1" % cid)
            text = frames(raw) if st2 == 200 else ""
            ok &= record(sec, "a container started on that network (gateway %s) runs and reads a resolver" % gw, text.strip()[:80] or "empty",
                         "a nameserver line", "nameserver " in text)
    if "on-network" in answered:
        info = inspect(answered["on-network"])
        nets = list(((info or {}).get("NetworkSettings") or {}).get("Networks") or {})
        good = info is not None and same_config(info, "on-network", trial) and "rcn-" + t in nets
        ok &= record(sec, "a container created on that network survives on it", nets if info else "absent", "['rcn-%s']" % t, good)
    unexpected = [c["Id"][:12] for c in listed if c["Labels"].get("rc-kind") == "rm-started"]
    ok &= record(sec, "no AutoRemove leftover is listed", unexpected, "[]", not unexpected)
    return ok


def cleanup(trial):
    flt = json.dumps({"label": ["rc-run=" + RUN]}).replace(" ", "")
    for c in jcall("GET", "/containers/json?all=1&filters=" + flt):
        call("DELETE", "/containers/%s?force=1" % c["Id"])
    for n in jcall("GET", "/networks?filters=" + flt) or []:
        call("DELETE", "/networks/" + n["Id"])
    vols = (jcall("GET", "/volumes?filters=" + flt) or {}).get("Volumes") or []
    for v in vols:
        call("DELETE", "/volumes/" + v["Name"])


def restart_machine():
    cli = os.environ["MICROPOD_CLI"]
    subprocess.run([cli, "machine", "stop"], capture_output=True, timeout=120)
    r = subprocess.run([cli, "machine", "start", "--timeout", "300"], capture_output=True, text=True, timeout=400)
    if r.returncode != 0:
        log("machine start: " + (r.stderr or r.stdout)[-400:])
    return wait_engine(None, 120)


def main():
    offsets = [float(x) for x in OFFSETS.split(",") if x]
    if not ping():
        record("P", "the throwaway engine answers before the first trial", "no answer", "up", False)
        return 2
    st, p = call("GET", "/images/%s/json" % IMAGE)
    if st != 200:
        record("P", "the trial image is present", st, 200, False)
        return 2
    all_ok = True
    kills = 0
    for i, off in enumerate(offsets, 1):
        # The supervisor gives up after five failures within a minute of a
        # launch, and a kill is one: a fresh machine every third trial.
        if kills == 3:
            if not restart_machine():
                record("T%02d" % i, "the machine restarts between trials", "no answer", "up", False)
                return 1
            kills = 0
        kills += 1
        try:
            answered, vmm, actual, order = run_trial(i, off)
        except Exception as e:  # noqa: BLE001 - a harness error is a failed check, never a pass
            all_ok &= record("T%02d" % i, "the trial's creates are answered and the VMM is this root's", str(e)[:200], "answered", False)
            if not wait_engine(None, 120):
                return 1
            continue
        try:
            ok = verify(i, answered, vmm, actual, order)
        except Exception as e:  # noqa: BLE001
            ok = record("T%02d" % i, "the trial's checks ran", str(e)[:200], "ran", False)
        if ok is None:
            log("the engine did not come back after trial %d; the sweep stops here" % i)
            return 1
        all_ok &= ok
        if ping():
            try:
                cleanup(i)
            except Exception as e:  # noqa: BLE001
                log("cleanup after trial %d: %s" % (i, e))
        else:
            if not wait_engine(None, 120):
                return 1
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
