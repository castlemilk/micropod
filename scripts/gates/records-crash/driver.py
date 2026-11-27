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

Then the image trials (GATE_IMAGE_TRIALS, section I; see image_main): a pull,
a load or a build of an image the engine never had, the VMM killed after the
answer (after:MS) or before it (before:FRACTION of the kind's duration); the
image must then be whole, or gone when the operation had not answered, and a
second pull, load or build must leave it whole.

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


# --- image kinds -----------------------------------------------------------
#
# An image trial makes one image the engine never had (a never-pulled image,
# or one generated with a unique layer for load and build), then kills the VMM
# either at an offset after the operation answered (after:MS) or at a
# fraction of the kind's measured duration after it began (before:FRACTION;
# if it answered first, that is recorded and it is judged as answered). After
# the relaunch the image must be whole when the operation answered, and gone
# or whole when it did not; "whole" is a container from it that runs and
# whose every regular file has the sha256 of the image's layers (computed on
# the host: from the registry for a pull, from the generated layer for load
# and build). Then the operation is repeated (pull, load or build again) and
# the image must be whole: a broken image that survives its own re-pull fails.

PULL_AFTER = os.environ.get("GATE_PULL_IMAGES", ",".join(
    "public.ecr.aws/docker/library/busybox:%s-%s" % (v, libc)
    for v in ("1.37.0", "1.36.1", "1.35.0", "1.34.1") for libc in ("musl", "glibc", "uclibc"))).split(",")
PULL_BEFORE = os.environ.get("GATE_PULL_BEFORE_IMAGES", ",".join(
    ["public.ecr.aws/docker/library/python:%s-alpine" % v for v in ("3.13", "3.12", "3.14", "3.10", "3.9")] +
    ["public.ecr.aws/docker/library/node:%s-alpine" % v for v in ("22", "20", "24", "18")])).split(",")
IMAGE_TRIALS = os.environ.get("GATE_IMAGE_TRIALS", "")
SWEEP = os.environ.get("GATE_SWEEP", "records,images").split(",")
DOCKER_BIN = os.environ.get("GATE_DOCKER_BIN", "docker")
GATE_TMP = os.environ.get("GATE_TMP", "/tmp")
GEN_MIB = int(os.environ.get("GATE_IMAGE_MIB", "32"))
used_refs = set()
durations = {}
expected_cache = {}
alpine_members = None
PROBE = ("find / -xdev -type f -print0 2>/dev/null | xargs -0 sha256sum 2>&1; echo RC-PROBE-END")
SKIP_PATHS = {"etc/hosts", "etc/hostname", "etc/resolv.conf"}


def parse_trials(spec):
    out = []
    for item in [x for x in spec.split(",") if x]:
        kind, phase, value = item.split(":")
        if kind not in ("pull", "load", "build") or phase not in ("after", "before"):
            raise ValueError("image trial %r: want pull|load|build:after|before:N" % item)
        out.append((kind, phase, float(value)))
    return out


def tar_path(name):
    while name.startswith("./"):
        name = name[2:]
    return name.lstrip("/").rstrip("/")


def merge_layer(files, tf):
    """Apply one layer tar to files ({path: sha256}), whiteouts included."""
    import hashlib
    links = []
    for m in tf:
        name = tar_path(m.name)
        if name in ("", "."):
            continue
        base = name.rsplit("/", 1)[-1]
        parent = name.rsplit("/", 1)[0] if "/" in name else ""
        if base == ".wh..wh..opq":
            pre = parent + "/"
            for k in [k for k in files if k.startswith(pre)]:
                del files[k]
            continue
        if base.startswith(".wh."):
            gone = (parent + "/" if parent else "") + base[4:]
            for k in [k for k in files if k == gone or k.startswith(gone + "/")]:
                del files[k]
            continue
        if m.isfile():
            h = hashlib.sha256()
            f = tf.extractfile(m)
            while True:
                b = f.read(1 << 20)
                if not b:
                    break
                h.update(b)
            files[name] = h.hexdigest()
        elif m.islnk():
            links.append((name, tar_path(m.linkname)))
        else:
            files.pop(name, None)
            if m.isdir():
                continue
    for name, target in links:
        if target in files:
            files[name] = files[target]
    return files


def registry_get(url, token, accept=None):
    import urllib.request

    class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            new = super().redirect_request(req, fp, code, msg, headers, newurl)
            if new is not None:
                new.remove_header("Authorization")
            return new
    import urllib.error
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token} if token else {})
    if accept:
        req.add_header("Accept", accept)
    # A public registry rate-limits anonymous clients (HTTP 429): back off.
    for attempt in range(8):
        try:
            return urllib.request.build_opener(NoAuthRedirect).open(req, timeout=120)
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or attempt == 7:
                raise
            wait = float(e.headers.get("Retry-After") or 0) or min(2 ** attempt, 30)
            log("registry %s answered %d; again in %.0f s" % (url.split("?")[0][-60:], e.code, wait))
            time.sleep(wait)


