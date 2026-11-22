#!/usr/bin/env python3
"""Read-only preflight, or a gated Micropod-only launch diagnostic and paired workspace experiment."""

import argparse
import base64
import ctypes
import hashlib
import json
import math
import os
import plistlib
import random
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import zlib
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import bench_docker_launch as launch
from bench_live_kernel import exported_config_digest, require

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "06bfc10ba545ed6a276a21e9b1dd371c00925448"
CONTROL_SHA = "77c3b71e40d2667866c8fd81368d56d39c0fa40109c32ba3f067ff3b1e538791"
TOOL_CONFIG = "sha256:73e5c74172d3555c685f3c8aad44163b52893478974e4c9926ba16a8a2c3a350"
TOOL_IMAGE = "sha256:ebc2079e1a616bf43ca219e21b53d9bac7043e71d3e2f68eebdaa8c26fed4ded"
FILES = (
    "go-app/main.go",
    "go-app/main_test.go",
    "go-app/go.mod",
    "go-app/go.sum",
    "node-app/package.json",
    "node-app/package-lock.json",
    "node-app/src/index.js",
    "node-app/test/index.test.js",
)
HELPERS = ("ci_edit_loop.py", "ci_profile_guest.py", "ci_storage_probe.py")
CONFIGS = """PSI PSI_DEFAULT_DISABLED IKCONFIG_PROC CGROUPS MEMCG BLK_CGROUP CGROUP_WRITEBACK CGROUP_SCHED
FAIR_GROUP_SCHED CFS_BANDWIDTH CPUSETS CGROUP_CPUACCT SCHEDSTATS SCHED_CLASS_EXT BLK_CGROUP_IOLATENCY
BLK_CGROUP_IOCOST IOSCHED_BFQ LRU_GEN LRU_GEN_ENABLED EXT4_FS VIRTIO_FS OVERLAY_FS OVERLAY_FS_METACOPY
OVERLAY_FS_REDIRECT_DIR TRACEPOINTS FTRACE IO_URING""".split()


def git(*args):
    return subprocess.check_output(["git", "-C", ROOT, *args])


def sha(data):
    return hashlib.sha256(data).hexdigest()


def kernel_file():
    path = Path.home() / "Library/Application Support/com.apple.container/kernels/default.kernel-arm64"
    if not path.is_file():
        return None
    data = path.read_bytes()
    i = data.find(b"IKCFG_ST\x1f\x8b")
    out = dict(file=path.resolve().name, sha256=sha(data), bytes=len(data), config=None)
    if i >= 0:
        config = zlib.decompress(data[i + 8 :], 31)
        settings = dict(re.findall(r"(?m)^CONFIG_(\w+)=(\S+)$", config.decode()))
        disabled = set(re.findall(r"(?m)^# CONFIG_(\w+) is not set$", config.decode()))
        out.update(
            config_sha256=sha(config), config={k: settings.get(k, "n" if k in disabled else None) for k in CONFIGS}
        )
    return out


def inputs(tarball):
    files = {f: git("show", f"{SOURCE}:ci/samples/{f}") for f in FILES}
    sri = json.loads(files["node-app/package-lock.json"])["packages"]["node_modules/picocolors"]["integrity"]
    h = base64.b64decode(sri.removeprefix("sha512-"), validate=True)
    key = h.hex()
    tarball = tarball or Path.home() / ".npm/_cacache/content-v2/sha512" / key[:2] / key[2:4] / key[4:]
    data = tarball.read_bytes()
    require(hashlib.sha512(data).digest() == h, "tarball differs from committed npm lock")
    files["picocolors-1.1.1.tgz"] = data
    for name in HELPERS:
        files[name] = (ROOT / "scripts" / name).read_bytes()
    return files


