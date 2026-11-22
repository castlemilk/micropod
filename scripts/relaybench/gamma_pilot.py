"""Print the minimal Gamma paired pilot. --run uses two already-serving benchmark scopes."""
import argparse
import hashlib
import json
import os
import platform
import plistlib
import random
import re
import subprocess
import tarfile
import tempfile
from pathlib import Path
from statistics import median

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
    require(mode in ("size", "peer", "workers") and workers in (2, 4) and peer_vcpus in (4, 6), "invalid arms")
    require(mode == "peer" or peer_vcpus == 4, "--peer-vcpus applies only to the OrbStack comparison")
    require(mode != "workers" or workers == 2, "the workers comparison always uses two and four workers")
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


def inspect(scope, cpus, orb):
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
    for key, expected in {"cpu.max": "400000 100000", "memory.max": "1073741824", "pids.max": "512"}.items():
        require(state[key] == expected, f"{name}: wrong {key}")
    require(command("curl", "--noproxy", "*", "-fsS", "--max-time", "3", "http://" + address + "/id") == name,
            "published endpoint returned the wrong marker")
    pids = {"vmm": int(value(scope, "vmm"))}
    fixture = dict(engine=info["ID"], engine_version=info["ServerVersion"], id=cid, name=name,
                   address=address, cpus=cpus, memory_bytes=info["MemTotal"],
                   image_config=IMAGE, cpuset=state["cpuset.cpus.effective"], release=state["release"], pids=pids)
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
    require(re.search(rf"(?m)^\s*pid = {pids['relay']}$", role) and "spawn type = interactive" in role
            and env["MICROPOD_CI_PORT_RELAY"] == "kqueue-interactive", "different live relay role")
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


def attempt(tools, fixture, birth, receipt):
    receipt["before"] = snapshot(tools, fixture)
    require(identities(receipt["before"]) == birth, "host process replaced before timing")
    try:
        result = subprocess.run([tools / "fixed", "http://" + fixture["address"], fixture["name"]],
                                capture_output=True, text=True, timeout=75)
    except subprocess.TimeoutExpired as exc:
        receipt.update(stdout=(exc.stdout or b"").decode(errors="replace"),
                       stderr=(exc.stderr or b"").decode(errors="replace"))
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
    receipt.update(mib_s=c.get("mib_s"), fresh_p95_us=c.get("fresh_p95_us"), fresh_p99_us=c.get("fresh_p99_us"),
                   arrivals=c.get("arrivals"), reopened=c.get("reopened"))


def save(path, obj):
    path.write_text(json.dumps(obj, indent=2, allow_nan=False) + "\n")