def registry_expected(ref):
    """{path: sha256} of the linux/arm64 image ref, from its registry."""
    if ref in expected_cache:
        return expected_cache[ref]
    import tarfile
    host, rest = ref.split("/", 1)
    repo, tag = rest.rsplit(":", 1)
    tok = json.loads(registry_get("https://%s/token/?scope=repository:%s:pull" % (host, repo), "").read())["token"]
    accept = ", ".join(["application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json",
                        "application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"])
    m = json.loads(registry_get("https://%s/v2/%s/manifests/%s" % (host, repo, tag), tok, accept).read())
    if "manifests" in m:
        arm = [x for x in m["manifests"] if (x.get("platform") or {}).get("architecture") == "arm64" and (x.get("platform") or {}).get("os") == "linux"]
        m = json.loads(registry_get("https://%s/v2/%s/manifests/%s" % (host, repo, arm[0]["digest"]), tok, accept).read())
    files = {}
    for layer in m["layers"]:
        r = registry_get("https://%s/v2/%s/blobs/%s" % (host, repo, layer["digest"]), tok)
        with tarfile.open(fileobj=r, mode="r|*") as tf:
            merge_layer(files, tf)
    expected_cache[ref] = files
    return files


def load_alpine_members():
    """The trial image's (alpine) only layer, as (TarInfo, bytes) pairs, from the engine's docker save."""
    global alpine_members
    if alpine_members is not None:
        return alpine_members
    import io as _io
    import tarfile
    st, raw = call("GET", "/images/%s/get" % IMAGE, timeout=300)
    if st != 200:
        raise RuntimeError("docker save %s: %d" % (IMAGE, st))
    outer = tarfile.open(fileobj=_io.BytesIO(raw))
    names = outer.getnames()

    def member(n):
        return outer.extractfile(n).read()
    layer = None
    if "manifest.json" in names:
        man = json.loads(member("manifest.json"))
        layers = man[0]["Layers"]
        if len(layers) != 1:
            raise RuntimeError("%s has %d layers, want 1" % (IMAGE, len(layers)))
        layer = member(layers[0])
    else:
        idx = json.loads(member("index.json"))
        d = idx["manifests"][0]["digest"]
        blob = json.loads(member("blobs/sha256/" + d.split(":")[1]))
        if "manifests" in blob:
            d = [x for x in blob["manifests"] if (x.get("platform") or {}).get("architecture") == "arm64"][0]["digest"]
            blob = json.loads(member("blobs/sha256/" + d.split(":")[1]))
        layer = member("blobs/sha256/" + blob["layers"][0]["digest"].split(":")[1])
    tf = tarfile.open(fileobj=_io.BytesIO(layer), mode="r:*")
    alpine_members = [(m, tf.extractfile(m).read() if m.isfile() else None) for m in tf.getmembers()]
    return alpine_members


def gen_rootfs(tag):
    """A unique layer: the trial image's rootfs plus GEN_MIB MiB of random files. (tar bytes, {path: sha256})."""
    import hashlib
    import io as _io
    import tarfile
    buf = _io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tf:
        for m, data in load_alpine_members():
            tf.addfile(m, _io.BytesIO(data) if data is not None else None)
        for d in ("rc", "rc/data"):
            ti = tarfile.TarInfo(d)
            ti.type, ti.mode = tarfile.DIRTYPE, 0o755
            tf.addfile(ti)
        files = [("rc/id", ("%s %s\n" % (tag, time.time())).encode())]
        files += [("rc/data/blob-%02d" % i, os.urandom(1 << 20)) for i in range(GEN_MIB)]
        for name, data in files:
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode = len(data), 0o644
            tf.addfile(ti, _io.BytesIO(data))
    raw = buf.getvalue()
    with tarfile.open(fileobj=_io.BytesIO(raw)) as tf:
        expected = merge_layer({}, tf)
    return raw, expected, "sha256:" + hashlib.sha256(raw).hexdigest()


def gen_load_archive(tag):
    import hashlib
    import io as _io
    import tarfile
    layer, expected, diffid = gen_rootfs(tag)
    config = json.dumps({"architecture": "arm64", "os": "linux", "config": {"Cmd": ["/bin/sh"]},
                         "rootfs": {"type": "layers", "diff_ids": [diffid]}}).encode()
    cfgname = hashlib.sha256(config).hexdigest() + ".json"
    lname = diffid.split(":")[1] + "/layer.tar"
    manifest = json.dumps([{"Config": cfgname, "RepoTags": [tag], "Layers": [lname]}]).encode()
    buf = _io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        for name, data in ((cfgname, config), (lname, layer), ("manifest.json", manifest)):
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            tf.addfile(ti, _io.BytesIO(data))
    return buf.getvalue(), expected


