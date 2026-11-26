"""Read-only admission and continuing contention checks for local VM measurements."""
import ctypes
import datetime
import http.client
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import struct
import subprocess
import time
import threading

LABEL = "com.skunkworq.micropod.ci-worker"
REGULAR_HOME = Path.home() / ".micropod/rig-native"
PID_NAMES = {"micropod", "fixed", "netbench", "Runner.Worker", "cuttle", "cuttlefish"}
RUNNER_ACTIONS = {"serve", "run", "start"}


def classify(name, args):
    """Only the actual executable and its argument vector may select a role."""
    head = args[1:3]
    if name == "micropod" and head == ["ci", "serve"]:
        return "Micropod CI supervisor"
    if name == "Runner.Worker":
        return "GitHub Actions job executor"
    if name == "fixed" and len(args) >= 3 and re.fullmatch(r"http://(?:127\.0\.0\.1|localhost):[1-9][0-9]*", args[1]):
        return "fixed-arrival TCP client"
    if name == "netbench" and any(x in ("-url", "--url") or x.startswith(("-url=", "--url=")) for x in args[1:]):
        return "TCP workload generator"
    if name in ("cuttle", "cuttlefish") and head[:1] in (["agent"], ["runner"]) and len(head) == 2 and head[1] in RUNNER_ACTIONS:
        return "runner control service"
    return None


def processes():
    proc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libc = ctypes.CDLL(None, use_errno=True)
    capacity = proc.proc_listallpids(None, 0)
    if capacity <= 0:
        raise OSError("cannot enumerate local process identities")
    pids = (ctypes.c_int * (capacity + 512))()
    n = proc.proc_listallpids(pids, ctypes.sizeof(pids))
    if not 0 < n < len(pids):
        raise OSError("local process inventory changed too quickly to enumerate")
    for pid in pids[:n]:
        path = ctypes.create_string_buffer(4096)
        if proc.proc_pidpath(pid, path, len(path)) <= 0:
            continue
        executable = Path(os.fsdecode(path.value))
        if executable.name not in PID_NAMES:
            continue
        # KERN_PROCARGS2 contains argv followed by the environment. Never
        # decode or record the environment or serialize the full command line.
        mib = (ctypes.c_int * 3)(1, 49, pid)
        nbytes = ctypes.c_size_t(1024 * 1024)
        buf = ctypes.create_string_buffer(nbytes.value)
        if libc.sysctl(mib, 3, buf, ctypes.byref(nbytes), None, 0) != 0:
            error = ctypes.get_errno()
            if error == 3:  # ESRCH, exited between observations
                continue
            raise OSError(f"cannot inspect {executable.name} PID {pid} (errno {error})")
        raw = buf.raw[:nbytes.value]
        argc = struct.unpack_from("i", raw)[0]
        start = raw.find(b"\0", 4)
        if not 0 < argc < 10000 or start < 4:
            raise ValueError(f"invalid arguments for {executable.name} PID {pid}")
        args = raw[start:].lstrip(b"\0").split(b"\0", argc)[:argc]
        yield pid, executable, [os.fsdecode(a) for a in args]


def role(pid):
    status = subprocess.run(["launchctl","print",f"gui/{os.getuid()}/{LABEL}"], capture_output=True, text=True, timeout=3)
    if status.returncode:
        return False
    pids = re.findall(r"(?m)^\s*pid = (\d+)\s*$", status.stdout)
    homes = re.findall(r"(?m)^\s*MICROPOD_CI_HOME => (.+)$", status.stdout)
    return pids == [str(pid)] and len(set(homes)) == 1 and Path(homes[0]).resolve() == REGULAR_HOME.resolve()


class LocalHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=2)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.path))


def read_json(sock, path):
    connection = LocalHTTP(sock)
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        if response.status != 200:
            raise ValueError(f"{sock.name} {path} returned HTTP {response.status}")
        data = response.read(8 * 1024 * 1024 + 1)
        if len(data) > 8 * 1024 * 1024:
            raise ValueError("worker workload inventory exceeds inspection limit")
        return json.loads(data)
    finally:
        connection.close()