def host_io(pid):
    # Darwin rusage_info_v2 extends v1 (UUID plus 16 uint64s) with disk bytes.
    class Usage(ctypes.Structure):
        _fields_ = [
            ("uuid", ctypes.c_uint8 * 16),
            ("v1", ctypes.c_uint64 * 16),
            ("read_bytes", ctypes.c_uint64),
            ("write_bytes", ctypes.c_uint64),
        ]

    u = Usage()
    data = {}
    if ctypes.CDLL("/usr/lib/libproc.dylib").proc_pid_rusage(pid, 2, ctypes.byref(u)) == 0:
        data["worker_process"] = {"read_bytes": u.read_bytes, "write_bytes": u.write_bytes}
    result = subprocess.run(
        ["/usr/sbin/ioreg", "-a", "-r", "-c", "IOBlockStorageDriver", "-d", "1"], capture_output=True, timeout=10
    )
    if result.returncode or not result.stdout:
        return data or None
    try:
        disks = plistlib.loads(result.stdout)
    except (ValueError, plistlib.InvalidFileException):
        return data or None
    keys = ("Bytes (Read)", "Bytes (Write)", "Operations (Read)", "Operations (Write)")
    data.update(
        {
            "device_" + str(e["IORegistryEntryID"]): {k: e["Statistics"].get(k) for k in keys}
            for e in disks
            if "IORegistryEntryID" in e and "Statistics" in e
        }
    )
    return data or None


def spread(values):
    if not values:
        return dict(n=0, p50=None, p95=None, maximum=None)
    s = sorted(values)
    return dict(n=len(s), p50=statistics.median(s), p95=s[math.ceil(0.95 * len(s)) - 1], maximum=max(s))


def account(cg):
    """Flatten cumulative fields only. Memory sizes and effective limits stay as raw gauges."""
    result = {}
    for key in ("cpu.stat", "memory.events"):
        for line in (cg.get(key) or "").splitlines():
            name, val = line.split()
            result[key + "/" + name] = int(val)
    for key in ("cpu.pressure", "memory.pressure", "io.pressure"):
        for line in (cg.get(key) or "").splitlines():
            level, *fields = line.split()
            result[key + "/" + level + "_us"] = int(dict(f.split("=") for f in fields)["total"])
    for line in (cg.get("io.stat") or "").splitlines():
        dev, *fields = line.split()
        for field in fields:
            k, v = field.split("=")
            result["io.stat/" + dev + "/" + k] = int(v)
    for k in ("workingset_refault_file", "pgscan", "pgsteal", "pgmajfault"):
        if k in (cg.get("memory.stat") or {}):
            result["memory.stat/" + k] = cg["memory.stat"][k]
    return result


def difference(before, after):
    return {k: after[k] - v for k, v in before.items() if k in after and after[k] >= v}


def cgroup_delta(before, after):
    a, b = account(before), account(after)
    if before.get("io.stat") is not None:
        for k in b:
            if k.startswith("io.stat/"):
                a.setdefault(k, 0)
    return difference(a, b)


def kernel_delta(before, after):
    out = {"vm": difference(before.get("vm", {}), after.get("vm", {}))}
    out["pressure_us"] = {
        kind: difference(prev, after["pressure_us"][kind])
        for kind, prev in before.get("pressure_us", {}).items()
        if kind in after.get("pressure_us", {})
    }
    out["block_devices"] = {}
    for dev, prev in before.get("disk", {}).items():
        if dev not in after.get("disk", {}):
            continue
        delta = difference(prev, after["disk"][dev])
        for op in ("read", "write"):
            if op + "_sectors" in delta:
                delta[op + "_bytes"] = 512 * delta[op + "_sectors"]
        out["block_devices"][dev] = delta
    for k in ("uptime", "context_switches", "forks"):
        if k in before and k in after:
            out[k if k != "uptime" else "sampled_s"] = after[k] - before[k]
    return out


def event_spans(raw):
    result = {}
    for line in raw.splitlines():
        e = json.loads(line)
        if e.get("Type") != "container" or e.get("Action") not in ("create", "start", "die", "destroy"):
            continue
        actor = e["Actor"]
        entry = result.setdefault(actor["ID"], dict(name=actor["Attributes"].get("name"), events={}))
        entry["events"][e["Action"]] = int(e["timeNano"])
    for c in result.values():
        times = c["events"]
        for a, b in (("create", "start"), ("start", "die"), ("die", "destroy")):
            c[a + "_to_" + b + "_ms"] = (times[b] - times[a]) / 1e6 if a in times and b in times else None
    return result


def cache_key(scope, identity, lock_hashes):
    data = dict(
        schema=1,
        trust="dedicated-trusted-fixture",
        scope=scope,
        identity=identity,
        config=TOOL_CONFIG,
        flags="-p=1 -trimpath -mod=readonly -buildvcs=false",
        cgo="0",
        npm="ci --offline",
        locks=lock_hashes,
    )
    return sha(json.dumps(data, sort_keys=True).encode())


