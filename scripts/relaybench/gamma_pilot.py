"""Print the minimal Gamma paired pilot. --run uses two already-serving benchmark scopes."""
import argparse
import hashlib
import json
import math
import os
import platform
import plistlib
import random
import re
import subprocess
import tarfile
import tempfile
import time
from pathlib import Path
from statistics import median

import host_role
from gamma_contrasts import IMAGE, clean_client, host_units, paired_median_interval, process_delta

TOOLS = Path("/tmp/mp-priority.b3sbI7ym")
HASHES = {"fixed": "a1e2609f9d052b2765dc717fac1b227a8247aa9e73364bf3962168c30c8ffc53",
          "rusage": "e1201164a75e97543ae4d75e0361b5d79a40e80aa11fcb2b97ba01881fd0ba0c"}
STOCK_KERNEL = "7e3713940eec7466d1b47f959244534051b46ea70c50796e292a651112e8a0bd"
DIRECT_ROUTE = dict(RtoMin=20, RtoMinLock=True, QuickACK=0, Congctl="reno", MTU=0)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def plan(seed, scored_pairs=2):
    require(scored_pairs >= 2 and scored_pairs % 2 == 0, "use balanced AB/BA pairs")
    rng = random.Random(seed)
    warmup = ["AB", "BA", rng.choice(("AB", "BA"))]
    rng.shuffle(warmup)
    scored = []
    for _ in range(scored_pairs // 2):
        block = ["AB", "BA"]
        rng.shuffle(block)
        scored.extend(block)
    return {"warmup": warmup, "scored": scored}


def arm_settings(mode, workers=2, peer_vcpus=4):
    require(mode in ("size", "peer", "workers", "host-role") and workers in (2, 4) and peer_vcpus in (4, 6),
            "invalid arms")
    require(mode == "peer" or peer_vcpus == 4, "--peer-vcpus applies only to the OrbStack comparison")
    require(mode != "workers" or workers == 2, "the workers comparison always uses two and four workers")
    if mode == "host-role":
        require(workers == 2, "host-role requires the stock two-worker relay")
        return {arm: dict(engine="Micropod", vcpus=4, relay_workers=2, callback_events=128, process_type=role)
                for arm, role in (("A", "Standard"), ("B", "Interactive"))}
    a_cpus = peer_vcpus if mode == "peer" else 4
    b_workers = {"workers": 4, "size": workers, "peer": None}[mode]
    return {"A": dict(engine="Micropod", vcpus=a_cpus, relay_workers=workers, callback_events=128),
            "B": dict(engine="OrbStack" if mode == "peer" else "Micropod", vcpus=6 if mode == "size" else a_cpus,
                      relay_workers=b_workers, callback_events=None if mode == "peer" else 128)}


def command(*args):
    return subprocess.check_output(args, text=True, timeout=12).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mapped_digest(path, pid):
    # Hash the same vnode lsof observes as executable text in the live supervisor.
    with path.open("rb") as binary:
        st = os.fstat(binary.fileno())
        text = command("lsof", "-nP", "-a", "-p", str(pid), "-d", "txt", "-FfDi", "--", str(path))
        mappings = [dict((s[0], s[1:]) for s in block.splitlines() if s)
                    for block in re.split(r"(?m)^f[^\n]*\n", text)[1:]]
        require(any("D" in m and "i" in m and (int(m["D"], 0), int(m["i"])) == (st.st_dev, st.st_ino)
                    for m in mappings), "running supervisor does not map the recorded binary")
        return hashlib.sha256(binary.read()).hexdigest()


def value(directory, name):
    return (directory / name).read_text().strip()


def image_config(docker, container):
    # Some engines expose a manifest ID. Check the reference against the
    # container on both sides of exporting its configuration.
    if container["Image"] == IMAGE:
        return IMAGE
    ref = container["Config"]["Image"]
    check_id = [*docker, "image", "inspect", "--format", "{{.Id}}", ref]
    require(command(*check_id) == container["Image"], "image reference changed since container creation")
    with tempfile.TemporaryFile() as saved:
        subprocess.run([*docker, "image", "save", ref], stdout=saved, check=True, timeout=20)
        saved.seek(0)
        with tarfile.open(fileobj=saved) as archive:
            entries = json.load(archive.extractfile("manifest.json"))
            require(len(entries) == 1, "ambiguous saved image")
            config = archive.extractfile(entries[0]["Config"]).read()
    require(command(*check_id) == container["Image"], "image reference changed during verification")
    return "sha256:" + hashlib.sha256(config).hexdigest()


def inspect(scope, cpus, orb, process_type=None):
    scope = scope.resolve()
    require(scope.is_dir() and not (scope / "removed").exists(), f"missing or retired fixture: {scope}")
    base = value(scope, "base")
    require(base not in (".", "..", "") and Path(base).name == base and (base == "orb") == orb,
            f"wrong engine in {scope}")
    home = scope.parent.parent / base
    sock = Path.home() / ".orbstack/run/docker.sock" if orb else home / "docker.sock"
    docker = ["docker", "--host", "unix://" + str(sock)]
    info = json.loads(command(*docker, "info", "--format", "{{json .}}"))
    require(info["NCPU"] == cpus and 3.7 * 2**30 < info["MemTotal"] <= 4 * 2**30, "wrong guest size")
    cid, name = value(scope, "id"), value(scope, "name")
    c = json.loads(command(*docker, "inspect", "--type", "container", "--format", "{{json .}}", cid))
    require(c["Id"] == cid and c["Name"].lstrip("/") == name and c["State"]["Running"], "retired identity")
    require(c["Config"]["Cmd"] == ["-listen", ":8080", "-marker", name] and
            [port for port, bindings in c["NetworkSettings"]["Ports"].items() if bindings] == ["8080/tcp"],
            "need the original single-port workload")
    require(image_config(docker, c) == IMAGE, "image configuration digest differs")
    address = command(*docker, "port", cid, "8080/tcp")
    require(re.fullmatch(r"127\.0\.0\.1:[1-9][0-9]{0,4}", address) and address == value(scope, "addr"),
            "fixture is not published on its recorded loopback port")
    state = json.loads(command(*docker, "exec", cid, "/mpcheck/check", "state"))
    limits = {"cpu.max": "400000 100000", "memory.max": "1073741824", "pids.max": "512"}
    for key, expected in limits.items():
        require(state[key] == expected, f"{name}: wrong {key}")
    require(command("curl", "--noproxy", "*", "-fsS", "--max-time", "3", "http://" + address + "/id") == name,
            "published endpoint returned the wrong marker")
    pids = {"vmm": int(value(scope, "vmm"))}
    fixture = dict(scope=str(scope), engine=info["ID"], engine_version=info["ServerVersion"], id=cid, name=name,
                   address=address, cpus=cpus, memory_bytes=info["MemTotal"],
                   image_config=IMAGE, service_limits={key: state[key] for key in limits},
                   cpuset=state["cpuset.cpus.effective"], release=state["release"], pids=pids)
    if orb:
        require(command("ps", "-p", str(pids["vmm"]), "-o", "comm=").endswith("/Contents/MacOS/OrbStack Helper"),
                "wrong OrbStack VMM process")
        return fixture
    config = json.loads(value(home, "worker.json"))
    session = json.loads(value(home, "session.json"))
    sock_id = session["readySocket"]
    # The native worker attests its OCI endpoint. Docker's /info identifies
    # the sibling Docker endpoint from the same worker and booted instance.
    attested = (home / "oci.sock").stat()
    require(session["nativeOCI"] and info["ID"] == config["worker"]
            and "io.micropod.instance=" + session["instance"] in info["Labels"]
            and sock_id["worker"] == config["worker"] and attested.st_ino == sock_id["inode"]
            and attested.st_dev == sock_id["device"], "stale worker socket")
    pids["relay"] = int(value(scope, "relay"))
    workers = session["publishedRelayWorkers"]
    require(session["started"] and session["owner"]["pid"] == pids["relay"] and workers in (2, 4),
            "need a live two- or four-worker relay")
    require(command("lsof", "-t", str(home / "worker.ext4")) == str(pids["vmm"]), "wrong Micropod VMM process")
    owner = scope.parent / base
    job = plistlib.loads((owner / "job.plist").read_bytes())
    env = job["EnvironmentVariables"]
    role = command("launchctl", "print", f"gui/{os.getuid()}/{job['Label']}")
    if process_type is None:
        require(re.search(rf"(?m)^\s*pid = {pids['relay']}$", role) and "spawn type = interactive" in role
                and env["MICROPOD_CI_PORT_RELAY"] == "kqueue-interactive", "different live relay role")
    else:
        require(Path(command("ps", "-p", str(pids["vmm"]), "-o", "comm=")).name
                == "com.apple.Virtualization.VirtualMachine", "disk holder is not the Apple VMM")
        fixture.update(host_role.verify_job(job, role, pids["relay"], home, process_type))
        fixture["docker_socket"] = str(sock)
        mounts = [mount for mount in c["Mounts"] if mount["Destination"] == "/mpcheck"]
        require(len(mounts) == 1 and mounts[0]["RW"] is False, "need the read-only guest probe mount")
        probe = command(*docker, "exec", cid, "/mpcheck/netbench", "-self-sha256")
        require(probe == host_role.GUEST_PROBE_SHA256, "unrecognized running guest probe")
        fixture["guest_probe_sha256"] = probe
        fixture["guest_boot"] = host_role.guest_sample(command, fixture)["boot"]
    routes = json.loads(command(*docker, "exec", cid, "/mpcheck/pathproof", "routes"))
    reno_routes = [route for route in routes.get("mppub0", []) if route.get("Congctl") == "reno"]
    require(state["release"].strip() == "7.3.5-micropod" and config["memoryMiB"] == 4096
            and config["publishedPath"] == "macvlan"
            and "mppub0" in state["interfaces"] and len(reno_routes) == 1,
            "different network or memory")
    service_env = json.dumps(sorted(c["Config"].get("Env") or [])).encode()
    executable = Path(job["ProgramArguments"][0])
    callback = session.get("publishedRelayCallbackEvents")
    if callback is not None:
        require(env.get("MICROPOD_CI_PORT_PROFILE") != "1" and not re.search(
            r"(?m)^\s*MICROPOD_CI_PORT_PROFILE\s*=>\s*1\s*$", role), "relay profiling must be off")
        require(isinstance(config.get("kernel"), str) and config["kernel"], "missing kernel image path")
        fixture["kernel_image_sha256"] = digest(Path(config["kernel"]))
        require(fixture["kernel_image_sha256"] == STOCK_KERNEL, "different kernel image")
    fixture.update(instance=session["instance"], worker=config["worker"], kernel=config["kernel"],
                   cli_sha256=mapped_digest(executable, pids["relay"]) if callback is not None else digest(executable),
                   relay_workers=workers, callback_events=callback,
                   route={k: reno_routes[0][k] for k in DIRECT_ROUTE},
                   service_env_sha256=hashlib.sha256(service_env).hexdigest())
    return fixture


def snapshot(tools, fixture):
    snap = json.loads(command(tools / "rusage", *map(str, fixture["pids"].values())))
    require({r["pid"] for r in snap["tasks"]} == set(fixture["pids"].values()), "missing host counters")
    return snap


def identities(snap):
    return {r["pid"]: r["birth_ticks"] for r in snap["tasks"]}


def attempt(tools, fixture, birth, receipt, check_window=None):
    receipt["before"] = snapshot(tools, fixture)
    require(identities(receipt["before"]) == birth, "host process replaced before timing")
    try:
        args = [tools / "fixed", "http://" + fixture["address"], fixture["name"]]
        if check_window is None:
            result = subprocess.run(args, capture_output=True, text=True, timeout=75)
        else:
            result = run_in_window(args, check_window, receipt)
    except subprocess.TimeoutExpired as exc:
        receipt.setdefault("stdout", (exc.stdout or b"").decode(errors="replace"))
        receipt.setdefault("stderr", (exc.stderr or b"").decode(errors="replace"))
        receipt["after"] = snapshot(tools, fixture)
        raise
    receipt.update(exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr)
    receipt["after"] = snapshot(tools, fixture)
    require(identities(receipt["after"]) == birth, "host process replaced during timing")
    c = json.loads(result.stdout)
    receipt["clean"] = result.returncode == 0 and clean_client(c)
    streams, errors = c.get("per_stream_bytes", []), c.get("errors")
    if len(streams) == 32 and min(streams) > 0 and "errors" in c and all('/id"' in s for s in errors or []):
        receipt["fresh_failed"] = len(errors or [])
    if c.get("bytes", 0) > 0:
        counters = {}
        for role, pid in fixture["pids"].items():
            delta = process_delta(receipt["before"], receipt["after"], pid)
            counters[role] = {**delta, **host_units(delta, c["bytes"])}
        receipt["host"] = counters
    if "fresh_p50_us" in c:
        receipt["fresh_p50_us"] = c["fresh_p50_us"]
        receipt["bulk_streams_with_bytes"] = sum(n > 0 for n in streams)
    receipt.update(mib_s=c.get("mib_s"), fresh_p95_us=c.get("fresh_p95_us"), fresh_p99_us=c.get("fresh_p99_us"),
                   arrivals=c.get("arrivals"), reopened=c.get("reopened"))


def run_in_window(args, check_window, receipt):
    window = check_window()
    deadline = time.monotonic() + 75
    with subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as client:
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(args, 75)
                try:
                    wait = min(1, remaining)
                    if window is not None:
                        wait = min(wait, max(0.0, window["valid_until_epoch"] - time.time()))
                    stdout, stderr = client.communicate(timeout=wait)
                    return subprocess.CompletedProcess(args, client.returncode, stdout, stderr)
                except subprocess.TimeoutExpired:
                    window = check_window()
        except BaseException:
            if client.poll() is None:
                client.kill()
            receipt["stdout"], receipt["stderr"] = client.communicate()
            receipt["exit_code"] = client.returncode
            raise


def save(path, obj):
    path.write_text(json.dumps(obj, indent=2, allow_nan=False) + "\n")


def screening_result(rows, pairs):
    """Score every first attempt and withhold paired improvement when evidence is incomplete."""
    attempts = []
    reasons = []
    ratios = []
    for number in range(1, pairs + 1):
        pair = {"pair": number}
        for arm in "AB":
            row = rows[number, arm]
            counts = {key: row.get(key) for key in ("arrivals", "fresh_failed", "bulk_streams_with_bytes", "reopened")}
            problems = []
            if (not row["clean"] or counts["arrivals"] != 240 or counts["fresh_failed"] != 0
                    or counts["bulk_streams_with_bytes"] != 32 or counts["reopened"] != 0):
                problems.append("unaccounted request, stream, or reconnect")
            tails = [row.get(f"fresh_p{p}_us") for p in (50, 95, 99)]
            if not all(type(t) is int for t in tails) or not 0 < tails[0] <= tails[1] <= tails[2]:
                problems.append("missing or unordered fresh-request percentiles")
            if arm == "B" and type(tails[1]) is int and tails[1] > 75000:
                problems.append("candidate fresh p95 exceeded 75 ms")
            host = row.get("host", {})
            metrics = {"mib_s": row.get("mib_s")}
            for process in ("vmm", "relay"):
                counters = host.get(process, {})
                for name in ("cpu_s_per_gib", "runnable_s_per_s", "wait_s_per_s"):
                    metrics[f"{process}_{name}"] = counters.get(name)
            if (any(type(v) not in (int, float) or not math.isfinite(v) or v < 0 for v in metrics.values())
                    or metrics["mib_s"] == 0):
                problems.append("missing or invalid throughput or process counters")
            pair[arm] = dict(**counts, **metrics, fresh_p50_us=tails[0], fresh_p95_us=tails[1],
                             fresh_p99_us=tails[2], clean=row["clean"], problems=problems)
            reasons.extend(f"pair {number} {arm}: {p}" for p in problems)
        if not pair["A"]["problems"] and not pair["B"]["problems"]:
            ratios.append(pair["B"]["mib_s"] / pair["A"]["mib_s"])
        attempts.append(pair)
    change = 100 * (median(ratios) - 1) if len(ratios) == pairs else None
    if change is not None and change <= 0:
        reasons.append("no median paired throughput improvement")
    return dict(verdict="reject" if reasons else "eligible for confirmation", reasons=reasons,
                median_paired_throughput_change_pct=change, pairs=attempts)


def run(args, orders, *, workers=2, peer_vcpus=4):
    settings = arm_settings(args.mode, workers, peer_vcpus)
    role_test = args.mode == "host-role"
    screen = getattr(args, "scored_pairs", None) is not None
    peer = args.mode == "peer"
    peer_holdout = peer and len(orders["scored"]) == 16
    tools = dict(HASHES, fixed=host_role.CLIENT_SHA256) if role_test or screen or peer_holdout else HASHES
    args.out.mkdir()  # Refuse to overwrite a previous attempt.
    save(args.out / "plan.json", dict(seed=args.seed, mode=args.mode, arms=settings, order=orders, tools=tools,
                                     host=platform.node(), macos=platform.mac_ver()[0]))
    require(platform.node().split(".")[0] == "Gamma-128GB", "run only on the original Gamma Mac")
    for tool, expected in tools.items():
        require(digest(args.tools / tool) == expected, f"unrecognized {tool} binary")
    scopes = {"A": (args.a, settings["A"]["vcpus"], False), "B": (args.b, settings["B"]["vcpus"], peer)}
    if role_test or screen:
        require(len(orders["scored"]) >= 4, "this comparison needs at least four scored pairs")
    require(getattr(args, "fleet", None) and getattr(args, "release", None),
            f"this live {args.mode} comparison needs --fleet and --release")

    def read_window():
        return host_role.check_window(args.fleet, args.release, (args.a, args.b), time.time(), mode=args.mode)

    initial_window = read_window()
    save(args.out / "handoff.json", initial_window)

    def check_window():
        live = read_window()
        require(all(live[k] == initial_window[k] for k in ("owner", "reservation", "scopes", "starts_at", "expires_at")),
                "Gamma handoff changed")
        return live

    for path, _, _ in scopes.values():
        require(path.is_dir() and not (path / "removed").exists(), f"missing or retired fixture: {path}")

    def inspect_arm(arm):
        check_window()
        if role_test:
            return inspect(*scopes[arm], process_type=settings[arm]["process_type"])
        return inspect(*scopes[arm])

    fixtures = {arm: inspect_arm(arm) for arm in ("BA" if peer else "AB")}
    a, b = fixtures["A"], fixtures["B"]
    for key in ("engine", "id", "address", "name"):
        require(a[key] and b[key] and a[key] != b[key], f"arms share {key}")
    require(set(a["pids"].values()).isdisjoint(b["pids"].values()), "arms share a host process")
    require(a["cpuset"] == b["cpuset"] == "0-3", "both service containers must be pinned to CPUs 0-3")
    for arm, settings_arm in settings.items():
        expected = settings_arm["relay_workers"]
        if expected is None:
            continue
        fixture = fixtures[arm]
        require(fixture["relay_workers"] == expected, f"arm {arm} needs {expected} relay workers")
        if (screen or args.mode in ("workers", "host-role") or expected == 4 or len(orders["scored"]) >= 16
                or fixture.get("callback_events") is not None):
            require(fixture.get("callback_events") == settings_arm["callback_events"],
                    f"arm {arm} needs a verified 128-event callback")
            require(fixture.get("route") == DIRECT_ROUTE, f"arm {arm} needs the qualified direct Reno route")
    if not peer:
        require(a["instance"] != b["instance"] and a["worker"] != b["worker"], "need separate Micropod VMs")
        kernel_field = "kernel_image_sha256" if all("kernel_image_sha256" in f for f in (a, b)) else "kernel"
        for key in (kernel_field, "release", "engine_version", "cli_sha256", "route", "service_env_sha256"):
            require(a[key] == b[key], f"Micropod arms differ in {key}")
    if role_test:
        require(a["job_controls_sha256"] == b["job_controls_sha256"], "launchd controls differ beyond ProcessType")
        require(a["guest_boot"] != b["guest_boot"], "arms share a guest boot")
        for arm, fixture in fixtures.items():
            require(fixture["process_type"] == settings[arm]["process_type"]
                    and fixture["kernel_image_sha256"] == STOCK_KERNEL, "wrong role or stock kernel")
    birth = {arm: identities(snapshot(args.tools, f)) for arm, f in fixtures.items()}
    save(args.out / "fixtures.json", fixtures)
    check_window()
    if args.check:
        return
    scored, measured_rows = {}, {}
    for phase, pairs in orders.items():
        for number, order in enumerate(pairs, 1):
            for arm in order:
                row = dict(phase=phase, pair=number, arm=arm, clean=False, fresh_failed=None)
                try:
                    require(all(path.is_dir() and not (path / "removed").exists() for path, _, _ in scopes.values()),
                            "fixture retired during the pilot")
                    row["admission_after"] = None
                    row["admission"] = check_window()
                    if role_test:
                        fixture = fixtures[arm]
                        row["guest_before"] = host_role.guest_sample(command, fixture)
                        require(row["guest_before"]["boot"] == fixture["guest_boot"], "guest boot changed before timing")
                    attempt(args.tools, fixtures[arm], birth[arm], row, check_window)
                    final = check_window()
                    row["admission_after"] = final
                    opening = row["admission"]
                    clearance_expiry = host_role.timestamp(opening["effective_disk_gate"]["expires_at"])
                    latest_start = max(host_role.timestamp(final["fleet_time"]),
                                       host_role.timestamp(final["effective_disk_gate"]["checked_at"]))
                    require(host_role.timestamp(final["observed_at"]) < clearance_expiry
                            and latest_start <= opening["valid_until_epoch"],
                            "admission evidence does not cover the whole attempt")
                    if peer_holdout:
                        require(type(row.get("fresh_p50_us")) is int, "missing scheduled-arrival p50 on the peer holdout")
                    if role_test:
                        row["guest_after"] = host_role.guest_sample(command, fixture)
                        row["guest"] = host_role.guest_delta(row["guest_before"], row["guest_after"])
                        if phase == "warmup":
                            require(not any(row["guest"]["delta"][k] for k in host_role.FAULT_COUNTERS),
                                    "interface fault or TCP reset during warmup")
                except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError) as exc:
                    row.update(clean=False, error=str(exc))
                    raise
                finally:
                    save(args.out / f"{phase}-{number}-{arm}.json", row)
                require(phase != "warmup" or row["clean"], "warmup failed")
                if phase == "scored" and row["clean"]:
                    scored[number, arm] = row["mib_s"]
                if phase == "scored" and (role_test or screen):
                    measured_rows[number, arm] = row
    require(all(inspect_arm(arm) == fixtures[arm] for arm in scopes), "fixture changed since preflight")
    if screen:
        check_window()
        result = screening_result(measured_rows, len(orders["scored"]))
        save(args.out / "complete.json", dict(identity_rechecked=True, mode=args.mode, screen=result))
        if result["verdict"] == "reject":
            raise ValueError(f"{args.mode} screen rejected: " + ", ".join(result["reasons"]))
        return
    numerator, denominator = ("A", "B") if peer else ("B", "A")
    ratios = {n: scored[n, numerator] / scored[n, denominator] for n in range(1, len(orders["scored"]) + 1)
              if (n, "A") in scored and (n, "B") in scored}
    deltas = {n: scored[n, numerator] - scored[n, denominator] for n in ratios}
    direction = {"peer": "Micropod/OrbStack", "size": "Micropod 6 vCPUs/Micropod 4 vCPUs",
                 "workers": "Micropod 4 relay workers/Micropod 2 relay workers",
                 "host-role": "Micropod Interactive/Micropod Standard"}[args.mode]
    values = list(ratios.values())
    complete = dict(identity_rechecked=True, ratio_direction=direction, paired_ratios=ratios,
                    paired_mib_s_differences=deltas,
                    median_paired_mib_s_difference=median(deltas.values()) if deltas else None,
                    median_ratio=median(values) if values else None, bootstrap_ci95=paired_median_interval(values),
                    clean_scored={arm: sum(a == arm for _, a in scored) for arm in settings})
    check_window()
    if role_test:
        complete["host_role"] = host_role.decision(measured_rows, len(orders["scored"]))
    save(args.out / "complete.json", complete)
    if role_test and complete["host_role"]["verdict"] != "eligible for confirmation":
        outcome = complete["host_role"]
        raise ValueError("host-role " + outcome["verdict"] + ": " + ", ".join(outcome["reasons"]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("size", "peer", "workers", "host-role"), default="size",
                        help="VM size, matched peer, relay workers, or Standard/Interactive launchd roles")
    parser.add_argument("--relay-workers", type=int, choices=(2, 4), default=2, help="fixed Micropod count for size/peer")
    parser.add_argument("--peer-vcpus", type=int, choices=(4, 6), default=4, help="equal VM size for a peer test")
    length = parser.add_mutually_exclusive_group()
    length.add_argument("--holdout", action="store_true", help="16 scored pairs, balanced in blocks of two")
    length.add_argument("--scored-pairs", type=int, metavar="N",
                        help="workers/size screen: even number of scored pairs (at least four)")
    parser.add_argument("--seed", type=int, default=34199)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--run", action="store_true")
    action.add_argument("--check", action="store_true", help="verify both live fixtures and counters with zero timed load")
    parser.add_argument("--tools", type=Path, default=TOOLS)
    parser.add_argument("--a", type=Path, help="owner's already-running Micropod control fixture scope")
    parser.add_argument("--b", type=Path, help="owner's already-running candidate or peer fixture scope")
    parser.add_argument("--fleet", type=Path, help="refreshed Cuttlefish fleet export for a live check or run")
    parser.add_argument("--release", type=Path, help="owner's exclusive handoff for the chosen mode and both fixtures")
    parser.add_argument("--out", type=Path, help="new output directory")
    args = parser.parse_args()
    try:
        settings = arm_settings(args.mode, args.relay_workers, args.peer_vcpus)
    except ValueError as exc:
        parser.error(str(exc))
    pilot_pairs = 4 if args.mode == "host-role" else 2
    if args.scored_pairs is not None:
        if args.mode not in ("workers", "size") or args.scored_pairs < 4 or args.scored_pairs % 2:
            parser.error("--scored-pairs requires workers or size mode and an even count of at least four")
        pilot_pairs = args.scored_pairs
    orders = plan(args.seed, 16 if args.holdout else pilot_pairs)
    if args.run or args.check:
        if not all((args.a, args.b, args.out)):
            parser.error("fixture checks and runs need --a, --b and --out")
        if not (args.fleet and args.release):
            parser.error(f"this live {args.mode} comparison needs --fleet and --release")
        try:
            run(args, orders, workers=args.relay_workers, peer_vcpus=args.peer_vcpus)
        except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError, tarfile.TarError) as exc:
            parser.exit(1, f"Stopped: {exc}\n")
    else:
        print(json.dumps(dict(mode=args.mode, seed=args.seed, arms=settings, order=orders), indent=2))
