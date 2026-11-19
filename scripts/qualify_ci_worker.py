#!/usr/bin/env python3
"""Qualify the trusted worker lifecycle. The Linux fixture runs only the guest engine."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import textwrap
import time
import uuid

from bench_live_kernel import WORKLOAD, fingerprint, measure, paired

ROOT = Path(__file__).resolve().parents[1]
ALPINE = "alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"


def command(*args, check=True, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, timeout=kwargs.pop("timeout", 240), **kwargs)
    if check and result.returncode:
        raise ValueError(f"{args[0]} {args[1]} exited {result.returncode}: {(result.stderr or result.stdout)[-1000:]}")
    return result


def require(value, message):
    if not value:
        raise ValueError(message)


def bootstrap():
    # Run exactly the script and image embedded in the shipped Mac executable.
    source = (ROOT / "Sources/MicropodRuntime/CIWorker.swift").read_text()
    image = re.search(r'static let image =\s*"(docker\.io/[^"]+@sha256:[a-f0-9]{64})"', source)[1]
    script = re.search(r'static let bootstrap = #"""\n(.*?)\n\s*"""#', source, re.S)[1]
    return image, textwrap.dedent(script)


def cached_package(cli, image, scope, op, lock=None):
    # Map the production cache locations into the existing offline fixture's layout.
    fixture = (ROOT / "scripts/bench_package_caches.py").read_text()
    job = """mkdir /caches
