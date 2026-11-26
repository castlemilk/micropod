#!/usr/bin/env python3
"""Provision and verify an isolated local Micropod stock fixture on its Mac."""
import argparse
from contextlib import contextmanager, nullcontext
from copy import copy
from local_admission import Admission
from local_launch_state import launch_fields, worker_exit
import ctypes
import datetime
import fcntl
import hashlib
import gzip
import io
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
TREE = HERE.parents[3]
BUILDS = TREE / ".build/local-published-tcp"
RECOVERY = BUILDS / "20261124-after-restart"
PREVIOUS = HERE / "20261124T062433Z"
PINNED = json.loads((PREVIOUS / "inputs.json").read_text())
BUILD_NAME = {"baseline": "revised-runtime-build.json", "diagnostic": "revised-runtime-build.json",
              "host-role": "revised-runtime-build.json", "workers": "fixed-workers-runtime-build.json"}
GUEST_FACTS = TREE.parent / "kernel-path-20261122/scripts/kernel_path/guest-facts.sh"
ALPINE = "docker.io/library/alpine@sha256:469c9ea410b9215eaee7976ba6c0639039b444be8e5d638f7abbada189971eb2"
SERVICE = "micropod-qa/netbench:local"
PAUSE = "registry.k8s.io/pause:3.10.2"
REEXPORT = "36703da965e7e5fb09d6e31c533deae862cedb8596e6716aa76c9e67df49f6fa"
MNF = "43c8761c8d7d97587c47c1b2a8f87941c24d919cb89b1d9268592dbc4025e93f"
LAYER = "7d4ee779f04af2802fa3613187490f443211d116770559941ad4094137353af4"
DIFF = "10c006a76139719b46481f0aae7c28347652a64ada716100689265b4a9b387b7"
SERVER = "11616563078329f6d13d5c3b50628c57b431537c2fbd05dda7d8136d5f4572ba"

STOCK_CONFIG_SHA256 = "a0da9a6ab98e69e253f2e8a27664bdb23f08ab4cef1dd66178c38c26d0035c9c"
SOCKET_INVENTORY_SHA256 = "bc63f5f9c68e440a02c8ec204d812b1b81e950303529fd8782d0a580435b87c2"


def check_socket_evidence(config, policy, *, check_inputs):
    disabled = "# CONFIG_INET_DIAG is not set"
    states = [line for line in config.read_text().splitlines()
              if line == disabled or line.startswith("CONFIG_INET_DIAG=")]
    compiled_out = states == [disabled]
    if policy == "route":
        require(digest(config) == STOCK_CONFIG_SHA256 and compiled_out,
                "route evidence requires the pinned stock kernel config with CONFIG_INET_DIAG compiled out")
    elif compiled_out and not check_inputs:
        raise ValueError("The stock kernel has CONFIG_INET_DIAG compiled out. To measure delivery with "
                         "route-policy evidence, select --socket-evidence route. Direct sender-controller "
                         "verification requires an independently qualified observable configuration.")
    return compiled_out


