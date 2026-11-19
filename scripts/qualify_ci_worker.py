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
import subprocess
import sys
import tempfile
import textwrap
import time
import uuid

from bench_live_kernel import fingerprint, measure, paired

ROOT = Path(__file__).resolve().parents[1]
ALPINE = "alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"


def command(*args, check=True, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, timeout=240, **kwargs)
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
            with ThreadPoolExecutor(max_workers=4) as pool:
                starts = list(pool.map(lambda _: json.loads(cli("start").stdout), range(4)))
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
        docker("volume", "create", volume)
        docker("run", "--rm", "-v", volume + ":/cache", ALPINE, "sh", "-ec", 'echo "$1" >/cache/proof', "_", token)
        parent = lambda: fingerprint(identity()["boot"])
        opts = argparse.Namespace(engine=args.profile, socket=str(socket), image=ALPINE, clients=args.clients,
                                  rounds=args.rounds, package_image=args.package_image, clock="client")
        if peer_uri:
            command("docker", "--host", peer_uri, "pull", ALPINE, env=env)
            package = token + ":packages"
            try:
                docker("build", "--build-arg", "SOURCE_DATE_EPOCH=0", "-t", package, str(ROOT / "scripts/bench_cache_image"))
                archive = str(home / "package.tar")
                docker("save", "-o", archive, package)
                command("docker", "--host", peer_uri, "load", "-i", archive, env=env)
                opts.package_image = package
                opts.worker_cli = str(Path(args.micropod).resolve())
                opts.orbstack_socket, opts.desktop_socket, opts.colima_socket = args.orbstack_socket, None, None
                opts.ubuntu_reference = list((ROOT / "docs/benchmarks/2026-11-19").glob("live-kernel-arm64*.json"))
                opts.ubuntu_reference += [ROOT / "docs/benchmarks/2026-11-19/package-containers-ubuntu-arm64.json"]
                # The shared harness runs stock clients as children of this process.
                os.environ["MICROPOD_CI_HOME"] = str(home)
                paired(opts, result.setdefault("paired", {}))
            finally:
                command("docker", "--host", peer_uri, "image", "rm", package, env=env, check=False)
        else:
            if args.packages and not apple:
                package = token + ":packages"
                archive = str(home / "toolchain.tar")
                host("build", "--build-arg", "SOURCE_DATE_EPOCH=0", "-t", package, str(ROOT / "scripts/bench_cache_image"))
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
        require(docker("run", "--rm", "--pull=never", "-v", volume + ":/cache:ro", ALPINE, "cat", "/cache/proof").stdout.strip() == token,
                "Image or named volume did not survive restart")
        build("changed")
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
    p.add_argument("--json", required=True, type=Path)
    args = p.parse_args()
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