class ImageOp:
    """One image-producing operation and how to check its image."""

    def __init__(self, kind, trial, before):
        self.kind, self.trial = kind, trial
        t = "%s-%d" % (RUN, trial)
        if kind == "pull":
            pool = PULL_BEFORE if before else PULL_AFTER
            for ref in pool:
                if ref in used_refs:
                    continue
                st, _ = call("GET", "/images/%s/json" % ref)
                used_refs.add(ref)
                if st == 404:
                    self.ref = ref
                    break
            else:
                raise RuntimeError("no never-pulled image left for a pull trial (%s)" % ("before" if before else "after"))
            self.expected = None
        elif kind == "load":
            self.ref = "docker.io/library/rc-load-%s:v1" % t
            self.archive, self.expected = gen_load_archive(self.ref)
        else:
            self.ref = "docker.io/library/rc-build-%s:v1" % t
            layer, self.expected, _ = gen_rootfs(self.ref)
            self.ctx = os.path.join(GATE_TMP, "build-" + t)
            os.makedirs(self.ctx, exist_ok=True)
            with open(os.path.join(self.ctx, "rootfs.tar"), "wb") as f:
                f.write(layer)
            with open(os.path.join(self.ctx, "Dockerfile"), "w") as f:
                f.write('FROM scratch\nADD rootfs.tar /\nCMD ["/bin/sh"]\n')

    def run(self, timeout=900):
        """Runs the operation; returns once it answered (raises if it failed)."""
        if self.kind == "pull":
            repo, tag = self.ref.rsplit(":", 1)
            st, p = call("POST", "/images/create?fromImage=%s&tag=%s" % (repo, tag), timeout=timeout)
            if st != 200:
                raise RuntimeError("pull %s: %d %s" % (self.ref, st, p[:200]))
        elif self.kind == "load":
            c = Unix(timeout)
            try:
                c.request("POST", "/v1.47/images/load?quiet=1", body=self.archive, headers={"Content-Type": "application/x-tar"})
                r = c.getresponse()
                p = r.read()
                if r.status != 200:
                    raise RuntimeError("load: %d %s" % (r.status, p[:200]))
            finally:
                c.close()
        else:
            r = subprocess.run([DOCKER_BIN, "build", "-q", "-t", self.ref, self.ctx], capture_output=True, text=True, timeout=timeout)
            if r.returncode != 0:
                raise RuntimeError("build: %s" % (r.stderr or r.stdout)[-300:])

    def expect(self):
        if self.expected is None:
            self.expected = registry_expected(self.ref)
        return self.expected


def image_state(op):
    """'absent', 'whole', or 'broken: why' for op's image in the engine now."""
    st, _ = call("GET", "/images/%s/json" % op.ref)
    if st == 404:
        return "absent"
    if st != 200:
        return "broken: inspect answered %d" % st
    expected = op.expect()
    body = {"Image": op.ref, "Cmd": ["/bin/sh", "-c", PROBE], "Labels": {"rc-run": RUN, "rc-kind": "image-probe", "io.micropod.cache": "off"},
            "HostConfig": {"NetworkMode": "none"}}
    st, p = call("POST", "/containers/create", body)
    if st != 201:
        return "broken: create answered %d %s" % (st, p[:160].decode(errors="replace"))
    cid = json.loads(p)["Id"]
    try:
        st, p = call("POST", "/containers/%s/start" % cid)
        if st != 204:
            return "broken: start answered %d %s" % (st, p[:160].decode(errors="replace"))
        w = jcall("POST", "/containers/%s/wait" % cid, timeout=300)
        st2, raw = call("GET", "/containers/%s/logs?stdout=1&stderr=1" % cid, timeout=120)
        text = frames(raw) if st2 == 200 else ""
        if "RC-PROBE-END" not in text:
            return "broken: the probe did not run (exit %s): %s" % (w.get("StatusCode"), text.strip()[:160])
        got = {}
        for line in text.splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2 and len(parts[0]) == 64 and parts[1].startswith("/"):
                got[parts[1][1:]] = parts[0]
        bad = [k for k, v in expected.items() if k not in SKIP_PATHS and got.get(k) != v]
        if bad:
            bad.sort()
            return "broken: %d of %d files differ or are missing (%s)" % (len(bad), len(expected), ", ".join("/" + b for b in bad[:4]))
        return "whole"
    finally:
        call("DELETE", "/containers/%s?force=1" % cid)