def inventory(pid, exe, previous):
    if not role(pid):
        raise ValueError("unrecognized Micropod CI supervisor or scope")
    plist = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    original = plistlib.loads(plist.read_bytes())
    if original.get("Label") != LABEL or Path(original["ProgramArguments"][0]).resolve() != exe.resolve():
        raise ValueError("persistent worker launch identity changed")
    home = REGULAR_HOME
    session = json.loads((home / "session.json").read_bytes())
    config = json.loads((home / "worker.json").read_bytes())
    oci, docker = home / "oci.sock", home / "docker.sock"
    if not (session["started"] and session["nativeOCI"] and session["owner"]["pid"] == pid
            and session["readySocket"]["worker"] == config["worker"] and oci.is_socket() and docker.is_socket()):
        raise ValueError("persistent worker session identity unavailable")
    sockets = [(p.stat().st_dev, p.stat().st_ino) for p in (oci,docker)]
    ready = session["readySocket"]
    if sockets[0] != (ready["device"], ready["inode"]):
        raise ValueError("persistent worker OCI socket was replaced")
    key = (pid, session["instance"], *sockets)
    if previous is None or previous["key"] != key:
        info = read_json(docker, "/info")
        if info.get("ID") != config["worker"] or "io.micropod.instance=" + session["instance"] not in info.get("Labels",[]):
            raise ValueError("persistent worker Docker instance is unverified")
        if previous is not None:
            raise ValueError("persistent worker changed while measuring")
    # Read-only calls do not open OCI job sessions; optional total detects jobs
    # that open and finish between two observations of the active count.
    native = read_json(oci, "/oci/v1/status")
    active, opened = native.get("active_sessions"), native.get("opened_sessions")
    if type(active) is not int or type(opened) is not int or min(active,opened) < 0:
        raise ValueError("persistent worker omitted native job counts")
    rows = read_json(docker, "/containers/json")
    if not isinstance(rows, list) or any(not isinstance(r,dict) or not re.fullmatch("[a-f0-9]{64}", r.get("Id","")) for r in rows):
        raise ValueError("invalid persistent worker container inventory")
    if active or rows:
        ids = [r["Id"][:12] for r in rows[:8]]
        raise ValueError(f"persistent worker has {active} active OCI sessions and {len(rows)} running containers (IDs {','.join(ids) or 'none'})")
    if previous is not None and previous["opened"] != opened:
        raise ValueError("a native job opened on the persistent worker during this run")
    return {"key":key, "opened":opened, "worker":config["worker"], "instance":session["instance"]}


class Admission:
    def __init__(self, folder):
        self.folder = folder
        self.previous = None
        self.last_check = 0
        self.arms = []
        self.peer_scopes = ()
        self.own = {}
        self.receiver_group = None
        self.lock = threading.Lock()

    def own_supervisor(self, pid, exe):
        identity = (pid,str(exe))
        if identity in self.own:
            home = self.own[identity]["home"]
            session_file = home / "session.json"
            if session_file.is_file():
                session = json.loads(session_file.read_bytes())
                return session.get("owner",{}).get("pid") == pid
        for arm in self.arms:
            if not arm.get("attempted"):
                continue
            job = arm["scope"] / "job.plist"
            content = plistlib.loads(job.read_bytes())
            if Path(content["ProgramArguments"][0]).resolve() != exe.resolve():
                continue
            r = subprocess.run(["launchctl","print",arm["job"]],capture_output=True,text=True,timeout=3)
            paths = re.findall(r"(?m)^\s*path = (.+)$",r.stdout)
            if (r.returncode == 0 and re.findall(r"(?m)^\s*pid = (\d+)\s*$",r.stdout) == [str(pid)]
                    and any(Path(p).resolve() == job.resolve() for p in paths)):
                self.own[identity] = arm
                return True
        return False

    def check(self, *, force=False):
        with self.lock:
            self.observe(force=force)

    def observe(self, *, force=False):
        # One background observer per workload. Disk monitoring is independent.
        if not force and time.monotonic() - self.last_check < 2:
            return
        self.last_check = time.monotonic()
        seen, blockers = [], []
        try:
            for pid, exe, args in processes():
                tag = classify(exe.name,args)
                if not tag:
                    continue
                item = {"pid":pid, "executable":exe.name, "role":tag}
                if tag == "runner control service":
                    # A process being present cannot establish whether it accepts
                    # work. GitHub runner listeners are classified separately
                    # from their per-job Runner.Worker executors.
                    state_file = Path.home() / ".cuttlefish/agent-desktop-state.json"
                    try:
                        pause = json.loads(state_file.read_bytes()).get("workPaused")
                    except (OSError, ValueError):
                        pause = None
                    if pause is True:
                        item["work_paused"] = True
                        seen.append(item)
                    else:
                        item["reason"] = "runner intake is running with no confirmed local pause"
                        blockers.append(item)
                    continue
                if tag == "Micropod CI supervisor":
                    if self.own_supervisor(pid,exe):
                        continue
                    try:
                        self.previous = inventory(pid,exe,self.previous)
                        item.update(role="idle designated rig-native supervisor", worker=self.previous["worker"],
                                    instance=self.previous["instance"], active_oci_sessions=0, running_containers=0,
                                    opened_sessions=self.previous["opened"])
                        seen.append(item)
                    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                        item["reason"] = str(error)
                        blockers.append(item)
                    continue
                in_receiver_group = False
                if self.receiver_group is not None and tag == "fixed-arrival TCP client":
                    try:
                        in_receiver_group = self.receiver_group == os.getpgid(pid)
                    except ProcessLookupError:
                        pass
                if in_receiver_group and any(
                    (scope / "addr").is_file() and args[1:] == [
                        "http://" + (scope / "addr").read_text().strip(), (scope / "name").read_text().strip()]
                    for scope in [*(a["scope"] for a in self.arms), *self.peer_scopes]):
                    continue
                item["reason"] = "foreign timed client or active job executor"
                blockers.append(item)
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            blockers.append({"role":"workload inspection", "reason":str(error)})
        row = {"utc":datetime.datetime.now(datetime.timezone.utc).isoformat(), "observed":seen, "blockers":blockers}
        with (self.folder/"admission.jsonl").open("a") as f:
            f.write(json.dumps(row,separators=(",",":"))+"\n")
        if blockers:
            b = blockers[0]
            raise ValueError(f"local contention check: {b['role']} PID {b.get('pid','unknown')}: {b['reason']}; see admission.jsonl")