def run(args, r, save):
    require(args.slot_released, "TCP owner release is required")
    home = args.worker_home.resolve()
    sock = home / "docker.sock"
    require(sock.is_socket() and (home / "session.json").is_file(), "Dedicated worker session/socket absent")
    require(
        launch.platform.system() == "Darwin" and launch.platform.machine() == "arm64", "Apple Silicon Mac required"
    )
    docker = str(Path(shutil.which(args.docker) or args.docker).resolve(strict=True))
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOCKER_", "MICROPOD_CI_"))}
    env.update(LC_ALL="C", MICROPOD_CI_HOME=str(home), MICROPOD_CI_ENGINE="docker")
    prefix = [docker, "--host", "unix://" + str(sock)]

    def cmd(argv, payload=None, timeout=90):
        p = subprocess.run(argv, env=env, input=payload, capture_output=True, timeout=timeout)
        require(
            p.returncode == 0,
            f"{argv[0]} {argv[1:4]} exit {p.returncode}: {p.stderr[-750:].decode(errors='replace')}",
        )
        return p.stdout.decode().strip()

    def cli(*argv, **opts):
        return cmd([*prefix, *argv], **opts)

    st = sock.stat()
    owner = json.loads((home / "session.json").read_text())["owner"]

    def check_socket():
        now = sock.stat()
        require(
            (st.st_dev, st.st_ino) == (now.st_dev, now.st_ino)
            and json.loads((home / "session.json").read_text())["owner"] == owner,
            "Dedicated endpoint/owner changed",
        )

    observer = None

    def idle():
        check_socket()
        allowed = {observer} if observer else set()
        require(set(cli("ps", "-q", "--no-trunc").split()) == allowed, "Unrelated workload or missing observer")
        pct = launch.cpu_idle()
        require(pct >= launch.IDLE_FLOOR, f"Host idle {pct}% below floor")
        return pct

    idle()
    r["client"] = launch.stock_client(docker, env)
    config = r["local"]["micropod_config"]
    info = json.loads(cli("info", "--format", "{{json .}}"))
    launch.resources(config["cpus"], config["memoryMiB"], info)
    r["docker_engine"] = {
        key: info.get(key)
        for key in (
            "ID",
            "Architecture",
            "KernelVersion",
            "Driver",
            "DriverStatus",
            "CgroupDriver",
            "CgroupVersion",
            "NCPU",
            "MemTotal",
            "DefaultRuntime",
            "OperatingSystem",
        )
    }
    status = json.loads(cmd([args.micropod, "ci", "status"]))
    require(
        status["daemon"] == info["ID"]
        and status["worker"].lower() == config["worker"].lower()
        and status["endpoint"] == prefix[2]
        and status["engine"] == "docker",
        "Worker/daemon identity mismatch",
    )
    r["worker"] = status
    r["docker_versions"] = json.loads(cli("version", "--format", "{{json .}}"))
    r["supervisor_source"] = "unattested"
    # Bind an operator's existing build receipt to the running executable. A client hash alone is insufficient.
    if args.build_receipt:
        buf = ctypes.create_string_buffer(4096)
        lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        require(lib.proc_pidpath(owner["pid"], buf, len(buf)) > 0, "Cannot identify supervisor executable")
        path = Path(os.fsdecode(buf.value))
        att = json.loads(args.build_receipt.read_text())
        with path.open("rb") as exe:
            st_exe = os.fstat(exe.fileno())
            mapped = cmd(["/usr/sbin/lsof", "-nP", "-a", "-p", str(owner["pid"]), "-d", "txt", "-FfDi"])
            records = re.split(r"(?m)^f[^\n]*\n", mapped)[1:]
            vnodes = [dict((line[0], line[1:]) for line in rec.splitlines() if line) for rec in records]
            require(
                any(
                    "D" in v and "i" in v and (int(v["D"], 0), int(v["i"])) == (st_exe.st_dev, st_exe.st_ino)
                    for v in vnodes
                ),
                "Cannot bind running executable vnode to build receipt",
            )
            require(
                att["worker_executable_sha256"] == sha(exe.read()) and att["source_revision"] == SOURCE,
                "Supervisor build does not match study source",
            )
        r["supervisor_source"] = dict(
            source=SOURCE, executable_sha256=att["worker_executable_sha256"], pid=owner["pid"]
        )
    files = inputs(args.npm_tarball)
    r["input_sha256"] = {k: sha(v) for k, v in files.items()}
    images = {}
    for ref, expected in ((launch.IMAGE, launch.CONFIG), (args.image, TOOL_CONFIG)):
        obj = json.loads(cli("image", "inspect", ref))[0]
        require(obj["Architecture"] == "arm64" and obj["Os"] == "linux", "Wrong image platform")
        if ref == launch.IMAGE:
            require(
                any(t.endswith("@" + ref.split("@")[1]) for t in obj.get("RepoDigests", [])),
                "Wrong Alpine manifest",
            )
        require(exported_config_digest(prefix, obj["Id"], "arm64", env) == expected, "Wrong native OCI config")
        images[ref] = obj["Id"]
    img = images[args.image]
    r["local_images"] = images
    base = "mp-edit-" + r["run"]
    label = "io.micropod.edit-research=" + r["run"]
    launch_labels = []

    def volume(name):
        require(cli("volume", "create", "--label", label, name) == name, "Unexpected volume name")
        return name

    def mount(name, dest, ro=False):
        return ["--mount", f"type=volume,src={name},dst={dest},volume-nocopy" + (",readonly" if ro else "")]

    flags = [
        "--platform",
        "linux/arm64",
        "--pull=never",
        "--network",
        "none",
        "--cpus",
        "1",
        "--memory",
        "1g",
        "--label",
        label,
    ]
    tool_env = [
        "-e",
        "GOOS=linux",
        "-e",
        "GOARCH=arm64",
        "-e",
        "GOARM64=v8.0",
        "-e",
        "CGO_ENABLED=0",
        "-e",
        "GOTOOLCHAIN=local",
        "-e",
        "GOENV=off",
        "-e",
        "GOTELEMETRY=off",
        "-e",
        "PYTHONDONTWRITEBYTECODE=1",
    ]

    def active_events(start, end, needle):
        return event_spans(
            cli(
                "events",
                "--since",
                f"{start:.9f}",
                "--until",
                f"{end:.9f}",
                "--filter",
                "type=container",
                "--filter",
                "label=" + needle,
                "--format",
                "{{json .}}",
            )
        )

    def window(needle, execute, report):
        report["idle_pct"] = idle()
        report["guest_before"] = json.loads(cli("exec", observer, "python3", "/inputs/ci_edit_loop.py", "kernel"))
        report["host_before"] = host_io(owner["pid"])
        start = time.time()
        execute()
        end = time.time()
        report["host_after"] = host_io(owner["pid"])
        report["guest_after"] = json.loads(cli("exec", observer, "python3", "/inputs/ci_edit_loop.py", "kernel"))
        report["guest_delta"] = kernel_delta(report["guest_before"], report["guest_after"])
        h1, h2 = report["host_before"], report["host_after"]
        report["host_io_delta"] = (
            {
                d: difference(
                    {k: v for k, v in h1[d].items() if v is not None},
                    {k: v for k, v in h2[d].items() if v is not None},
                )
                for d in h1.keys() & h2.keys()
            }
            if h1 and h2
            else None
        )
        report["containers"] = active_events(start, end, needle)
        report["observed_lifecycles"] = sum(len(c["events"]) == 4 for c in report["containers"].values())
        save()

    def clean():
        check_socket()
        for owned in [label, *launch_labels]:
            active = cli("ps", "-aq", "--no-trunc", "--filter", "label=" + owned).split()
            if active:
                cli("rm", "-fv", *active)
        own = cli("volume", "ls", "-q", "--filter", "label=" + label).split()
        if own:
            cli("volume", "rm", *own)
        require(
            not cli("ps", "-aq", "--filter", "label=" + label)
            and not cli("volume", "ls", "-q", "--filter", "label=" + label),
            "Run-owned objects remain",
        )

    try:
        src = volume(base + "-inputs")
        payload = json.dumps({p: base64.b64encode(v).decode() for p, v in files.items()}).encode()
        unpack = "import json,sys,base64,pathlib\nfor name,v in json.load(sys.stdin).items():\n p=pathlib.Path('/inputs')/name; p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(base64.b64decode(v,validate=True))"
        cli("run", "--rm", "-i", *flags, *mount(src, "/inputs"), img, "python3", "-c", unpack, payload=payload)
        read = mount(src, "/inputs", True)
        observer = cli("run", "--rm", "-d", "--read-only", *flags, *tool_env, *read, img, "sleep", "14400")
        boot = status["boot"].lower()
        proof = json.loads(cli("exec", observer, "python3", "/inputs/ci_edit_loop.py", "kernel"))
        require(proof["boot"] == boot, "Observer in wrong kernel")
        r["kernel"] = proof
        r["guest_kernel_identity"] = json.loads(
            cli("exec", observer, "python3", "/inputs/ci_edit_loop.py", "kernel-id")
        )
        identity = json.loads(cli("exec", observer, "python3", "/inputs/ci_edit_loop.py", "identity"))
        r["toolchain"] = identity
        locks = {
            p: r["input_sha256"][p]
            for p in FILES
            if p.endswith((".mod", ".sum", "package.json", "package-lock.json"))
        }
        ns = cache_key(r["run"], identity, locks)
        r["cache_key"] = ns
        socketmap = {launch.MIC: sock}
        for width in args.clients:
            for warm in (True, False):
                tag = "io.micropod.edit-launch=" + r["run"] + f"-{width}-{int(warm)}"
                launch_labels.append(tag)

                def build(_, token):
                    return launch.argv(launch.MIC, docker, None, socketmap, tag, token)

                row = dict(clients=width, phase="warmup" if warm else "diagnostic")
                r["launches"].append(row)

                def measure_launch():
                    row.update(launch.batch(launch.MIC, width, "launch", build, dict(env, CONTROL_BOOT=boot)))

                window(tag, measure_launch, row)
                require(all(j["ok"] for j in row["jobs"]), "Alpine assertion failed")

        for block, width, storage in r["schedule"]:
            cohort = volume(f"{base}-{ns[:8]}-{block}-{width}-{storage}-cache")
            cm = mount(cohort, "/cache")

            def audit():
                return json.loads(
                    cli(
                        "run",
                        "--rm",
                        *flags,
                        *read,
                        *mount(cohort, "/cache", True),
                        img,
                        "python3",
                        "-B",
                        "/inputs/ci_edit_loop.py",
                        "audit",
                        "/cache",
                    )
                )

            for phase in ("cold", "edit", "repeat"):
                marker = "base" if phase == "cold" else f"edit-{block}-{width}"
                before = audit()
                if phase == "cold":
                    require(
                        not any(s["files"] for s in before["stores"].values()), "Cold cohort already populated"
                    )
                tag = "io.micropod.edit-batch=" + uuid.uuid4().hex
                row = dict(
                    block=block,
                    clients=width,
                    storage=storage,
                    phase=phase,
                    revision=marker,
                    store_before=before["stores"],
                    jobs=[],
                )
                r["batches"].append(row)

                def one(i):
                    name = f"{base}-{block}-{width}-{storage}-{phase}-{i}"
                    work = name + "-work"
                    j = dict(index=i, name=name, ok=False)
                    gate.wait()
                    begin = time.monotonic()
                    try:
                        opt = []
                        if storage == "volume":
                            cli("volume", "create", "--label", label, work)
                            opt = mount(work, "/job")
                        t = time.monotonic()
                        result = json.loads(
                            cli(
                                "run",
                                "--rm",
                                "--name",
                                name,
                                *flags,
                                "--label",
                                tag,
                                *tool_env,
                                "-e",
                                "CONTROL_BOOT=" + boot,
                                "-e",
                                "CONTROL_STORAGE=" + storage,
                                *read,
                                *cm,
                                *opt,
                                img,
                                "python3",
                                "-B",
                                "/inputs/ci_edit_loop.py",
                                "job",
                                marker,
                                timeout=420,
                            )
                        )
                        j.update(container_s=time.monotonic() - t, guest=result, ok=True)
                    except (ValueError, OSError, subprocess.SubprocessError) as e:
                        j["error"] = str(e)[-1200:]
                    finally:
                        if storage == "volume":
                            try:
                                cli("volume", "rm", work)
                            except (ValueError, OSError, subprocess.SubprocessError) as e:
                                j.update(ok=False, cleanup_error=str(e)[-800:])
                    j["client_s"] = time.monotonic() - begin
                    return j

                def measure_jobs():
                    nonlocal gate
                    starts = []
                    gate = threading.Barrier(width + 1, action=lambda: starts.append(time.monotonic()))
                    with ThreadPoolExecutor(max_workers=width) as pool:
                        fs = [pool.submit(one, i) for i in range(width)]
                        gate.wait()
                        row["jobs"] = [f.result() for f in fs]
                        row["batch_s"] = time.monotonic() - starts[0]

                gate = None
                window(tag, measure_jobs, row)
                row["store_after"] = audit()["stores"]
                all_refs = set()
                for j in row["jobs"]:
                    if "guest" not in j:
                        continue
                    g = j["guest"]
                    g["cgroup_delta"] = cgroup_delta(g["cgroup_before"], g["cgroup_after"])
                    refs = set(g.pop("go_import_refs")) & before["objects"].keys()
                    all_refs.update(refs)
                    g["go_preexisting_imports"] = len(refs)
                    g["go_hit_bytes_lower_bound"] = sum(before["objects"][ref] for ref in refs)
                row["unique_go_hit_bytes_lower_bound"] = sum(before["objects"][ref] for ref in all_refs)
                row["client_s"] = spread([j["client_s"] for j in row["jobs"]])
                row["failed"] = sum(not j["ok"] for j in row["jobs"])
                save()
                require(not cli("ps", "-aq", "--filter", "label=" + tag), "Job containers remain after batch")
                require(not row["failed"], "Edit-build failed, remaining jobs unscheduled")
            cli("volume", "rm", cohort)
        if args.storage_probes:
            import ci_storage_probe

            paths = r["storage_probes"] = []
            scratch = volume(base + "-storage")
            share = json.loads((home / "worker.json").read_text()).get("workspace")
            parent = args.workspace_parent.resolve() if args.workspace_parent else None
            if parent:
                require(
                    share and parent.is_relative_to(Path(share).resolve()), "Outside existing configured workspace"
                )
            with tempfile.TemporaryDirectory(dir=parent) as tmp:
                root = Path(tmp)
                locations = ["guest-volume", "guest-overlay"]
                try:
                    dev = cmd(["/bin/df", "-P", str(root)]).splitlines()[-1].split()[0]
                    fs = plistlib.loads(
                        subprocess.check_output(
                            ["/usr/sbin/diskutil", "info", "-plist", dev], timeout=15, stderr=subprocess.PIPE
                        )
                    )
                    fs_type = fs.get("FilesystemType", "")
                    r["host_probe_filesystem"] = {"device": dev, "type": fs_type}
                    if fs_type.lower() == "apfs":
                        locations.insert(0, "host-apfs")
                    else:
                        r["host_probe_filesystem"]["reason"] = "Scratch is not on verified APFS"
                except (
                    OSError,
                    ValueError,
                    IndexError,
                    plistlib.InvalidFileException,
                    subprocess.SubprocessError,
                ) as error:
                    r["host_probe_filesystem"] = {"type": None, "reason": str(error)}
                if parent:
                    locations.append("workspace")
                r["shared_workspace_probe"] = (
                    "enabled" if parent else "no approved existing workspace path supplied"
                )
                for i in range(args.probe_rounds):
                    for loc in locations if i % 2 == 0 else locations[::-1]:
                        idle()
                        for method in ("private", "clone") if i % 2 == 0 else ("clone", "private"):
                            if loc == "host-apfs":
                                value = ci_storage_probe.probe(root, 1, method)
                            else:
                                opt = (
                                    mount(scratch, "/probe")
                                    if loc == "guest-volume"
                                    else ["--mount", f"type=bind,src={root},dst=/probe"]
                                    if loc == "workspace"
                                    else []
                                )
                                where = "/tmp" if loc == "guest-overlay" else "/probe"
                                expected = {
                                    "guest-overlay": "overlay",
                                    "guest-volume": "ext4",
                                    "workspace": "virtiofs",
                                }[loc]
                                value = json.loads(
                                    cli(
                                        "run",
                                        "--rm",
                                        *flags,
                                        *read,
                                        *opt,
                                        img,
                                        "python3",
                                        "-B",
                                        "/inputs/ci_storage_probe.py",
                                        where,
                                        "--method",
                                        method,
                                        "--rounds",
                                        "1",
                                        "--expect-fs",
                                        expected,
                                    )
                                )
                            paths.append(dict(round=i + 1, path=loc, method=method, result=value))
                            save()
            for method in ("lower-read", "lower-rewrite"):
                idle()
                cid = cli(
                    "create",
                    *flags,
                    *read,
                    "-e",
                    "MP_PRIVATE_COPYUP=1",
                    img,
                    "python3",
                    "-B",
                    "/inputs/ci_storage_probe.py",
                    "/tmp",
                    "--method",
                    method,
                )

                def size():
                    return int(cli("inspect", "--size", "--format", "{{.SizeRw}}", cid))

                before = size()
                result = json.loads(cli("start", "-a", cid))
                require(cli("inspect", "--format", "{{.State.ExitCode}}", cid) == "0", "Lower file probe failed")
                paths.append(
                    dict(
                        path="image-lower",
                        method=method,
                        before_rw_bytes=before,
                        after_rw_bytes=size(),
                        changed_paths=cli("diff", cid).splitlines(),
                        result=result,
                    )
                )
                cli("rm", cid)
                save()
        require(json.loads(cli("info", "--format", "{{json .ID}}")) == info["ID"], "Daemon changed")
    except BaseException as error:
        r["experiment_error"] = str(error) or type(error).__name__
        raise
    finally:
        try:
            clean()
        except (ValueError, OSError, subprocess.SubprocessError) as e:
            r["cleanup_error"] = str(e)
            raise