ln -s "$npm_config_cache" /caches/npm-cache
ln -s "$GOMODCACHE" /caches/go-mod-cache
ln -s "$GOCACHE" /caches/go-build-cache
exec python3 -c "$1" container "$2" "$3" """
    row = json.loads(cli("run", "--cache", "npm", "--cache", "go", "--cache-scope", scope,
                         "--pull=never", "--network", "none", "--cpus", "1", "--memory", "1g",
                         image, "sh", "-ec", job, "sh", fixture, op, json.dumps(lock)).stdout)
    require(row["verified"] == op, f"CLI package-cache check failed: {op}")
    return row


def warm_cli_caches(cli, image, scope, clients, boot):
    seed = cached_package(cli, image, scope, "seed")
    lock = seed["lock"]
    require(fingerprint(seed["boot"]) == fingerprint(boot), "Cache seed ran on another kernel")
    cached_package(cli, image, scope + "-empty", "empty", lock)
    elapsed = {}
    for tool in ("npm", "go"):
        start = time.perf_counter()
        with ThreadPoolExecutor(max_workers=clients) as pool:
            jobs = [pool.submit(cached_package, cli, image, scope, tool, lock) for _ in range(clients)]
            require(all(fingerprint(job.result()["boot"]) == fingerprint(boot) for job in jobs),
                    "An offline job used another kernel")
        elapsed[tool] = round(time.perf_counter() - start, 6)
    audit = cached_package(cli, image, scope, "audit", lock)
    require(audit["payload_inodes"] == seed["payload_inodes"], "Scoped caches duplicated the package payloads")
    require(audit["cache_sizes"] == seed["cache_sizes"], "Fresh jobs grew the shared fixture caches")
    return dict(clients=clients, seed=seed, warm_seconds=elapsed, after=audit["cache_sizes"],
                empty_scope_verified=True)


def bare_packages(host, package, home, env, args, expected):
    # Use the same binaries outside Docker to measure the raw process floor on this Ubuntu allocation.
    prefix = home / "host-tools"
    binary = prefix / "bin"
    binary.mkdir(parents=True)
    container = host("create", package).stdout.strip()
    try:
        for source, dest in [("/usr/local/go", prefix / "go"), ("/usr/local/bin/node", binary / "node"),
                             ("/usr/local/lib/node_modules/npm", prefix / "npm")]:
            host("cp", container + ":" + source, str(dest))
    finally:
        host("rm", container)
    (binary / "npm").symlink_to(prefix / "npm/bin/npm-cli.js")
    env = dict(env, GOROOT=str(prefix / "go"), PATH=os.pathsep.join([str(binary), str(prefix / "go/bin"), env["PATH"]]))
    versions = {tool: command(tool, flag, env=env).stdout.strip()
                for tool, flag in [("node", "--version"), ("npm", "--version"), ("go", "version")]}
    require(versions == expected, "The native Ubuntu processes used different toolchain versions")
    path = home / "bare.json"
    command(sys.executable, str(ROOT / "scripts/bench_package_caches.py"), "--parent", str(home),
            "--clients", *map(str, args.clients), "--rounds", str(args.rounds), "--json", str(path), env=env, timeout=420)
    record = json.loads(path.read_text())
    require(record["passed"], "Native Ubuntu process cache validation failed")
    record.update(versions=versions, isolation="host processes, no per-container CPU or memory limit")
    return record


def qualify(args, result, home):
    token = "mp-ci-" + uuid.uuid4().hex
    outer = token + "-guest"
    disk = token + "-disk"
    volume = token + "-proof"
    tag = token + ":proof"
    net = token + "-net"
    service = token + "-service"
    env = dict(os.environ, MICROPOD_CI_HOME=str(home))
    for key in ("DOCKER_CONTEXT", "DOCKER_CERT_PATH", "DOCKER_TLS_VERIFY", "BUILDX_BUILDER"):
        env.pop(key, None)
    apple = args.profile == "apple-worker"
    if apple:
        require(platform.system() == "Darwin" and platform.machine() == "arm64", "Expected Apple Silicon")
    else:
        require(platform.system() == "Linux" and os.getenv("RUNNER_ENVIRONMENT") == "github-hosted",
                "Use a disposable GitHub-hosted Linux runner for the privileged guest fixture")
    host_docker = os.getenv("DOCKER_HOST", "unix:///var/run/docker.sock")
    worker_id = str(uuid.uuid4()).upper()
    image, script = bootstrap()
    result.update(guest_image=image, revision=command("git", "-C", str(ROOT), "rev-parse", "HEAD").stdout.strip(),
                  host_platform=platform.platform(), hosted_runner=os.getenv("ImageOS"), system=platform.machine())
    socket = home / "docker.sock"
    uri = "unix://" + str(socket)

    def host(*argv, **kwargs):
        return command("docker", "--host", host_docker, *argv, env=env, **kwargs)

    def docker(*argv, **kwargs):
        return command("docker", "--host", uri, *argv, env=env, **kwargs)

    def cli(*argv, **kwargs):
        return command(args.micropod, "ci", *argv, env=env, **kwargs)

    def identity():
        if apple:
            return json.loads(cli("status").stdout)
        data = json.loads(docker("info", "--format", "{{json .}}").stdout)
        labels = dict(s.split("=", 1) for s in data["Labels"] if "=" in s)
        return dict(daemon=data["ID"], boot=labels["io.micropod.ci.boot"], worker=labels["io.micropod.ci.worker"],
                    instance=labels["io.micropod.ci.instance"], storageDriver=data["Driver"],
                    cgroupDriver=data["CgroupDriver"], cpus=data["NCPU"], memoryBytes=data["MemTotal"])

    def start():
        if apple:
            clients = max(args.clients)
            with ThreadPoolExecutor(max_workers=clients) as pool:
                starts = list(pool.map(lambda _: json.loads(cli("start").stdout), range(clients)))
            require(len({(s["boot"], s["daemon"], s["instance"]) for s in starts}) == 1,
                    "Concurrent starters reached different workers")
            require(starts[0]["endpoint"] == uri, "The CLI selected another socket")
        else:
            host("run", "-d", "--name", outer, "--privileged", "--cgroupns=private",
                 "--mount", "type=volume,src=" + disk + ",dst=/var/lib/docker",
                 "--mount", "type=bind,src=" + str(home) + ",dst=/var/lib/micropod",
                 "-e", "MICROPOD_CI_WORKER_ID=" + worker_id, "-e", "MICROPOD_CI_INSTANCE=" + str(uuid.uuid4()).upper(),
                 "--entrypoint", "/bin/sh", image, "-c", script)
            for _ in range(120):
                if socket.is_socket() and not os.access(socket, os.W_OK):
                    command("sudo", "-n", "chown", str(os.getuid()), str(socket))
                if socket.is_socket() and docker("info", check=False).returncode == 0:
                    break
                time.sleep(.25)
            else:
                raise ValueError("Guest daemon failed to boot: " + host("logs", outer).stderr[-1800:])
        return identity()

    def stop():
        if apple:
            cli("stop")
        else:
            host("stop", "-t", "25", outer)
            host("rm", outer)

    bundle = args.ubuntu_bundle
    peer_uri = "unix://" + args.orbstack_socket if args.orbstack_socket else None
    if peer_uri:
        require(apple, "The OrbStack comparison requires a physical Mac")
        peer = json.loads(command("docker", "--host", peer_uri, "info", "--format", "{{json .}}", env=env).stdout)
        require("orbstack" in (peer["Name"] + peer["OperatingSystem"]).lower(), "Expected the live OrbStack engine")
        env["MICROPOD_CI_CPUS"] = str(peer["NCPU"])
        env["MICROPOD_CI_MEMORY_MIB"] = str(max(1024, round(peer["MemTotal"] / 2**30) * 1024))
    try:
        if not apple:
            host("volume", "create", disk)
        started = time.perf_counter()
        first = start()
        result["initial_start_seconds"] = round(time.perf_counter() - started, 4)
        result["worker"] = first
        require(first["cgroupDriver"] == "cgroupfs", "Missing Linux cgroup driver")
        docker("pull", ALPINE)
        if apple:
            cli("run", "--cache", "npm", "--cache", "go", ALPINE, "sh", "-ec",
                'for cache in "$npm_config_cache" "$GOMODCACHE" "$GOCACHE"; do echo "$1" > "$cache/proof"; done', "_", token)
            cli("run", "--cache", "npm", "--cache", "go", ALPINE, "sh", "-ec",
                'for cache in "$npm_config_cache" "$GOMODCACHE" "$GOCACHE"; do test "$(cat "$cache/proof")" = "$1"; done', "_", token)
        docker("volume", "create", volume)
        docker("run", "--rm", "-v", volume + ":/cache", ALPINE, "sh", "-ec", 'echo "$1" >/cache/proof', "_", token)
        parent = lambda: fingerprint(identity()["boot"])
        opts = argparse.Namespace(engine=args.profile, socket=str(socket), image=ALPINE, clients=args.clients,
                                  rounds=args.rounds, package_image=args.package_image, clock="client", canonical_images=True)
        if peer_uri:
            command("docker", "--host", peer_uri, "pull", ALPINE, env=env)
            package = token + ":packages"
            try:
                if bundle:
                    reference = bundle / "native.json"
                    source_tag = json.loads(reference.read_text())["package_image_tag"]
                    require(re.fullmatch(r"mp-ci-[a-f0-9]{32}:packages", source_tag), "Unexpected Ubuntu fixture tag")
                    docker("load", "-i", str(bundle / "packages.tar"))
                    docker("tag", source_tag, package)
                else:
                    docker("build", "--build-arg", "SOURCE_DATE_EPOCH=0", "-t", package, str(ROOT / "scripts/bench_cache_image"))
                archive = str(home / "package.tar")
                docker("save", "-o", archive, package)
                command("docker", "--host", peer_uri, "load", "-i", archive, env=env)
                opts.package_image = package
                opts.worker_cli = shutil.which(args.micropod) or str(Path(args.micropod).resolve())
                opts.orbstack_socket, opts.desktop_socket, opts.colima_socket = args.orbstack_socket, None, None
                matched_series = args.rounds == 5 and set(args.clients) <= {1, 4, 8, 16}
                opts.ubuntu_reference = (sorted((ROOT / "docs/benchmarks/2026-11-19").glob("live-kernel-arm64*.json"))
                                         if matched_series else [])
                if bundle:
                    opts.ubuntu_reference.append(reference)
                # The shared harness runs stock clients as children of this process.
                os.environ["MICROPOD_CI_HOME"] = str(home)
                pair = result.setdefault("paired", {})
                paired(opts, pair)
                saved = ROOT / "docs/benchmarks/2026-11-19/package-containers-ubuntu-arm64.json"
                ref = json.loads(saved.read_text())
                actual = pair["blocks"][0]["package_caches"]["image_id"]
                if bundle:
                    pair["ubuntu_package_reference"] = pair["ubuntu_references"][-1]
                elif matched_series and actual == ref["package_caches"]["image_id"]:
                    from bench_live_kernel import reference_times
                    pair["ubuntu_package_reference"] = reference_times([saved], pair["blocks"][0], args.clients, args.rounds)[0]
                else:
                    pair["ubuntu_package_reference"] = dict(available=False, measured_config=actual,
                                                             archived_config=ref["package_caches"]["image_id"])
            finally:
                command("docker", "--host", peer_uri, "image", "rm", package, env=env, check=False)
        else:
            if args.packages:
                package = token + ":packages"
                builder = docker if apple else host
                builder("build", "--build-arg", "SOURCE_DATE_EPOCH=0", "-t", package, str(ROOT / "scripts/bench_cache_image"))
                if not apple:
                    if bundle:
                        bundle.mkdir(parents=True, exist_ok=True)
                    archive = str(bundle / "packages.tar" if bundle else home / "toolchain.tar")
                    host("save", "-o", archive, package)
                    docker("load", "-i", archive)
                opts.package_image = package
            measure(opts, result.setdefault("warm", {}), read_parent=parent)
            if not apple:
                # Fresh native reference on this exact CPU, kernel, toolchain and job allocation.
                host("pull", ALPINE)
                raw = argparse.Namespace(**vars(opts))
                raw.socket, raw.engine = host_docker.removeprefix("unix://"), "linux-docker"
                measure(raw, result.setdefault("native_ubuntu", {}))
                if bundle:
                    native = dict(result["native_ubuntu"], profile="linux-docker", system="Linux", clock="client",
                                  rounds=args.rounds, workload=WORKLOAD, package_image_tag=package, passed=True)
                    (bundle / "native.json").write_text(json.dumps(native, indent=2) + "\n")
                if args.packages:
                    expected = result["warm"]["package_caches"]["blocks"][0]["versions"]
                    result["bare_ubuntu_packages"] = bare_packages(host, package, home, env, args, expected)

        if apple and opts.package_image:
            result["cli_caches"] = warm_cli_caches(cli, opts.package_image, token, max(args.clients), first["boot"])
        require(identity()["instance"] == first["instance"], "The supervisor restarted during the warm batches")

        # A user-defined bridge and a fresh container resolving the service name exercise guest DNS.
        docker("network", "create", net)
        docker("run", "-d", "--name", service, "--network", net, ALPINE, "sh", "-ec",
               r"""while :; do printf 'HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nready' | nc -l -p 8080; done""")
        require(docker("run", "--rm", "--network", net, ALPINE, "wget", "-qO-", "http://" + service + ":8080/").stdout.strip() == "ready",
                "The service was unreachable")
        if apple:
            require(cli("stop", check=False).returncode != 0, "Stopped a worker with an active service")
        docker("rm", "-f", service)
        docker("network", "rm", net)

        # A source edit must re-execute this layer offline and find the *same* BuildKit cache.
        context = home / "context"
        context.mkdir()
        (context / "Dockerfile").write_text(
            f"FROM {ALPINE}\nCOPY revision /revision\n"
            f"RUN --network=none --mount=type=cache,id={token},target=/cache "
            f"if grep -qx seed /revision; then echo {token} > /cache/proof; "
            f"else grep -qx {token} /cache/proof; fi\n")
        def build(revision):
            (context / "revision").write_text(revision + "\n")
            docker("build", "-t", tag, str(context))
            require(docker("run", "--rm", tag, "cat", "/revision").stdout.strip() == revision,
                    "The build returned a stale layer")

        build("seed")
        stop()
        started = time.perf_counter()
        second = start()
        result["restart_seconds"] = round(time.perf_counter() - started, 4)
        require(second["daemon"] == first["daemon"] and second["worker"] == first["worker"]
                and second["instance"] != first["instance"], "Disk ownership failed across supervisor restart")
        require((first["boot"] != second["boot"]) == apple, "Unexpected kernel identity across restart")
        result["restarted"] = second
        if "cli_caches" in result:
            cache = result["cli_caches"]
            audit = cached_package(cli, opts.package_image, token, "audit", cache["seed"]["lock"])
            require(fingerprint(audit["boot"]) == fingerprint(second["boot"])
                    and audit["payload_inodes"] == cache["seed"]["payload_inodes"], "Restart lost scoped package data")
            cache["restart_reused_payloads"] = True
        require(docker("run", "--rm", "--pull=never", "-v", volume + ":/cache:ro", ALPINE, "cat", "/cache/proof").stdout.strip() == token,
                "Image or named volume did not survive restart")
        build("changed")
        if args.pipelines:
            engines = [("worker", uri)]
            if not apple:
                engines.append(("native_ubuntu", host_docker))
            timings = result["pipeline_seconds"] = {name: {} for name, _ in engines}
            for index in range(args.pipeline_rounds + 1):
                phase = "first" if index == 0 else f"warm_{index}"
                order = engines if index % 2 == 0 else reversed(engines)
                for name, endpoint in order:
                    started = time.perf_counter()
                    phase_log = home / (name + "-" + phase + ".jsonl")
                    command("bash", str(ROOT / "ci/worker-pipeline.sh"), "all", endpoint,
                            env=dict(env, MICROPOD_CI_STAGE_TIMINGS=str(phase_log)), timeout=600)
                    stages = [json.loads(line) for line in phase_log.read_text().splitlines()]
                    require(len(stages) == 5 and all(code == 0 for _, _, code in stages), "Incomplete pipeline stages")
                    result.setdefault("pipeline_stages_seconds", {}).setdefault(name, {})[phase] = {
                        stage: seconds for stage, seconds, _ in stages}
                    timings[name][phase] = round(time.perf_counter() - started, 3)
                    print(f"{name} {phase} Go and npm pipelines: {timings[name][phase]:.3f}s", file=sys.stderr, flush=True)
            for series in timings.values():
                series["warm"] = statistics.median(series[f"warm_{n}"] for n in range(1, args.pipeline_rounds + 1))
            result["pipelines"] = ["Go vet, race and Testcontainers PostgreSQL", "npm tests, source edit and rebuild"]
        result["verified"] = ["container streams and exit", "PID and mount namespaces", "CPU and memory quotas",
                              "bridge DNS and HTTP", "image and volume reuse", "offline BuildKit cache after restart"]
    finally:
        if apple:
            status = cli("status", check=False)
            if status.returncode == 0:
                docker("rm", "-f", service, check=False)
                cli("stop")
        else:
            host("rm", "-f", outer, check=False)
            host("volume", "rm", disk)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("profile", choices=["linux-guest", "apple-worker"])
    p.add_argument("--micropod", default="micropod")
    p.add_argument("--clients", type=int, nargs="+", default=[1, 4, 8, 16])
    p.add_argument("--rounds", type=int, default=5)
    p.add_argument("--package-image")
    p.add_argument("--packages", action="store_true", help="Build one shared offline toolchain for guest and native Ubuntu")
    p.add_argument("--orbstack-socket")
    p.add_argument("--ubuntu-bundle", type=Path,
                   help="Write the native reference and package image on Ubuntu, or use them for an Apple pair")
    p.add_argument("--pipelines", action="store_true", help="Run the normal Go and npm CI entry points")
    p.add_argument("--pipeline-rounds", type=int, choices=range(1, 11), default=3, metavar="1..10",
                   help="Warm passes of the full application pipelines per engine")
    p.add_argument("--json", required=True, type=Path)
    args = p.parse_args()
    if args.ubuntu_bundle and not (args.packages if args.profile == "linux-guest" else args.orbstack_socket):
        p.error("--ubuntu-bundle requires --packages on Ubuntu or --orbstack-socket on the Mac")
    if not 1 <= args.rounds <= 50 or not all(1 <= n <= 64 for n in args.clients) or len(set(args.clients)) != len(args.clients):
        p.error("Supply 1..50 rounds and unique concurrency levels from 1..64")
    record = dict(profile=args.profile, rounds=args.rounds, clients=args.clients)
    try:
        home = Path(tempfile.mkdtemp(prefix="mpci-", dir="/tmp"))
        try:
            qualify(args, record, home)
        except Exception:
            if (home / "worker.log").is_file():
                print((home / "worker.log").read_text(errors="replace")[-1600:], file=sys.stderr)
            if args.profile == "apple-worker":
                # Keep the owned disk if the supervisor cannot confirm shutdown.
                command(args.micropod, "ci", "stop", env=dict(os.environ, MICROPOD_CI_HOME=str(home)))
            shutil.rmtree(home)
            raise
        shutil.rmtree(home)
        record["passed"] = True
    except Exception as exc:
        record.update(passed=False, error=str(exc))
    args.json.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, separators=(",", ":")))
    return 0 if record["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