def run(args, orders, *, workers=2, peer_vcpus=4):
    settings = arm_settings(args.mode, workers, peer_vcpus)
    args.out.mkdir()  # Refuse to overwrite a previous attempt.
    save(args.out / "plan.json", dict(seed=args.seed, mode=args.mode, arms=settings, order=orders, tools=HASHES,
                                     host=platform.node(), macos=platform.mac_ver()[0]))
    require(platform.node().split(".")[0] == "Gamma-128GB", "run only on the original Gamma Mac")
    for tool, expected in HASHES.items():
        require(digest(args.tools / tool) == expected, f"unrecognized {tool} binary")
    peer = args.mode == "peer"
    scopes = {"A": (args.a, settings["A"]["vcpus"], False), "B": (args.b, settings["B"]["vcpus"], peer)}
    for path, _, _ in scopes.values():
        require(path.is_dir() and not (path / "removed").exists(), f"missing or retired fixture: {path}")
    fixtures = {arm: inspect(*scopes[arm]) for arm in ("BA" if peer else "AB")}
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
        if (args.mode == "workers" or expected == 4 or len(orders["scored"]) >= 16
                or fixture.get("callback_events") is not None):
            require(fixture.get("callback_events") == settings_arm["callback_events"],
                    f"arm {arm} needs a verified 128-event callback")
            require(fixture.get("route") == DIRECT_ROUTE, f"arm {arm} needs the qualified direct Reno route")
    if not peer:
        require(a["instance"] != b["instance"] and a["worker"] != b["worker"], "need separate Micropod VMs")
        kernel_field = "kernel_image_sha256" if all("kernel_image_sha256" in f for f in (a, b)) else "kernel"
        for key in (kernel_field, "release", "engine_version", "cli_sha256", "route", "service_env_sha256"):
            require(a[key] == b[key], f"Micropod arms differ in {key}")
    birth = {arm: identities(snapshot(args.tools, f)) for arm, f in fixtures.items()}
    save(args.out / "fixtures.json", fixtures)
    if args.check:
        return
    scored = {}
    for phase, pairs in orders.items():
        for number, order in enumerate(pairs, 1):
            for arm in order:
                row = dict(phase=phase, pair=number, arm=arm, clean=False, fresh_failed=None)
                try:
                    require(all(path.is_dir() and not (path / "removed").exists() for path, _, _ in scopes.values()),
                            "fixture retired during the pilot")
                    attempt(args.tools, fixtures[arm], birth[arm], row)
                except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError) as exc:
                    row.update(clean=False, error=str(exc))
                    raise
                finally:
                    save(args.out / f"{phase}-{number}-{arm}.json", row)
                require(phase != "warmup" or row["clean"], "warmup failed")
                if phase == "scored" and row["clean"]:
                    scored[number, arm] = row["mib_s"]
    require(all(inspect(*spec) == fixtures[arm] for arm, spec in scopes.items()), "fixture changed since preflight")
    numerator, denominator = ("A", "B") if peer else ("B", "A")
    ratios = {n: scored[n, numerator] / scored[n, denominator] for n in range(1, len(orders["scored"]) + 1)
              if (n, "A") in scored and (n, "B") in scored}
    deltas = {n: scored[n, numerator] - scored[n, denominator] for n in ratios}
    direction = {"peer": "Micropod/OrbStack", "size": "Micropod 6 vCPUs/Micropod 4 vCPUs",
                 "workers": "Micropod 4 relay workers/Micropod 2 relay workers"}[args.mode]
    values = list(ratios.values())
    save(args.out / "complete.json", dict(identity_rechecked=True, ratio_direction=direction, paired_ratios=ratios,
                                         paired_mib_s_differences=deltas,
                                         median_paired_mib_s_difference=median(deltas.values()) if deltas else None,
                                         median_ratio=median(values) if values else None,
                                         bootstrap_ci95=paired_median_interval(values),
                                         clean_scored={arm: sum(a == arm for _, a in scored) for arm in settings}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("size", "peer", "workers"), default="size",
                        help="VM size, matched OrbStack peer, or two/four relay workers on four-vCPU VMs")
    parser.add_argument("--relay-workers", type=int, choices=(2, 4), default=2, help="fixed Micropod count for size/peer")
    parser.add_argument("--peer-vcpus", type=int, choices=(4, 6), default=4, help="equal VM size for a peer test")
    parser.add_argument("--holdout", action="store_true", help="16 scored pairs, balanced in blocks of two")
    parser.add_argument("--seed", type=int, default=34199)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--run", action="store_true")
    action.add_argument("--check", action="store_true", help="verify both live fixtures and counters with zero timed load")
    parser.add_argument("--tools", type=Path, default=TOOLS)
    parser.add_argument("--a", type=Path, help="owner's already-running Micropod control fixture scope")
    parser.add_argument("--b", type=Path, help="owner's already-running candidate or peer fixture scope")
    parser.add_argument("--out", type=Path, help="new output directory")
    args = parser.parse_args()
    try:
        settings = arm_settings(args.mode, args.relay_workers, args.peer_vcpus)
    except ValueError as exc:
        parser.error(str(exc))
    orders = plan(args.seed, 16 if args.holdout else 2)
    if args.run or args.check:
        if not all((args.a, args.b, args.out)):
            parser.error("fixture checks and runs need --a, --b and --out")
        try:
            run(args, orders, workers=args.relay_workers, peer_vcpus=args.peer_vcpus)
        except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError, tarfile.TarError) as exc:
            parser.exit(1, f"Stopped: {exc}\n")
    else:
        print(json.dumps(dict(mode=args.mode, seed=args.seed, arms=settings, order=orders), indent=2))