def calibrate(kind, trial):
    """How long kind's operation takes (ms) for a before trial, measured
    without a kill: a load or a build measured by an earlier after trial, a
    pull (before trials pull larger images than after trials) on its own."""
    key = kind + "-before" if kind == "pull" else kind
    if key in durations:
        return durations[key]
    op = ImageOp(kind, trial * 100, before=True)
    t0 = time.perf_counter()
    op.run()
    durations[key] = (time.perf_counter() - t0) * 1000
    log("calibrated %s: %.0f ms (%s)" % (kind, durations[key], op.ref))
    return durations[key]


def run_image_trial(trial, kind, phase, value):
    before = phase == "before"
    budget = calibrate(kind, trial) * value if before else None
    op = ImageOp(kind, trial, before)
    vmm = my_vmm()
    if vmm is None:
        raise RuntimeError("this root's VMM is not running")
    result = {}

    def go():
        t0 = time.perf_counter()
        try:
            op.run()
            result["answered"] = time.perf_counter()
            result["ms"] = (result["answered"] - t0) * 1000
        except Exception as e:  # noqa: BLE001 - reported with the trial
            result["error"] = str(e)
    start = time.perf_counter()
    if not before:
        go()
        if "error" in result:
            raise RuntimeError(result["error"])
        if kind != "pull":
            durations.setdefault(kind, result["ms"])
        while (time.perf_counter() - result["answered"]) * 1000 < value:
            time.sleep(0.0005)
    else:
        th = threading.Thread(target=go, daemon=True)
        th.start()
        while (time.perf_counter() - start) * 1000 < budget and th.is_alive():
            time.sleep(0.0005)
    if state().get("vmmPID") != vmm:
        raise RuntimeError("the VMM changed during the trial")
    os.kill(vmm, signal.SIGKILL)
    killed = time.perf_counter()
    answered = "answered" in result and result["answered"] <= killed
    if before:
        th.join(60)
    where = ("+%.0f ms after it answered" % ((killed - result["answered"]) * 1000)) if answered else ("%.0f ms into it, unanswered" % ((killed - start) * 1000))
    log("image trial %d: %s, killed VMM %d %s (%s)" % (trial, kind, vmm, where, op.ref))
    return op, vmm, answered, where


def verify_image(trial, kind, op, vmm, answered, where):
    sec = "I%02d" % trial
    up = wait_engine(vmm)
    if not record(sec, "%s: after kill -9 %s the relaunched engine answers _ping" % (kind, where),
                  "up" if up else "no answer: " + (engine_error() or "?"), "up", up, "logs/console.log"):
        return None
    got = image_state(op)
    if answered:
        ok = record(sec, "an image whose %s answered is whole after the kill (%s)" % (kind, op.ref), got, "whole", got == "whole")
    else:
        ok = record(sec, "an image whose %s had not answered is gone or whole after the kill, never broken (%s)" % (kind, op.ref),
                    got, "absent or whole", got in ("absent", "whole"))
    try:
        op.run()
        again = image_state(op)
    except Exception as e:  # noqa: BLE001
        again = "the %s failed: %s" % (kind, str(e)[:200])
    ok &= record(sec, "%s again after the crash: the image is whole (a broken image never survives its own re-%s)" % (kind, kind),
                 again, "whole", again == "whole")
    return ok


def image_main(start_index, kills):
    all_ok = True
    for i, (kind, phase, value) in enumerate(parse_trials(IMAGE_TRIALS), start_index):
        if kills == 3:
            if not restart_machine():
                record("I%02d" % i, "the machine restarts between trials", "no answer", "up", False)
                return False, kills
            kills = 0
        kills += 1
        try:
            op, vmm, answered, where = run_image_trial(i, kind, phase, value)
        except Exception as e:  # noqa: BLE001 - a harness error is a failed check
            all_ok &= record("I%02d" % i, "the %s trial ran and the VMM is this root's" % kind, str(e)[:200], "ran", False)
            if not ping() and not wait_engine(None, 120):
                return False, kills
            continue
        try:
            ok = verify_image(i, kind, op, vmm, answered, where)
        except Exception as e:  # noqa: BLE001
            ok = record("I%02d" % i, "the image trial's checks ran", str(e)[:200], "ran", False)
        if ok is None:
            log("the engine did not come back after image trial %d; the sweep stops here" % i)
            return False, kills
        all_ok &= ok
    return all_ok, kills


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
    for i, off in enumerate(offsets if "records" in SWEEP else [], 1):
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
    if "images" in SWEEP and IMAGE_TRIALS:
        ok, kills = image_main(1, kills)
        all_ok &= ok
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