def summarize(r):
    groups = {}
    for b in r["batches"]:
        groups.setdefault((b["block"], b["clients"], b["phase"]), {})[b["storage"]] = b
    pairs = []
    comparison_failures = []
    for (block, width, phase), g in groups.items():
        if set(g) != {"overlay", "volume"}:
            continue
        a, b = g["overlay"], g["volume"]
        if any(x.get("failed", 1) for x in (a, b)):
            continue
        hashes = {j["guest"]["go_sha256"] for x in (a, b) for j in x["jobs"]}
        outputs = {j["guest"]["node_output"] for x in (a, b) for j in x["jobs"]}
        if len(hashes) != 1 or len(outputs) != 1:
            comparison_failures.append(
                dict(block=block, clients=width, phase=phase, error="Arms returned different products")
            )
            continue
        pairs.append(
            dict(
                block=block,
                clients=width,
                phase=phase,
                go_sha256=hashes.pop(),
                matched_idle=abs(a["idle_pct"] - b["idle_pct"]) <= launch.IDLE_GAP,
                volume_minus_overlay_s=b["batch_s"] - a["batch_s"],
            )
        )
    for key in {(p["block"], p["clients"]) for p in pairs}:
        h = {p["phase"]: p["go_sha256"] for p in pairs if (p["block"], p["clients"]) == key}
        if len(h) == 3 and not (h["cold"] != h["edit"] == h["repeat"]):
            comparison_failures.append(
                dict(block=key[0], clients=key[1], phase="all", error="Go product did not follow the edit")
            )
            pairs = [p for p in pairs if (p["block"], p["clients"]) != key]
    jobs = [j for b in r["batches"] for j in b["jobs"]]
    arms = {}
    for width in sorted({w for _, w, _ in r["schedule"]}):
        for storage in ("volume", "overlay"):
            for phase in ("cold", "edit", "repeat"):
                bs = [
                    b for b in r["batches"] if (b["clients"], b["storage"], b["phase"]) == (width, storage, phase)
                ]
                js = [j for b in bs for j in b["jobs"]]
                ds = [j["guest"] for j in js if j["ok"]]
                arms[f"{width}/{storage}/{phase}"] = dict(
                    attempted=len(js),
                    failed=sum(not j["ok"] for j in js),
                    batch_s=spread([b["batch_s"] for b in bs if "batch_s" in b]),
                    first_attempt_client_s=spread([j["client_s"] for j in js]),
                    npm_payload_hits=sum(g["npm_hit_at_seed"] for g in ds) if ds else None,
                    npm_payload_hit_bytes=sum(g["npm_payload_bytes"] for g in ds if g["npm_hit_at_seed"])
                    if ds
                    else None,
                    go_confirmed_hit_bytes=sum(
                        g["go_hit_bytes_lower_bound"] for g in ds if "go_hit_bytes_lower_bound" in g
                    )
                    if ds and all("go_hit_bytes_lower_bound" in g for g in ds)
                    else None,
                )
    launches = [j for b in r["launches"] for j in b.get("jobs", [])]
    matched = {
        f"{w}/{phase}": spread(
            [
                p["volume_minus_overlay_s"]
                for p in pairs
                if p["clients"] == w and p["phase"] == phase and p["matched_idle"]
            ]
        )
        for w in sorted({w for _, w, _ in r["schedule"]})
        for phase in ("cold", "edit", "repeat")
    }
    return dict(
        pairs=pairs,
        comparison_failures=comparison_failures,
        paired_spread_s=matched,
        attempted=len(jobs),
        failed=sum(not j["ok"] for j in jobs),
        unattempted=sum(3 * w for _, w, _ in r["schedule"]) - len(jobs),
        arms=arms,
        alpine_attempted=len(launches),
        alpine_failed=sum(not j["ok"] for j in launches),
    )


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("mode", choices=("inspect", "run"))
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--worker-home", type=Path, default=Path.home() / ".micropod/ci")
    p.add_argument("--clients", type=int, choices=(1, 16), nargs="+", default=[1])
    p.add_argument("--blocks", type=int, default=1)
    p.add_argument("--seed", type=int, default=20261122)
    p.add_argument("--slot-released", action="store_true")
    p.add_argument("--image", default=TOOL_IMAGE)
    p.add_argument("--docker", default="docker")
    p.add_argument("--micropod", default="micropod")
    p.add_argument("--npm-tarball", type=Path)
    p.add_argument("--build-receipt", type=Path)
    p.add_argument(
        "--storage-probes", action="store_true", help="separate disposable diagnostics after the timed loop"
    )
    p.add_argument(
        "--workspace-parent", type=Path, help="existing approved directory in the configured virtiofs checkout"
    )
    p.add_argument("--probe-rounds", type=int, default=4)
    a = p.parse_args()
    if a.blocks < 1 or a.probe_rounds < 1 or a.clients not in ([1], [1, 16]):
        p.error("select 1 or 1 16 clients and positive rounds")
    with a.output.open("x"):
        pass
    home = a.worker_home.resolve()
    rng = random.Random(a.seed)
    first = rng.randrange(2)
    schedule = []
    for i in range(a.blocks):
        for w in a.clients if i % 2 == 0 else a.clients[::-1]:
            for s in ("overlay", "volume") if (first + i + (w == 16)) % 2 == 0 else ("volume", "overlay"):
                schedule.append((i + 1, w, s))
    r = dict(
        run=uuid.uuid4().hex,
        at=datetime.now(timezone.utc).isoformat(),
        fixture_source=SOURCE,
        checkout_head_at_capture=git("rev-parse", "HEAD").decode().strip(),
        harness_sha256=sha(Path(__file__).read_bytes()),
        control_sha256=sha((ROOT / "scripts/bench_docker_launch.py").read_bytes()),
        schedule=schedule,
        seed=a.seed,
        launches=[],
        batches=[],
        tcp_released=a.slot_released,
        mode=a.mode,
    )

    def save():
        tmp = a.output.with_name(a.output.name + "." + r["run"] + ".tmp")
        tmp.write_text(json.dumps(r, indent=2) + "\n")
        tmp.replace(a.output)

    try:
        require(r["control_sha256"] == CONTROL_SHA, "Alpine control source changed")
        r["local"] = launch.local_state(
            home, {launch.MIC: home / "docker.sock", launch.ORB: Path.home() / ".orbstack/run/docker.sock"}
        )
        r["kernel_on_disk"] = kernel_file()
        r["blockers"] = []
        if not a.slot_released:
            r["blockers"].append("No TCP-owner slot release supplied")
        if not r["local"]["micropod_session"]:
            r["blockers"].append("Dedicated worker session absent")
        if not r["local"]["sockets"][launch.MIC]["present"]:
            r["blockers"].append("Dedicated Docker socket absent")
        r["state"] = (
            "local-paths-present"
            if r["local"]["micropod_session"] and r["local"]["sockets"][launch.MIC]["present"]
            else "blocked"
        )
        if a.mode == "run":
            require(r["state"] != "blocked", "Dedicated session/socket missing")
            run(a, r, save)
            r["state"] = "complete"
    except (ValueError, OSError, KeyError, subprocess.SubprocessError, KeyboardInterrupt) as e:
        r.update(state="failed" if r["launches"] or r["batches"] else "blocked", error=str(e) or type(e).__name__)
    try:
        r["summary"] = summarize(r)
        if r["summary"]["comparison_failures"]:
            r.update(state="failed", error="Cross-arm output or revision check failed")
    except ValueError as e:
        r.update(state="failed", error=str(e))
    save()
    print(r["state"], a.output)
    return 0 if r["state"] in ("complete", "local-paths-present") else 1


if __name__ == "__main__":
    sys.exit(main())