def verify_service(path):
    out = {}
    with tarfile.open(path) as tar:
        def blob(descriptor, expected):
            require(descriptor["digest"] == "sha256:" + expected, "netbench OCI descriptor mismatch")
            b = tar.extractfile("blobs/sha256/" + expected).read()
            require(len(b) == descriptor["size"] and hashlib.sha256(b).hexdigest() == expected, "corrupt netbench OCI blob")
            return b
        idx = json.load(tar.extractfile("index.json"))
        desc, = idx["manifests"]
        manifest = json.loads(blob(desc, MNF))
        cfg = json.loads(blob(manifest["config"], PINNED["image_config_sha256"]))
        require(cfg["architecture"] == "arm64" and cfg["os"] == "linux" and cfg["rootfs"]["diff_ids"] == ["sha256:" + DIFF],
                "netbench OCI platform or rootfs mismatch")
        layer, = manifest["layers"]
        unpacked = gzip.decompress(blob(layer, LAYER))
        require(hashlib.sha256(unpacked).hexdigest() == DIFF, "corrupt uncompressed netbench layer")
        with tarfile.open(fileobj=io.BytesIO(unpacked)) as image:
            elf, = [f for f in image.getmembers() if f.isfile() and f.name.lstrip("./") == "netbench"]
            require(hashlib.sha256(image.extractfile(elf).read()).hexdigest() == SERVER, "historical service binary mismatch")
        docker = json.load(tar.extractfile("manifest.json"))
        recorded, = docker
        require(any(tag.removeprefix("docker.io/") == SERVICE for tag in recorded["RepoTags"]), "wrong netbench archive tag")
    return dict(manifest=MNF, config=PINNED["image_config_sha256"], compressed_layer=LAYER, diff_id=DIFF, netbench=SERVER, archive=digest(path))


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def save(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def require(ok, why):
    if not ok:
        raise ValueError(why)


def digest(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def invoke(*args, env=None, timeout=90, check=True):
    p = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=timeout, env=env)
    if check and p.returncode:
        raise RuntimeError(f"{Path(args[0]).name} exited {p.returncode}: {p.stderr.strip()[-1200:]}")
    return p


def bootstrap_worker(job_id, plist, manifest):
    domain = job_id.rsplit("/", 1)[0]
    result = invoke("launchctl", "bootstrap", domain, plist, check=False)
    if result.returncode == 0:
        return
    receipt = {"job": job_id, "prior_service": "absent", "bootstrap_exit": result.returncode,
               "bootstrap_stderr": result.stderr.strip()}
    # Exit 5 is ambiguous. Keep the original launchd message and distinguish
    # denied capability readback from a Mac reporting no hypervisor support.
    detail = ""
    if result.returncode == 5:
        try:
            hv = invoke("sysctl", "-n", "kern.hv_support", check=False, timeout=3)
            receipt["kern.hv_support"] = {"exit": hv.returncode, "stdout": hv.stdout.strip(), "stderr": hv.stderr.strip()}
            if hv.returncode and "Operation not permitted" in hv.stderr:
                detail = " This executor also denied the host capability check. This benchmark needs an approved host run."
        except (OSError, subprocess.SubprocessError) as exc:
            receipt["capability_check_error"] = str(exc)
    path = manifest / "bootstrap.json"
    save(path, receipt)
    summary = result.stderr.strip().splitlines()
    reason = summary[0] if summary else "no diagnostic from launchctl"
    raise RuntimeError(f"launchctl bootstrap exited {result.returncode} for {job_id}: {reason}.{detail} See {path}")


def log_tail(path):
    try:
        with path.open("rb") as log:
            log.seek(max(0, os.fstat(log.fileno()).st_size - 1200))
            return log.read(1200).decode(errors="replace").strip()
    except OSError:
        return ""


def receiver_failure(folder):
    status_path = folder / "receiver/status.json"
    try:
        status = json.loads(status_path.read_bytes())
    except (OSError, ValueError):
        status = None
    reason = status.get("error") if isinstance(status, dict) else None
    if isinstance(reason, str) and reason.strip():
        return f"{reason.strip()[-1200:]} (see {status_path})"
    stderr = folder / "receiver.stderr"
    return f"{log_tail(stderr)} (see {stderr})".strip()


def wait_for_worker(home, manifest, job_id, guard):
    deadline = time.monotonic() + 180
    previous = None
    with (manifest / "launch-state.jsonl").open("x") as history:
        while True:
            guard()
            try:
                session = json.loads((home / "session.json").read_bytes())
            except (FileNotFoundError, json.JSONDecodeError):
                session = {}
            if session.get("started") and (home / "docker.sock").is_socket():
                history.write(json.dumps(dict(time=now(), ready=True)) + "\n")
                return session
            status = invoke("launchctl", "print", job_id, check=False, timeout=8)
            fields = launch_fields(status.stdout) if status.returncode == 0 else {}
            observation = dict(print_status=status.returncode, **fields)
            if status.returncode:
                observation["message"] = status.stderr.strip()[-400:]
            if previous != observation:
                history.write(json.dumps(dict(time=now(), **observation)) + "\n")
                history.flush()
                previous = observation
            exit_reason = worker_exit(fields)
            if exit_reason or time.monotonic() >= deadline:
                reason = f"ended with {exit_reason}" if exit_reason else "was not ready within 180 seconds"
                detail = log_tail(manifest / "service.stderr")
                raise RuntimeError(f"private worker {reason}; see {history.name}" + (f"\n{detail}" if detail else ""))
            time.sleep(.5)


def verify_cache():
    store = Path.home() / "Library/Application Support/com.apple.container"
    refs = json.loads((store / "state.json").read_text())
    init = sorted(ref for ref in refs if ref.startswith("ghcr.io/apple/containerization/vminit:"))
    require(bool(init), "no local Apple vminit reference")
    init = next((ref for ref in init if ref.endswith(":0.42.0")), init[0])
    records = {}
    def blob(desc):
        sha = desc["digest"].removeprefix("sha256:")
        require(re.fullmatch("[0-9a-f]{64}", sha), "invalid local content digest")
        path = store / "content/blobs/sha256" / sha
        require(path.is_file() and path.stat().st_size == desc["size"] and digest(path) == sha,
                f"missing or corrupt local worker image content {sha}")
        return path
    for ref in (ALPINE, init):
        require(ref in refs, "worker image missing from local store: " + ref)
        descriptor = refs[ref]
        manifest = json.loads(blob(descriptor).read_bytes())
        if "manifests" in manifest:
            arms = [d for d in manifest["manifests"] if d.get("platform", {}).get("os") == "linux"
                    and d.get("platform", {}).get("architecture") == "arm64"]
            require(len(arms) == 1, "expected one arm64 worker image manifest for " + ref)
            manifest = json.loads(blob(arms[0]).read_bytes())
        for desc in [manifest["config"], *manifest["layers"]]:
            blob(desc)
        records[ref] = descriptor["digest"]
    return records


def fixture_files(opts):
    sys.path.insert(0, str(TREE / "scripts/relaybench"))
    import gamma_pilot
    inp = opts.inputs.resolve()
    paths = {}
    problems = []
    def file(key, candidates, sha=None):
        for p in candidates:
            if p.is_file() and (not sha or digest(p) == sha):
                paths[key] = p.resolve()
                return
        problems.append(f"{key}: {', '.join(map(str, candidates))}" + (f" [sha256 {sha}]" if sha else ""))
    is_diagnostic = opts.mode == "diagnostic"
    required = [("kernel", "Image"), ("kernel_config", "config")]
    required.append(("netbench_image_tar", "netbench-v2.tar"))
    for key, name in required:
        ident = PINNED["kernel_and_tools"][key]
        if key == "netbench_image_tar" and (inp / name).is_file() and digest(inp / name) == REEXPORT:
            paths[key] = (inp / name).resolve()
        else:
            file(key, [inp / name, Path(ident["path"])], ident["sha256"])
    file("pause", [inp / "pause-3.10.2.tar", inp / "pause-fixture.tar"],
         "6c3e11bf4ada3dc89fe6819b2f5c6c0a626ba131fe18c6207eedffc1205285a0")
    file("check", [inp / "check", inp / "probe/check"])
    file("pathproof", [inp / "pathproof", inp / "probe/pathproof"])
    if getattr(opts, "socket_evidence", "controller") == "route":
        file("socket-inventory", [inp / "socket-inventory"], SOCKET_INVENTORY_SHA256)
    expected_client = (gamma_pilot.host_role.CLIENT_SHA256 if opts.mode in ("workers", "host-role")
                       else gamma_pilot.HASHES["fixed"])
    if opts.mode == "host-role":
        file("role_probe", [inp / "host-role/netbench", inp / "probe/netbench", inp / "netbench"],
             gamma_pilot.host_role.GUEST_PROBE_SHA256)
    file("fixed", [inp / opts.mode / "fixed", inp / "fixed", RECOVERY / "mixed/fixed", RECOVERY / "handshake/fixed"],
         expected_client)
    file("rusage", [inp / "rusage", inp / opts.mode / "rusage", RECOVERY / "usage-recovery/host-rusage", inp / "rusage.-O2"],
         gamma_pilot.HASHES["rusage"])
    build = PREVIOUS / BUILD_NAME[opts.mode]
    file("build", [build])
    if build.is_file():
        rec = json.loads(build.read_text())
        file("cli", [Path(rec["worker_executable"])], rec["worker_executable_sha256"])
    tools = (opts.oci_tools or Path.home() / ".micropod/qualified/interactive-a41976076b67-2293dd639a7a/micropod-oci-tools").resolve()
    for name in ("runner/start.sh", "runner/published-ports.sh", "runner/bin/job"):
        file("oci-" + Path(name).name, [tools / name])
    paths["oci"] = tools
    # diag/ contains the two arm64 utilities and their dynamic loader/libraries,
    # relative to Linux /. The service image itself contains only /netbench.
    diag = inp / "diag"
    ethtool_available = any((diag / p / "ethtool").is_file() for p in ("sbin", "usr/sbin", "bin", "usr/bin"))
    for name in (("ss",) if is_diagnostic and not ethtool_available else ("ss", "ethtool")):
        file(name, [diag / p / name for p in ("sbin", "usr/sbin", "bin", "usr/bin")])
    paths["diag"] = diag
    if problems:
        raise ValueError("missing or unverified local fixture inputs\n" + "\n".join(problems))
    return paths


def check_archives(files):
    for label, path, reference in (("pause", files["pause"], PAUSE),):
        with tarfile.open(path) as tar:
            try:
                manifest = json.load(tar.extractfile("manifest.json"))
                selected = [m for m in manifest if reference in (m.get("RepoTags") or [])]
                require(len(selected) == 1, f"{label} archive lacks its reference")
                cfg = tar.extractfile(selected[0]["Config"]).read()
            except KeyError:
                idx = json.load(tar.extractfile("index.json"))
                def descriptor(member):
                    algorithm, hash_ = member["digest"].split(":")
                    body = tar.extractfile("blobs/" + algorithm + "/" + hash_).read()
                    require(algorithm == "sha256" and hashlib.sha256(body).hexdigest() == hash_, "OCI digest mismatch")
                    return body
                matches = [m for m in idx["manifests"] if reference in m.get("annotations", {}).values()]
                require(len(matches) == 1, f"{label} OCI archive lacks its reference")
                payload = json.loads(descriptor(matches[0]))
                if "manifests" in payload:
                    matches = [m for m in payload["manifests"] if m.get("platform", {}).get("architecture") == "arm64"]
                    require(len(matches) == 1, f"{label} OCI archive lacks unique arm64 manifest")
                    payload = json.loads(descriptor(matches[0]))
                cfg = descriptor(payload["config"])
            require(json.loads(cfg).get("architecture") == "arm64", f"{label} image is not arm64")
            if label == "service":
                require(hashlib.sha256(cfg).hexdigest() == PINNED["image_config_sha256"], "service config differs")


def stage(root, files, *, runner_start=None):
    is_diagnostic = "ethtool" not in files
    workspace = root / "workspace"
    probe = workspace / "probe"
    probe.mkdir(parents=True, mode=0o700)
    probe_names = ["check", "pathproof", "ss"]
    if "socket-inventory" in files:
        probe_names.append("socket-inventory")
    for name in probe_names:
        shutil.copy2(files[name], probe / name)
        (probe / name).chmod(0o755)
    if "socket-inventory" in files:
        require(digest(probe / "socket-inventory") == SOCKET_INVENTORY_SHA256,
                "staged socket inventory differs from the pinned build")
    diag = workspace / "diag"
    shutil.copytree(files["diag"], diag, symlinks=True)
    tools = root / "oci"
    invoke("/bin/cp", "-cR", files["oci"], tools)
    require(not any(p.is_symlink() for p in (tools / "runner", tools / "runner/start.sh")),
            "private guest startup is a symlink")
    shutil.copy2(GUEST_FACTS, tools / "runner/fixture-facts.sh")
    start = tools / "runner/start.sh"
    if runner_start is not None:
        shutil.copy2(runner_start, start)
    content = start.read_text()
    content = content.replace("apk add --no-cache", "apk --repositories-file /dev/null add --no-network")
    tag = '"$tools/runner/bin/job" recover'
    require(content.count(tag) == 1, "unknown guest startup hook")
    ethtool = files.get("ethtool", files["diag"] / "sbin/ethtool").relative_to(files["diag"])
    # Guest Alpine has musl. Supply any missing ethtool libraries for this
    # private inventory command only, before the service is published.
    hook = '''(
  export PATH="$MICROPOD_ENGINE_WORKSPACE/diag/ETHPARENT:$PATH"
  export LD_LIBRARY_PATH="$MICROPOD_ENGINE_WORKSPACE/diag/lib:$MICROPOD_ENGINE_WORKSPACE/diag/usr/lib"
  target="$MICROPOD_ENGINE_WORKSPACE/facts-$MICROPOD_CI_WORKER_ID"
  if sh "$tools/runner/fixture-facts.sh" > "$target.tmp" 2>"$target.stderr"; then
    mv "$target.tmp" "$target"
  else
    echo "Guest inventory failed. Last output and error:" >&2
    tail -c 4096 "$target.tmp" >&2
    tail -c 4096 "$target.stderr" >&2
    exit 1
  fi
) || exit 1
'''.replace("ETHPARENT", str(ethtool.parent))
    if is_diagnostic:
        # Omit only the ethtool section. Preserve all existing boot, kernel,
        # NIC identity, queues, drops, IRQs, pressure, CPU and TCP counters.
        script = tools / "runner/fixture-facts.sh"
        source = script.read_text()
        left = "    for flag in i l k g c S; do"
        right = '    for q in "$path"/queues/*; do'
        require(source.count(left) == source.count(right) == 1, "guest capture source changed")
        start_block, end_block = source.index(left), source.index(right)
        require(start_block < end_block, "guest capture range changed")
        script.write_text(source[:start_block] + '    echo "ethtool_inventory=omitted_in_local_diagnostic"\n' + source[end_block:])
    start.write_text(content.replace(tag, hook + tag))
    clients = root / "clients"
    clients.mkdir(mode=0o700)
    for name in ("rusage", "fixed"):
        (clients / name).symlink_to(files[name])
    return workspace, tools, clients


class Run:
    def __init__(self, opts, folder, admission=None, *, worker_drive=None):
        self.opts, self.folder = opts, folder
        self.admission = admission
        # Lower-level Gamma fixtures also construct Run directly.
        self.volume_policy = {}
        if worker_drive is None:
            worker_drive, self.volume_policy = prepare_worker_drive(folder)
            save(folder / "host-volume-policy.json", self.volume_policy)
        self.worker_drive = worker_drive
        self.contention = None
        self.tearing_down = False
        self.root = Path(tempfile.mkdtemp(prefix="mp-t-", dir="/private/tmp")).resolve()
        self.arms, self.errors = [], []
        if self.admission:
            self.admission.arms = self.arms
        self.stop, self.low = threading.Event(), threading.Event()
        try:
            self.guard()
        except BaseException:
            self.root.rmdir()
            raise
        self.watch = threading.Thread(target=self.monitor, daemon=True)
        self.watch.start()

    def guard(self):
        if self.contention is not None:
            raise ValueError(self.contention)
        readings = {}
        for path in (self.root, self.folder):
            fs = os.statvfs(path)
            readings[str(path)] = fs.f_bavail * fs.f_frsize
        low = min(readings.values()) < self.opts.min_free_gib * 2**30
        with (self.folder / "disk.jsonl").open("a") as out:
            out.write(json.dumps(dict(time=now(), available_bytes=readings, below_floor=low)) + "\n")
        if low:
            self.low.set()
        require(not self.low.is_set(), "effective disk clearance lost during this run")

    def monitor(self):
        while not self.stop.wait(1):
            if self.admission and not self.tearing_down:
                try:
                    self.admission.check()
                except Exception as error:
                    self.contention = str(error)
                    return
            try:
                self.guard()
            except Exception as error:
                self.low.set()
                self.errors.append(str(error))
                return

    def waited(self, argv, log, timeout):
        with (self.folder / (log + ".stdout")).open("wb") as stdout, (self.folder / (log + ".stderr")).open("w") as stderr:
            receiver = log == "receiver"
            p = subprocess.Popen(list(map(str, argv)), stdout=subprocess.PIPE if receiver else stdout,
                                 stderr=stderr, start_new_session=True)
            if receiver:
                output_errors = []
                def capture():
                    try:
                        with p.stdout:
                            for line in p.stdout:
                                stdout.write(line)
                                stdout.flush()
                                if line.startswith(b"[idle] "):
                                    try:
                                        print(line.decode(errors="replace").rstrip(), flush=True)
                                    except OSError:
                                        pass
                    except OSError as error:
                        output_errors.append(error)
                progress = threading.Thread(target=capture, daemon=True)
                progress.start()
            if self.admission and log == "receiver":
                self.admission.receiver_group = p.pid
            try:
                deadline = time.monotonic() + timeout
                while p.poll() is None:
                    self.guard()
                    require(time.monotonic() < deadline, log + " timed out")
                    time.sleep(.3)
                if p.returncode:
                    if log == "receiver":
                        raise ReceiverFailed(p.returncode, receiver_failure(self.folder))
                    raise RuntimeError(f"{log} exited {p.returncode}; see {log}.stderr")
            finally:
                if p.poll() is None:
                    if log == "receiver":
                        # Let its finally blocks save the interrupted first attempt
                        # and stdout/stderr before escalating to the private group.
                        p.send_signal(signal.SIGINT)
                    else:
                        os.killpg(p.pid, signal.SIGTERM)
                    try:
                        p.wait(5)
                    except subprocess.TimeoutExpired:
                        os.killpg(p.pid, signal.SIGKILL)
                        p.wait()
                if receiver:
                    progress.join(5)
                    require(not progress.is_alive(), "receiver output stream did not close")
                    if output_errors:
                        raise RuntimeError(f"could not preserve receiver stdout: {output_errors[0]}")

    def arm(self, letter, workers, files, workspace, oci, *, process_type="Interactive", publication_mtu=None,
            relay_mode="kqueue-interactive", product_mtu=False, ext4_batch_us=None, profile_relay=False,
            published_rps=False, published_gso_bytes=None, relay_read_kib=None, anon_thp_16k=None, ci_scheduler=None, ci_next_buddy=False,
            anon_thp_64k=None):
        require(process_type in ("Interactive", "Standard"), "unknown launchd process type")
        require(relay_mode in ("kqueue-interactive", "kqueue-throughput"), "unknown worker relay mode")
        home = self.root / letter
        home.mkdir(mode=0o700)
        scope = self.root / "data" / letter
        scope.mkdir(parents=True)
        manifest = self.folder / letter
        manifest.mkdir()
        label = f"dev.micropod.benchmark.{self.root.name}.{letter}"
        job_id = f"gui/{os.getuid()}/{label}"
        entry = dict(scope=scope, home=home, manifest=manifest, job=job_id, attempted=False, loaded=False, cid=None)
        self.arms.append(entry)
        self.worker_drive.attach(self.root, home, manifest)
        env = {k: v for k, v in os.environ.items() if not k.startswith(("MICROPOD_", "DOCKER_"))}
        env.update(MICROPOD_CI_HOME=str(home), MICROPOD_CI_WORKSPACE=str(workspace), MICROPOD_CI_KERNEL=str(files["kernel"]),
                   MICROPOD_CI_OCI_TOOLS=str(oci), MICROPOD_CI_ENGINE="containerd", MICROPOD_CI_CPUS="4",
                   MICROPOD_CI_MEMORY_MIB="4096", MICROPOD_CI_DISK_GIB="6", MICROPOD_CI_PORT_RELAY=relay_mode,
                   MICROPOD_CI_PORT_RELAY_WORKERS=str(workers), MICROPOD_CI_PUBLISHED_PATH="macvlan")
        if profile_relay:
            env["MICROPOD_CI_PORT_PROFILE"] = "1"
        if relay_read_kib is not None:
            require(relay_read_kib in (256, 512), "unknown experimental relay read size")
            env["MICROPOD_BENCH_RELAY_READ_KIB"] = str(relay_read_kib)
        if publication_mtu is not None:
            require(publication_mtu in (1500, 8000, 9000), "invalid private publication MTU")
            mtu_key = "MICROPOD_CI_PUBLISHED_MTU" if product_mtu else "MICROPOD_BENCH_PRIVATE_PUBLICATION_MTU"
            env[mtu_key] = str(publication_mtu)
        if ext4_batch_us is not None:
            env["MICROPOD_CI_EXT4_MAX_BATCH_US"] = str(ext4_batch_us)
        if published_rps:
            env["MICROPOD_CI_PUBLISHED_RPS"] = "off-irq"
        if published_gso_bytes is not None:
            env["MICROPOD_CI_PUBLISHED_GSO_BYTES"] = str(published_gso_bytes)
        rendered = invoke(files["cli"], "ci", "launch-agent", env=env)
        job = plistlib.loads(rendered.stdout.encode())
        require(Path(job["ProgramArguments"][0]).resolve() == files["cli"] and job["ProgramArguments"][1:] == ["ci", "serve"], "unexpected supervisor")
        require(Path(job["EnvironmentVariables"]["MICROPOD_CI_HOME"]).resolve() == home, "wrong local job")
        if relay_read_kib is not None:
            require(job["EnvironmentVariables"].get("MICROPOD_BENCH_RELAY_READ_KIB") == str(relay_read_kib),
                    "signed worker did not pass the read size to launchd")
        if publication_mtu is not None:
            require(job["EnvironmentVariables"].get(mtu_key) == str(publication_mtu),
                    "signed worker did not accept the publication MTU")
        if published_rps:
            require(job["EnvironmentVariables"].get("MICROPOD_CI_PUBLISHED_RPS") == "off-irq",
                    "signed worker did not pass receive steering to launchd")
        if published_gso_bytes is not None:
            require(job["EnvironmentVariables"].get("MICROPOD_CI_PUBLISHED_GSO_BYTES") == str(published_gso_bytes),
                    "signed worker did not pass the segmentation limit to launchd")
        # The pinned stock command renders its default role and accepts no role
        # argument. The private plist sets it explicitly; the receiver checks
        # the actual spawn type and PID through launchctl for both arms.
        kernel_args = []
        if anon_thp_16k is not None:
            require(anon_thp_16k in ("never", "always"), "unknown anonymous 16 KiB page policy")
            kernel_args += [f"thp_anon=16K:{anon_thp_16k}", "thp_anon=2M:inherit"]
        if ci_scheduler is not None:
            require(ci_scheduler in ("hrtick", "hrtick-1ms", "hrtick-500us", "hrtick-250us", "hrtick-125us"), "unknown CI scheduler policy")
            kernel_args.append("micropod.ci_sched=" + ci_scheduler)
        if ci_next_buddy:
            kernel_args.append("micropod.ci_wakeup=next-buddy")
        if anon_thp_64k is not None:
            require(anon_thp_16k is None and anon_thp_64k in ("never", "always"), "unknown 64 KiB anonymous page policy")
            kernel_args += ["transparent_hugepage=never", f"thp_anon=64K-32M:never;64K:{anon_thp_64k}"]
        if kernel_args:
            require("MICROPOD_SANDBOX_KERNEL_ARGS" not in job["EnvironmentVariables"], "kernel arguments already set")
            job["EnvironmentVariables"]["MICROPOD_SANDBOX_KERNEL_ARGS"] = " ".join(kernel_args)
        job["ProcessType"] = process_type
        job.update(Label=label, KeepAlive=False, RunAtLoad=True, StandardOutPath=str(manifest / "service.stdout"),
                   StandardErrorPath=str(manifest / "service.stderr"))
        plist = scope / "job.plist"
        plist.write_bytes(plistlib.dumps(job))
        shutil.copy2(plist, manifest / plist.name)
        self.guard()
        previous = invoke("launchctl", "print", job_id, check=False)
        require(previous.returncode == 113 and "Could not find service" in previous.stderr, "cannot prove unique launchd label is absent")
        entry["attempted"] = True
        bootstrap_worker(job_id, plist, manifest)
        entry["loaded"] = True
        session = wait_for_worker(home, manifest, job_id, self.guard)
        self.worker_drive.verify_disk(home, manifest)
        config = json.loads((home / "worker.json").read_text())
        if published_rps:
            require(config.get("publishedRPS") == "off-irq", "wrong persisted receive steering")
        if ext4_batch_us is not None:
            require(config.get("ext4MaxBatchUS") == ext4_batch_us, "wrong persisted ext4 batch time")
        if publication_mtu is not None:
            expected = config.get("publishedMTU") == publication_mtu if product_mtu else config.get("benchmarkPublicationMTU") == str(publication_mtu)
            require(expected, "wrong persisted publication MTU")
        facts = workspace / ("facts-" + config["worker"])
        if not facts.is_file():
            matches = [p for p in workspace.glob("facts-*") if p.name.casefold() == facts.name.casefold()]
            require(len(matches) == 1, "guest inventory did not finish for this worker")
            facts = matches[0]
        shutil.copy2(facts, manifest / "guest-facts.txt")
        docker = ["docker", "--host", "unix://" + str(home / "docker.sock")]
        entry["docker"] = docker
        for name in ("pause", "netbench_image_tar"):
            self.waited([*docker, "load", "-i", files[name]], f"{letter}-load-{name}", 180)
        sandbox_ref = PAUSE
        service_ref = SERVICE
        for ref in (sandbox_ref, service_ref):
            invoke(*docker, "image", "inspect", ref)
        name = self.root.name + "-" + letter
        mounts = ["--mount", f"type=bind,src={workspace / 'probe'},dst=/mpcheck,readonly"]
        for lib in ("lib", "usr/lib"):
            if (workspace / "diag" / lib).is_dir():
                mounts.extend(["--mount", f"type=bind,src={workspace / 'diag' / lib},dst=/{lib},readonly"])
        cid = invoke(*docker, "run", "--pull=never", "--detach", "--name", name, "--cpus", "4", "--memory", "1g",
                     "--pids-limit", "512", *mounts, "-p", "127.0.0.1::8080", service_ref, "-listen", ":8080", "-marker", name).stdout.strip()
        require(re.fullmatch("[0-9a-f]{64}", cid), "unrecognized private container ID")
        entry["cid"] = cid
        holder_ids = invoke("lsof", "-nP", "-t", home / "worker.ext4").stdout.splitlines()
        library = ctypes.CDLL("/usr/lib/libproc.dylib")
        a = "com.apple.Virtualization.VirtualMachine"
        vmms = []
        for pid in set(holder_ids):
            require(pid.isdecimal(), "invalid private disk holder PID")
            buf = ctypes.create_string_buffer(4096)
            if library.proc_pidpath(int(pid), buf, len(buf)) > 0:
                executable = Path(os.fsdecode(buf.value))
                if executable.is_relative_to("/System/Library/Frameworks/Virtualization.framework") and executable.parts[-4:] == (a + ".xpc", "Contents", "MacOS", a):
                    vmms.append(pid)
        require(len(vmms) == 1, "private worker disk lacks a unique Apple VMM holder")
        vmm = vmms[0]
        address = invoke(*docker, "port", cid, "8080/tcp").stdout.strip()
        for key, val in dict(base=letter, id=cid, name=name, vmm=vmm, relay=session["owner"]["pid"], addr=address).items():
            (scope / key).write_text(str(val) + "\n")
        return scope, manifest / "guest-facts.txt"

    def job_state(self, arm):
        status = invoke("launchctl", "print", arm["job"], check=False, timeout=8)
        if status.returncode == 113 and "Could not find service" in status.stderr:
            return "absent"
        plist = arm["scope"] / "job.plist"
        paths = re.findall(r"(?m)^\s*path = (.+)$", status.stdout)
        if status.returncode == 0 and any(Path(path.strip()).resolve() == plist.resolve() for path in paths):
            return "owned"
        return "unknown"

    def cleanup(self):
        self.tearing_down = True
        for arm in reversed(self.arms):
            try:
                if arm["cid"]:
                    p = invoke(*arm["docker"], "rm", "-f", arm["cid"], check=False, timeout=20)
                    if p.returncode:
                        self.errors.append("private container cleanup: " + p.stderr[-400:])
                if arm["attempted"]:
                    state = self.job_state(arm)
                    if state == "owned":
                        p = invoke("launchctl", "bootout", arm["job"], check=False, timeout=30)
                        if p.returncode and self.job_state(arm) != "absent":
                            self.errors.append("private job cleanup: " + p.stderr[-400:])
                    elif state != "absent":
                        self.errors.append("cannot verify private launchd job identity: " + arm["job"])
                for name in ("session.json", "worker.json", "network.json", "published-network.json"):
                    p = arm["home"] / name
                    if p.is_file():
                        shutil.copy2(p, arm["manifest"] / name)
            except (OSError, subprocess.SubprocessError) as error:
                self.errors.append(str(error))
        released_homes = set()
        for arm in self.arms:
            if not arm["attempted"]:
                released_homes.add(arm["home"])
                continue
            # launchd can return from bootout before the Apple VMM releases
            # the data disk. Keep the private workspace on ambiguous status.
            deadline = time.monotonic() + 15
            while True:
                try:
                    disk = arm["home"] / "worker.ext4"
                    holder = invoke("lsof", "-t", disk, check=False, timeout=5) if disk.is_file() else None
                    if self.job_state(arm) == "absent" and (not holder or
                            holder.returncode == 1 and not holder.stdout.strip() and not holder.stderr.strip()):
                        released_homes.add(arm["home"])
                        break
                except (OSError, subprocess.SubprocessError) as error:
                    self.errors.append(str(error))
                    break
                if time.monotonic() >= deadline:
                    self.errors.append("private scope retained pending confirmed shutdown: " + str(self.root))
                    break
                time.sleep(.5)
        self.stop.set()
        self.watch.join(3)
        for arm in reversed(self.arms):
            if arm["home"] not in released_homes:
                continue
            try:
                self.worker_drive.close(arm["home"], arm["manifest"])
            except Exception as error:
                self.errors.append(f"private worker drive cleanup: {error}")
        for arm in self.arms:
            if arm["home"].is_mount():
                self.errors.append("worker volume still mounted: " + str(arm["home"]))
        if not self.errors:
            shutil.rmtree(self.root)
        save(self.folder / "cleanup.json", dict(scope=str(self.root), retained=self.root.exists(), errors=self.errors))


def exit_on_signal(signum, _frame):
    raise KeyboardInterrupt(signal.Signals(signum).name)


@contextmanager
def terminal_lock():
    with (HERE / "terminal-run.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("a local fixture is already active")
        yield


class ReceiverFailed(RuntimeError):
    def __init__(self, code, reason):
        self.code = code
        super().__init__(f"receiver exited {code}: {reason}")


def receiver_schedule(mode, idle_wait_seconds):
    args = ["--idle-wait-seconds", str(idle_wait_seconds)]
    windows = 2  # One warmup and one scored baseline invocation.
    if mode in ("host-role", "workers"):
        import receiver
        pairs = 8 if mode == "host-role" else 4
        args.extend(["--pairs", str(pairs)])
        windows = sum(len(pair) for group in receiver.relay.plan(0, pairs).values() for pair in group)
    return args, 1200 + windows * idle_wait_seconds


def prepare_worker_drive(folder):
    import local_worker_drive

    apfs = local_worker_drive.load_apfs()
    sources = {}
    for source in (Path(local_worker_drive.__file__), Path(apfs.__file__)):
        archived = folder / source.name
        shutil.copyfile(source, archived)
        sources[source.name] = digest(archived)
    return local_worker_drive.WorkerDrive(apfs, save), {
        "host_worker_volume": local_worker_drive.POLICY,
        "host_worker_volume_gib": local_worker_drive.VOLUME_GIB,
        "host_worker_volume_final_history": True,
        "host_volume_sources": sources,
    }


def run_mode(opts, folder, *, show_summary=True):
    record = dict(time=now(), mode=opts.mode, action="check-inputs" if opts.check_inputs else "run" if opts.run else "preflight",
                  inputs=str(opts.inputs), min_free_gib=opts.min_free_gib, socket_evidence=opts.socket_evidence,
                  idle_wait_seconds=opts.idle_wait_seconds, receiver_sha256=digest(HERE / "receiver.py"))
    if opts.ambient_diagnostic:
        record["ambient_diagnostic"] = True
    if opts.mode == "host-role":
        record["host_role_first"] = opts.host_role_first
    if sys.version_info < (3, 11):
        record["error"] = "requires Python 3.11 or newer"
        save(folder / "status.json", record)
        return 1
    runner = None
    try:
        files = fixture_files(opts)
        record["inet_diag_compiled_out"] = check_socket_evidence(
            files["kernel_config"], opts.socket_evidence, check_inputs=opts.check_inputs)
        record["netbench_identity"] = verify_service(files["netbench_image_tar"])
        record["host_image_cache"] = verify_cache()
        check_archives(files)
        record["inputs_verified"] = {k: {"path": str(v), "sha256": digest(v)} for k, v in files.items() if v.is_file()}
        require(shutil.which("docker") and shutil.which("lsof"), "docker CLI or lsof missing")
        save(folder / "status.json", record)
        if opts.check_inputs:
            print("Offline inputs verified.", flush=True)
            return 0
        admission = Admission(folder)
        admission.check(force=True)
        runner = Run(opts, folder, admission)
        record.update(runner.volume_policy)
        save(folder / "scope.json", dict(scope=str(runner.root), timestamp=now(), **runner.volume_policy))
        # Changes to this environment affect only this local invocation.
        for key in list(os.environ):
            if key.startswith(("DOCKER_", "MICROPOD_")):
                del os.environ[key]
        docker_config = runner.root / "docker-config"
        docker_config.mkdir(mode=0o700)
        os.environ["DOCKER_CONFIG"] = str(docker_config)
        workspace, oci, clients = stage(runner.root, files)
        if opts.mode == "host-role":
            import local_qos
            args = local_qos.receiver_args(runner, files, workspace, oci, clients, folder, opts)
        else:
            args = [sys.executable, "-B", HERE / "receiver.py", "baseline" if opts.mode == "diagnostic" else opts.mode, "--build", files["build"], "--tools", clients,
                    "--out", folder / "receiver", "--disk-path", runner.root, "--min-free-gib", opts.min_free_gib, "--ss", "/mpcheck/ss"]
            for letter, count in ([("a", 2), ("b", 4)] if opts.mode == "workers" else [("a", 2)]):
                scope, facts = runner.arm(letter, count, files, workspace, oci)
                args.extend(["--scope-" + letter, scope, "--facts-" + letter, facts])
        if opts.mode == "diagnostic" or opts.ambient_diagnostic:
            args.append("--ambient-diagnostic")
            if opts.mode == "diagnostic" and "ethtool" not in files:
                args.append("--abbreviated-inventory")
        if opts.socket_evidence == "route":
            args.extend(["--socket-evidence", "route", "--socket-config", files["kernel_config"]])
        schedule_args, timeout = receiver_schedule(opts.mode, opts.idle_wait_seconds)
        args.extend(schedule_args)
        if opts.run:
            args.append("--run")
        admission.check(force=True)
        runner.waited(args, "receiver", timeout)
        admission.check(force=True)
        record["receiver_exit"] = 0
        runner.cleanup()
        require(not runner.errors, "check cleanup.json for retained private scope")
        runner = None
    except (Exception, KeyboardInterrupt) as error:
        record["error"] = str(error) or type(error).__name__
        if isinstance(error, ReceiverFailed):
            record["receiver_exit"] = error.code
        record["completed_eligible_measurement"] = False
        print(record["error"], file=sys.stderr)
        return 1
    finally:
        if runner is not None and not runner.stop.is_set():
            runner.cleanup()
        if runner is not None:
            record["guards_clear"] = runner.contention is None and not runner.low.is_set() and not runner.errors
        record["end"] = now()
        save(folder / "status.json", record)
    summary = folder / "receiver/summary.json"
    if show_summary and summary.exists():
        print(summary.read_text().strip(), flush=True)
    print("Receiver results:", folder / "receiver", flush=True)
    return 0


SUITE_MODES = ("baseline", "host-role", "workers")


def suite_result(mode, folder, socket_evidence, idle_wait_seconds):
    def read(name):
        return json.loads((folder / name).read_bytes())

    cleanup = read("cleanup.json")
    require(cleanup["retained"] is False and cleanup["errors"] == [], f"{mode} cleanup incomplete")
    status = read("receiver/status.json")
    summary = read("receiver/summary.json")
    require(status["error"] is None and summary["schedule_complete"] is True,
            f"{mode} schedule incomplete; see {folder / 'receiver/status.json'}")
    verified = socket_evidence == "controller"
    for data in (status, summary):
        require(data.get("socket_evidence") == socket_evidence and
                data.get("accepted_socket_reno_verified") is verified,
                f"{mode} receiver socket evidence differs from the suite plan")
        require(type(data.get("idle_wait_seconds")) is int and data["idle_wait_seconds"] == idle_wait_seconds,
                f"{mode} receiver idle wait differs from the suite plan")
    result = {"socket_evidence": socket_evidence, "accepted_socket_reno_verified": verified,
              "idle_wait_seconds": idle_wait_seconds}
    if mode in ("baseline", "diagnostic"):
        row = read("receiver/scored-1-A.json")
        p95 = row.get("fresh_p95_us")
        require(status["scored_clean"] == 1 and row["clean"] is True and row["fresh_failed"] == 0 and
                row["reopened"] == 0 and row["mib_s"] > 0 and 0 < p95 <= row["fresh_p99_us"],
                f"{mode} failed the delivery gate")
        if mode == "diagnostic":
            require(status["ambient_diagnostic"] is True and status["local_vm_idle_and_delivery_qualified"] is False and
                    status["started"] == 2 and status["scored"] == 1, "ambient delivery result incomplete")
            result["evidence"] = "ambient delivery only"
        else:
            require(status["local_vm_idle_and_delivery_qualified"] is True and row["idle_gate_passed"] is True,
                    "stock baseline failed the idle gate")
            require(p95 <= 75000, f"stock baseline delivered {row['mib_s']:.1f} MiB/s, "
                    f"fresh p95 {p95} µs exceeded 75,000 µs; see {folder / 'receiver/scored-1-A.json'}")
        result.update(mib_s=row["mib_s"], fresh_p95_us=p95, fresh_p99_us=row["fresh_p99_us"])
    else:
        # An unfavorable comparison is a completed experimental result.
        require(not status.get("ambient_diagnostic") and not summary.get("ambient_diagnostic"),
                f"{mode} used ambient load and cannot qualify as a controlled comparison")
        verdict = summary["screen"]["verdict"]
        if not verified:
            verdict = "Independent controller confirmation required. Delivery screen: " + verdict
        result.update(screen=verdict, reasons=summary["screen"]["reasons"])
    return result


def idle_timeout_before_client(folder, attempt):
    if attempt.get("receiver_exit") != 1 or attempt.get("guards_clear") is not True:
        return False
    try:
        status = json.loads((folder / "receiver/status.json").read_bytes())
        cleanup = json.loads((folder / "cleanup.json").read_bytes())
        return (status["error_kind"] == "host_idle_timeout" and status["completed_schedule"] is False and
                type(status["started"]) is int and status["started"] == 0 and status["scored"] == 0 and
                status["ambient_diagnostic"] is False and cleanup["retained"] is False and cleanup["errors"] == [])
    except (OSError, KeyError, TypeError, ValueError):
        return False


def run_busy_diagnostic(opts, folder, record):
    directory = folder / "ambient-diagnostic"
    child = copy(opts)
    child.mode, child.idle_wait_seconds, child.busy_diagnostic = "diagnostic", 0, False
    diagnostic = record["ambient_diagnostic"] = {
        "state": "running", "start": now(), "evidence": str(directory), "socket_evidence": child.socket_evidence,
        "idle_wait_seconds": 0, "trigger": "controlled baseline idle timeout before first client"}
    save(folder / "status.json", record)
    print("The controlled baseline timed out before its first client. Its private scope was removed. "
          f"Starting one ambient delivery diagnostic. Evidence: {directory}", flush=True)
    try:
        directory.mkdir()
        if run_mode(child, directory, show_summary=False):
            raise RuntimeError(json.loads((directory / "status.json").read_bytes())["error"])
        result = suite_result("diagnostic", directory, child.socket_evidence, 0)
        diagnostic.update(state="complete", result=result)
        print(f"Ambient delivery only: {result['mib_s']:.1f} MiB/s, "
              f"fresh p95 {result['fresh_p95_us'] / 1000:.2f} ms. Controlled suite incomplete.", flush=True)
    except (Exception, KeyboardInterrupt) as error:
        diagnostic.update(state="failed", error=str(error) or type(error).__name__)
        print(f"Ambient diagnostic stopped: {diagnostic['error']}", file=sys.stderr)
    finally:
        diagnostic["end"] = now()


def resume_source(opts):
    supplied = opts.resume_from
    source = HERE / supplied if supplied.parent == Path(".") else supplied.absolute()
    require(source == source.resolve() and source.parent == HERE and source.is_dir() and
            re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-local-[a-z0-9_]{8}", source.name),
            "--resume-from needs the exact local suite evidence directory or its basename")
    prior = json.loads((source / "status.json").read_bytes())
    require(prior["mode"] == "suite" and prior["action"] == "run" and prior["complete"] is False and
            prior.get("error") and prior.get("end") and prior["plan"] == list(SUITE_MODES) and
            "resume_from" not in prior, "resume requires an original failed timed suite")
    require(prior["socket_evidence"] in ("controller", "route") and type(prior["idle_wait_seconds"]) is int and
            0 <= prior["idle_wait_seconds"] <= 60, "source has no supported socket and idle protocol")
    for key in ("socket_evidence", "idle_wait_seconds"):
        if getattr(opts, key + "_explicit"):
            require(getattr(opts, key) == prior[key], f"resume {key} conflicts with the source suite")
        setattr(opts, key, prior[key])
    return source


def resume_baseline(opts, fresh_folder, source):
    import receiver

    # Sealed copies keep the qualification evidence with this run, independently of the source directory.
    preserved = fresh_folder / "preserved"
    names = ["status.json", *(f"inputs/{mode}/status.json" for mode in SUITE_MODES),
             *(f"{mode}/{file}.json" for mode in ("baseline", "host-role") for file in ("status", "scope", "cleanup")),
             "host-role/receiver/status.json"]
    names.extend(str(path.relative_to(source)) for path in sorted((source / "baseline/receiver").iterdir()))
    hashes = {}
    for name in names:
        path = source / name
        require(path == path.resolve() and path.is_file(), f"expected a local receipt at {path}")
        target = preserved / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as out:
            out.write(path.read_bytes())
        hashes[name] = digest(target)

    def read(name):
        return json.loads((preserved / name).read_bytes())

    suite = read("status.json")
    stages = suite["stages"]
    require([stages[m]["state"] for m in SUITE_MODES] == ["complete", "failed", "inputs verified"] and
            not (source / "workers").exists() and not (source / "ambient-diagnostic").exists(),
            "resume needs a completed baseline, a failed host-role stage and unstarted workers")
    require(suite["socket_evidence"] == opts.socket_evidence and suite["idle_wait_seconds"] == opts.idle_wait_seconds,
            "source suite protocol changed")
    fields = ("inputs_verified", "netbench_identity", "host_image_cache", "receiver_sha256",
              "inet_diag_compiled_out", "min_free_gib", "idle_wait_seconds", "socket_evidence")
    for mode in SUITE_MODES:
        stage = stages[mode]
        require(stage["inputs"] == str(source / "inputs" / mode), f"unexpected source {mode} inputs path")
        old = read(f"inputs/{mode}/status.json")
        fresh = json.loads((fresh_folder / "inputs" / mode / "status.json").read_bytes())
        for receipt in (old, fresh):
            require(receipt["mode"] == mode and receipt["action"] == "check-inputs" and not receipt.get("error"),
                    f"invalid {mode} input receipt")
        for field in fields:
            require(old[field] == fresh[field], f"{mode} {field} changed since source suite")
        if mode != "workers":
            attempt = read(f"{mode}/status.json")
            require(stage["evidence"] == str(source / mode) and attempt["mode"] == mode and attempt["action"] == "run" and
                    all(attempt[k] == fresh[k] for k in fields), f"{mode} run differs from its checked inputs")
            cleanup = read(f"{mode}/cleanup.json")
            require(cleanup["retained"] is False and cleanup["errors"] == [] and
                    cleanup["scope"] == read(f"{mode}/scope.json")["scope"], f"{mode} teardown was incomplete")
    failed = read("host-role/receiver/status.json")
    require(failed["timing_requested"] is True and failed["timed_first_attempts"] == 0 and
            failed["scored_complete"] is False and failed["error"] and
            not any(json.loads(p.read_bytes()).get("started") for pattern in ("warmup-*.json", "scored-*.json")
                    for p in (source / "host-role/receiver").glob(pattern)), "host-role already timed a client")
    base = preserved / "baseline"
    attempt = read("baseline/status.json")
    status = read("baseline/receiver/status.json")
    require(attempt["receiver_exit"] == 0 and not attempt.get("error") and status["timed"] is True and
            status["started"] == 2 and status["scored"] == 1 and status["completed_schedule"] is True and
            status["ambient_diagnostic"] is False and status["abbreviated_inventory"] is False,
            "baseline did not finish the complete controlled schedule")
    plan = read("baseline/receiver/plan.json")
    scope = read("baseline/scope.json")["scope"]
    expected = dict(mode="baseline", order={"warmup": ["A"], "scored": ["A"]}, host=platform.node(), disk_path=scope,
                    minimum_free_GiB=opts.min_free_gib, ambient_diagnostic=False, abbreviated_inventory=False,
                    socket_evidence=opts.socket_evidence, idle_floor_pct=90, paired_idle_gap_max_pp=5,
                    **receiver.idle_policy(opts.idle_wait_seconds), tool_sha256=receiver.relay.HASHES,
                    adapter_sha256=attempt["receiver_sha256"], idle_verifier_sha256=digest(HERE / "local_idle.py"),
                    verifier_sha256=digest(Path(receiver.path_pilot.__file__)))
    for key, repo in (("source_revision", receiver.ROOT), ("verifier_revision", receiver.KERNEL_STUDY)):
        expected[key] = invoke("git", "-C", repo, "rev-parse", "HEAD").stdout.strip()
    if opts.socket_evidence == "route":
        expected["route_verifier_sha256"] = digest(HERE / "local_socket_route.py")
    for key, value in expected.items():
        require(plan[key] == value, f"baseline plan differs in {key}")
    fixture = read("baseline/receiver/fixtures.json")["A"]
    inputs = attempt["inputs_verified"]
    require(fixture["scope"] == str(Path(scope) / "data/a") and fixture["socket_evidence"] == opts.socket_evidence and
            fixture["accepted_socket_reno_verified"] is (opts.socket_evidence == "controller") and
            fixture["kernel_image_sha256"] == inputs["kernel"]["sha256"] and
            fixture["guest_config_sha256"] == inputs["kernel_config"]["sha256"] and
            fixture["cli_sha256"] == inputs["cli"]["sha256"] and
            fixture["guest_inventory_sha256"] == digest(base / "receiver/guest-A.txt"),
            "baseline fixture identity differs from the verified inputs")
    sockets = sorted((base / "receiver").glob("socket-A-*"))
    require(len(sockets) == 5, "expected socket evidence for preflight and both sides of each window")
    for proof in sockets:
        if opts.socket_evidence == "route":
            from local_socket_route import match_route
            data = json.loads(proof.read_bytes())
            captures = {r["stage"]: r for r in data["observations"]}
            route = match_route(data["flow"], json.loads(captures["routes"]["stdout"]),
                                json.loads(captures["service_addresses"]["stdout"]))
            require(data["passed"] is True and data["socket_congestion_controller"] is None and data["route"] == route,
                    "baseline return route evidence differs from the receiver")
        else:
            require(receiver.path_pilot.parse_service_ss(proof.read_text())["controller"] == "reno",
                    "baseline socket evidence did not verify Reno")
    for phase in ("warmup", "scored"):
        row = read(f"baseline/receiver/{phase}-1-A.json")
        checked = row.copy()
        receiver.score(subprocess.CompletedProcess([], row["exit_code"], row["stdout"], row["stderr"]), checked)
        samples = row["idle_observations"]
        count = 2 if opts.idle_wait_seconds else 1
        require(row["started"] is True and checked["clean"] is True and row == checked and row["phase"] == phase and
                row["arm"] == "A" and row["pair"] == 1 and row["idle_gate_passed"] is True and len(samples) >= count and
                all(s["eligible"] is True and 90 <= s["idle_pct"] <= 100 for s in samples[-count:]) and
                (not opts.idle_wait_seconds or samples[-1]["elapsed_seconds"] <= opts.idle_wait_seconds) and
                row["link_delta"]["mppub0"]["tx_bytes"] >= row["delivered_bytes"] and
                all(v["rx_dropped"] == v["tx_dropped"] == 0 for v in row["link_delta"].values()),
                f"baseline {phase} evidence differs from the raw delivery or idle observations")
    result = suite_result("baseline", base, opts.socket_evidence, opts.idle_wait_seconds)
    reported = read("baseline/receiver/summary.json")["results"]["A"]
    require(result == stages["baseline"]["result"] and reported == {"admission_attempts": 1, "first_attempts": 1,
            "clean": 1, "clean_median_MiB_s": result["mib_s"]}, "source baseline result differs from raw receipts")
    manifest = preserved / "manifest.json"
    save(manifest, {"source": str(source), "sha256": hashes})
    return {"state": "preserved", "evidence": str(base), "source": str(source / "baseline"),
            "manifest_sha256": digest(manifest), "result": result}


def completed_continuation(opts, folder, source):
    # A failed preflight can be repeated. Once a comparison client has started, preserve that first attempt.
    for manifest in sorted(source.parent.glob("*Z-local-*/preserved/manifest.json")):
        previous = manifest.parent.parent
        if previous == folder:
            continue
        prior = json.loads((previous / "status.json").read_bytes())
        if prior.get("resume_from") != str(source) or prior["action"] != "run" or prior.get("completed_by"):
            continue
        if prior["complete"]:
            require(digest(manifest) == digest(folder / "preserved/manifest.json"),
                    f"source evidence differs from completed continuation {previous}")
            for mode in SUITE_MODES[1:]:
                require(suite_result(mode, previous / mode, opts.socket_evidence, opts.idle_wait_seconds) ==
                        prior["stages"][mode]["result"], f"completed {mode} result changed at {previous}")
            return previous, prior["stages"]
        for mode in SUITE_MODES[1:]:
            stage = previous / mode
            if (stage / "scope.json").exists():
                cleanup = stage / "cleanup.json"
                require(cleanup.is_file(), f"confirm previous {mode} cleanup at {stage}")
                state = json.loads(cleanup.read_bytes())
                require(state["retained"] is False and state["errors"] == [], f"confirm previous {mode} cleanup at {stage}")
            rows = (path for pattern in ("warmup-*.json", "scored-*.json") for path in (stage / "receiver").glob(pattern))
            require(not any(json.loads(path.read_bytes())["started"] for path in rows),
                    f"previous continuation already timed {mode} at {stage}")
    return None


def run_suite(opts, folder):
    record = {"mode": "suite", "action": "check-inputs" if opts.check_inputs else "preflight" if opts.preflight else "run",
              "time": now(), "plan": list(SUITE_MODES), "stages": {}, "complete": False,
              "socket_evidence": opts.socket_evidence, "idle_wait_seconds": opts.idle_wait_seconds,
              "busy_diagnostic": opts.busy_diagnostic}
    stages = record["stages"]
    mode = None
    try:
        source = None
        if opts.resume_from:
            source = resume_source(opts)
            record.update(resume_from=str(source), socket_evidence=opts.socket_evidence, idle_wait_seconds=opts.idle_wait_seconds)
        for mode in SUITE_MODES:
            child = copy(opts)
            child.mode, child.check_inputs, child.preflight, child.run = mode, True, False, False
            directory = folder / "inputs" / mode
            directory.mkdir(parents=True)
            stages[mode] = {"inputs": str(directory), "state": "checking inputs",
                            "idle_wait_seconds": child.idle_wait_seconds}
            save(folder / "status.json", record)
            print(f"Checking {mode} inputs", flush=True)
            if run_mode(child, directory):
                raise RuntimeError(f"{mode} inputs: {json.loads((directory / 'status.json').read_bytes())['error']}")
            stages[mode]["state"] = "inputs verified"
        if source:
            mode = "baseline"
            stages[mode].update(resume_baseline(opts, folder, source))
            print(f"Preserved baseline: {stages[mode]['result']['mib_s']:.1f} MiB/s from {source.name}", flush=True)
            save(folder / "status.json", record)
            if opts.run and (prior := completed_continuation(opts, folder, source)):
                previous, completed = prior
                for mode in SUITE_MODES[1:]:
                    stages[mode].update(state="preserved", evidence=str(previous / mode), result=completed[mode]["result"])
                record.update(complete=True, completed_by=str(previous))
                print(f"Both comparisons already completed: {previous}", flush=True)
                return 0
        if not opts.check_inputs:
            for mode in SUITE_MODES[1:] if source else SUITE_MODES:
                directory = folder / mode
                directory.mkdir()
                child = copy(opts)
                child.mode = mode
                stages[mode].update(state="running", evidence=str(directory), start=now())
                save(folder / "status.json", record)
                print(f"Starting {mode}. Evidence: {directory}", flush=True)
                if run_mode(child, directory, show_summary=False):
                    attempt = json.loads((directory / "status.json").read_bytes())
                    stages[mode].update(state="failed", end=now(), error=attempt["error"])
                    if (opts.busy_diagnostic and mode == "baseline" and opts.run and
                            idle_timeout_before_client(directory, attempt)):
                        run_busy_diagnostic(opts, folder, record)
                    raise RuntimeError(f"{mode}: {attempt['error']}")
                if opts.run:
                    result = suite_result(mode, directory, opts.socket_evidence, opts.idle_wait_seconds)
                    stages[mode]["result"] = result
                    if mode == "baseline":
                        label = "Stock baseline" if opts.socket_evidence == "controller" else "Stock delivery baseline (route evidence)"
                        print(f"{label} {result['mib_s']:.1f} MiB/s, "
                              f"fresh p95 {result['fresh_p95_us'] / 1000:.2f} ms", flush=True)
                    else:
                        print(f"{mode} comparison finished. Verdict: {result['screen']}", flush=True)
                stages[mode].update(state="complete", end=now())
        record["complete"] = True
        return 0
    except (Exception, KeyboardInterrupt) as error:
        record["error"] = str(error) or type(error).__name__
        if mode in stages and stages[mode]["state"] != "failed":
            stages[mode].update(state="failed", end=now())
        print(record["error"], file=sys.stderr)
        return 1
    finally:
        record["end"] = now()
        save(folder / "status.json", record)


def parse_options(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--check-inputs", action="store_true", help="verify exact binaries, offline images, diagnostics and host cache; do not boot")
    action.add_argument("--preflight", action="store_true", help="boot, verify the private service and tear it down without timed clients")
    action.add_argument("--run", action="store_true", help="boot a new fixture, preflight and measure using receiver.py")
    parser.add_argument("--mode", choices=[*BUILD_NAME, "suite"], default="baseline",
                        help="suite runs baseline, host-role, then workers, each with private VMs")
    parser.add_argument("--host-role-first", choices=("Standard", "Interactive"),
                        help="which VM to start first in a standalone host-role comparison (default Standard)")
    parser.add_argument("--socket-evidence", choices=("controller", "route"),
                        help="controller requires the accepted socket's TCP algorithm; route measures delivery with the pinned route policy")
    parser.add_argument("--idle-wait-seconds", type=int, metavar="0..60",
                        help="pre-client settling budget per window (suite default 60 seconds, single mode default 0)")
    parser.add_argument("--busy-diagnostic", action="store_true",
                        help="on an initial baseline idle timeout, run one separate ambient diagnostic (suite --run only)")
    parser.add_argument("--ambient-diagnostic", action="store_true",
                        help="measure standalone host-role or workers under observed load and omit the controlled verdict")
    parser.add_argument("--resume-from", type=Path, metavar="SUITE",
                        help="verify and preserve a completed local baseline, then continue its unstarted comparisons")
    parser.add_argument("--inputs", type=Path, default=RECOVERY / "fixture-inputs", help="persistent local fixture input directory")
    parser.add_argument("--oci-tools", type=Path, help="qualified local guest OCI bundle")
    parser.add_argument("--min-free-gib", type=int, default=12, help="minimum effective free space, monitored through teardown")
    opts = parser.parse_args(argv)
    if opts.host_role_first and opts.mode != "host-role":
        parser.error("--host-role-first applies to the standalone host-role comparison")
    if opts.host_role_first is None:
        opts.host_role_first = "Standard"
    opts.socket_evidence_explicit = opts.socket_evidence is not None
    opts.idle_wait_seconds_explicit = opts.idle_wait_seconds is not None
    if opts.socket_evidence is None:
        opts.socket_evidence = "controller"
    if opts.idle_wait_seconds is None:
        opts.idle_wait_seconds = 60 if opts.mode == "suite" else 0
    if not 0 <= opts.idle_wait_seconds <= 60:
        parser.error("--idle-wait-seconds must be an integer from 0 through 60")
    if opts.mode == "diagnostic" and opts.idle_wait_seconds:
        parser.error("ambient diagnostics require --idle-wait-seconds 0")
    if opts.ambient_diagnostic and (opts.mode not in ("host-role", "workers") or not opts.run or opts.idle_wait_seconds):
        parser.error("--ambient-diagnostic requires standalone host-role or workers with --run and --idle-wait-seconds 0")
    if opts.busy_diagnostic and not (opts.mode == "suite" and opts.run):
        parser.error("--busy-diagnostic requires --mode suite --run")
    if opts.resume_from and (opts.mode != "suite" or opts.preflight):
        parser.error("--resume-from requires --mode suite with --run or --check-inputs")
    return opts


def main():
    # Terminal closure or an operator stop should unwind the private worker.
    for signum in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(signum, exit_on_signal)
    opts = parse_options()
    require(opts.min_free_gib >= 12, "minimum free space is 12 GiB")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    folder = Path(tempfile.mkdtemp(prefix=stamp + "-local-", dir=HERE))
    print("Local benchmark evidence:", folder, flush=True)
    try:
        with nullcontext() if opts.check_inputs else terminal_lock():
            if opts.mode == "suite":
                return run_suite(opts, folder)
            return run_mode(opts, folder)
    except (Exception, KeyboardInterrupt) as error:
        reason = str(error) or type(error).__name__
        save(folder / "status.json", dict(mode=opts.mode, error=reason, end=now()))
        print(reason, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
