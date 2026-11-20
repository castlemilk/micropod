#!/usr/bin/env python3
"""Differential Docker Engine contract probes against two explicitly selected local Unix sockets."""

import argparse
import base64
import gzip
import hashlib
import http.client
import io
import json
import os
import re
import socket
import struct
import subprocess
import tarfile
import tempfile
import time
import uuid
from pathlib import Path
from urllib.parse import quote, urlencode

from ci_benchmark_store import DEFAULT_DB, store

LABEL = "io.micropod.engine-qualification"
SPEC_SHA256 = "00ccd7d2e6e0b7a943ac0067007d181d723b2513ef1f6af3b6b54145314a6fa7"
VERSION = "1.56"


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=15)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.path))


class Engine:
    def __init__(self, endpoint, image, postgres_runner, guest_socket):
        self.endpoint = endpoint
        self.image = image
        self.postgres_runner = postgres_runner
        self.guest_socket = guest_socket
        self.cases = {}
        self.name = "mp-engine-" + uuid.uuid4().hex
        self.labels = {LABEL: self.name}
        self.prefix = "/v" + VERSION
        self.env = {
            k: v
            for k, v in os.environ.items()
            if k
            not in {
                "DOCKER_CONTEXT",
                "DOCKER_HOST",
                "DOCKER_API_VERSION",
                "DOCKER_TLS_VERIFY",
                "DOCKER_CERT_PATH",
                "BUILDX_BUILDER",
            }
        }

    def request(self, method, path, *, body=None, headers=None, versioned=True):
        conn = UnixHTTP(self.endpoint)
        try:
            if isinstance(body, dict):
                body = json.dumps(body).encode()
                headers = {"Content-Type": "application/json", **(headers or {})}
            conn.request(
                method, (self.prefix if versioned else "") + path, body=body, headers=headers or {}
            )
            response = conn.getresponse()
            data = response.read(8 << 20)
            if response.read(1):
                raise ValueError("response exceeds qualification limit")
            return response.status, {k.lower(): v for k, v in response.getheaders()}, data
        finally:
            conn.close()

    def cli(self, *args, data=None, timeout=90):
        return subprocess.run(
            ["docker", "--host", "unix://" + str(self.endpoint), *args],
            input=data,
            capture_output=True,
            timeout=timeout,
            env=self.env,
            check=False,
        )

    def observe(self, case, operations, fn):
        try:
            self.cases[case] = {"operations": operations.split(), "observed": fn()}
        except (
            ValueError,
            KeyError,
            OSError,
            RuntimeError,
            TypeError,
            http.client.HTTPException,
            tarfile.TarError,
            subprocess.SubprocessError,
        ) as exc:
            self.cases[case] = {"operations": operations.split(), "error": str(exc)[:500]}

    def shape(self, path, *, versioned=True):
        status, _, body = self.request("GET", path, versioned=versioned)
        if status >= 400:
            try:
                error = as_json(body)
            except ValueError:
                error = None
            return {
                "status": status,
                "json_message": isinstance(error, dict) and bool(error.get("message")),
            }
        parsed = as_json(body)
        return {"status": status, "kind": type(parsed).__name__}

    def run(self):
        def ping(method):
            status, headers, data = self.request(method, "/_ping", versioned=False)
            return {
                "status": status,
                "body": data.decode(),
                "api": headers.get("api-version"),
                "os": headers.get("ostype"),
                "builder": headers.get("builder-version"),
            }

        for method, op in [("GET", "SystemPing"), ("HEAD", "SystemPingHead")]:
            self.observe("ping-" + method.lower(), op, lambda m=method: ping(m))

        def advertised():
            version = as_json(self.request("GET", "/version", versioned=False)[2])
            return {k: version.get(k) for k in ["ApiVersion", "MinAPIVersion", "Os", "Arch"]}

        self.observe("advertised", "SystemVersion", advertised)
        self.observe(
            "version-range",
            "SystemVersion",
            lambda: {
                str(n): self.request("GET", f"/v1.{n}/version", versioned=False)[0]
                for n in range(39, 58)
            },
        )
        for path, op in [
            ("/info", "SystemInfo"),
            ("/swarm", "SwarmInspect"),
            ("/services", "ServiceList"),
            ("/secrets", "SecretList"),
            ("/configs", "ConfigList"),
            ("/tasks", "TaskList"),
            ("/nodes", "NodeList"),
            ("/plugins", "PluginList"),
        ]:
            self.observe(path[1:], op, lambda p=path: self.shape(p))
        self.observe(
            "missing-container",
            "ContainerInspect",
            lambda: self.shape("/containers/" + self.name + "/json"),
        )
        self.observe("missing-volume", "VolumeInspect", lambda: self.shape("/volumes/" + self.name))
        image = "/images/" + quote(self.image, safe=":/")

        def image_info():
            status, _, data = self.request("GET", image + "/json")
            result = as_json(data)
            return {
                "status": status,
                "layers": result["RootFS"]["Layers"],
                "dir": result["Config"]["WorkingDir"],
                "cmd": result["Config"]["Cmd"],
                "arch": result["Architecture"],
            }

        self.observe("image-inspect", "ImageInspect", image_info)
        self.observe("image-history", "ImageHistory", lambda: self.shape(image + "/history"))
        self.observe(
            "volume-lifecycle", "VolumeCreate VolumeInspect VolumeList VolumeDelete", self.volume
        )
        self.observe(
            "network-lifecycle", "NetworkCreate NetworkInspect NetworkList NetworkDelete", self.network
        )
        self.observe(
            "container-lifecycle",
            "ContainerCreate ContainerInspect ContainerList ContainerStart ContainerWait ContainerLogs ContainerDelete",
            self.lifecycle,
        )
        self.observe(
            "container-events",
            "SystemEvents ContainerCreate ContainerStart ContainerWait ContainerDelete",
            self.events,
        )
        self.observe(
            "archive-roundtrip",
            "ContainerCreate ContainerArchiveInfo ContainerArchive PutContainerArchive ContainerDelete",
            self.archive,
        )
        self.observe(
            "stock-cli-attach",
            "ContainerCreate ContainerAttach ContainerStart ContainerWait",
            self.attach,
        )
        self.observe(
            "stock-cli-exec",
            "ContainerCreate ContainerStart ContainerExec ExecStart ExecInspect",
            self.exec_check,
        )
        self.observe("compose-up-down", "", self.compose)
        self.observe("buildx-local-export", "", self.buildx)
        if self.postgres_runner:
            self.observe("testcontainers-postgres", "", self.postgres)

    def volume(self):
        path = "/volumes/" + self.name
        status, _, payload = self.request(
            "POST", "/volumes/create", body={"Name": self.name, "Labels": self.labels}
        )
        expect(status, 201, payload)
        try:
            detailed = as_json(self.request("GET", path)[2])
            filters = urlencode({"filters": json.dumps({"label": [LABEL + "=" + self.name]})})
            listed = as_json(self.request("GET", "/volumes?" + filters)[2])
            result = {
                "label": detailed["Labels"] == self.labels,
                "driver": detailed["Driver"],
                "listed": [v["Name"] for v in listed["Volumes"]] == [self.name],
            }
        finally:
            deleted, _, data = self.request("DELETE", path)
            expect(deleted, 204, data)
        result["after_delete"] = self.shape(path)
        return result

    def network(self):
        status, _, data = self.request(
            "POST",
            "/networks/create",
            body={"Name": self.name, "Driver": "bridge", "Labels": self.labels},
        )
        expect(status, 201, data)
        net = as_json(data)["Id"]
        try:
            info = as_json(self.request("GET", "/networks/" + net)[2])
            filters = urlencode({"filters": json.dumps({"label": [LABEL + "=" + self.name]})})
            listed = as_json(self.request("GET", "/networks?" + filters)[2])
            return {
                "id": info["Id"] == net,
                "label": info["Labels"] == self.labels,
                "driver": info["Driver"],
                "listed": [item["Id"] for item in listed] == [net],
            }
        finally:
            status, _, data = self.request("DELETE", "/networks/" + net)
            expect(status, 204, data)

    def create(self, command):
        spec = {
            "Image": self.image,
            "Labels": self.labels,
            "Entrypoint": ["/bin/sh"],
            "Cmd": ["-c", command],
            "HostConfig": {"NetworkMode": "none", "Memory": 256 << 20, "NanoCpus": 1000000000},
        }
        status, _, data = self.request("POST", "/containers/create?name=" + self.name, body=spec)
        expect(status, 201, data)
        ident = as_json(data)["Id"]
        if not re.fullmatch("[a-f0-9]{64}", ident):
            raise ValueError("create did not return a full ID")
        return "/containers/" + ident

    def remove(self, path):
        status, _, data = self.request("DELETE", path + "?force=1&v=1")
        expect(status, 204, data)

    def lifecycle(self):
        path = self.create("printf out; printf err >&2; exit 23")
        try:
            info = as_json(self.request("GET", path + "/json")[2])
            filters = urlencode({"all": 1, "filters": json.dumps({"label": [LABEL + "=" + self.name]})})
            status, _, listing = self.request("GET", "/containers/json?" + filters)
            expect(status, 200, listing)
            listed = [obj["Id"] for obj in as_json(listing)]
            conflict, _, error = self.request(
                "POST", "/containers/create?name=" + self.name, body={"Image": self.image}
            )
            start, _, data = self.request("POST", path + "/start")
            expect(start, 204, data)
            status, _, data = self.request("POST", path + "/wait?condition=not-running")
            expect(status, 200, data)
            code = as_json(data)["StatusCode"]
            status, _, data = self.request("GET", path + "/logs?stdout=1&stderr=1")
            expect(status, 200, data)
            return {
                "label": info["Config"]["Labels"].get(LABEL) == self.name,
                "listed": listed == [info["Id"]],
                "memory": info["HostConfig"]["Memory"],
                "conflict": conflict,
                "json_message": bool(as_json(error).get("message")),
                "wait": code,
                "logs": multiplexed(data),
            }
        finally:
            self.remove(path)

    def events(self):
        since = int(time.time()) - 2
        path = self.create("exit 23")
        ident = path.rsplit("/", 1)[-1]
        try:
            status, _, data = self.request("POST", path + "/start")
            expect(status, 204, data)
            status, _, data = self.request("POST", path + "/wait?condition=not-running")
            expect(status, 200, data)
            expect(as_json(data)["StatusCode"], 23, data)
        finally:
            self.remove(path)
        query = urlencode(
            {
                "since": since,
                "until": int(time.time()) + 2,
                "filters": json.dumps({"type": ["container"], "container": [ident]}),
            }
        )
        status, _, data = self.request("GET", "/events?" + query)
        expect(status, 200, data)
        result = []
        for line in data.splitlines():
            event = as_json(line)
            action = event["Action"]
            if action in {"create", "start", "die", "destroy", "remove"}:
                actor = event["Actor"]
                result.append(
                    {
                        "action": action,
                        "same_id": actor["ID"] == ident,
                        "exit_code": actor.get("Attributes", {}).get("exitCode"),
                    }
                )
        return result

    def archive(self):
        path = self.create("true")
        try:
            payload = io.BytesIO()
            with tarfile.open(fileobj=payload, mode="w") as archive:
                file = tarfile.TarInfo("probe")
                file.size, file.mode = 3, 0o640
                archive.addfile(file, io.BytesIO(b"a\x00b"))
            status, _, data = self.request(
                "PUT",
                path + "/archive?path=/tmp",
                body=payload.getvalue(),
                headers={"Content-Type": "application/x-tar"},
            )
            expect(status, 200, data)
            route = path + "/archive?path=/tmp/probe"
            status, headers, _ = self.request("HEAD", route)
            expect(status, 200, b"")
            meta = json.loads(base64.b64decode(headers["x-docker-container-path-stat"]))
            status, _, data = self.request("GET", route)
            expect(status, 200, data)
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                member = next((item for item in archive if item.isfile()), None)
                if member is None:
                    raise ValueError("archive omitted probe")
                return {
                    "size": meta["size"],
                    "name": meta["name"],
                    "mode": member.mode,
                    "bytes": archive.extractfile(member).read().hex(),
                }
        finally:
            self.remove(path)

    def attach(self):
        name = self.name + "-attach"
        try:
            result = self.cli(
                "run",
                "--name",
                name,
                "--rm",
                "-i",
                "--pull=never",
                "--network",
                "none",
                "--label",
                LABEL + "=" + self.name,
                "--entrypoint",
                "/bin/sh",
                self.image,
                "-c",
                "cat; printf stderr >&2; exit 23",
                data=b"stdin\x00\xff",
            )
            return {
                "code": result.returncode,
                "stdout": result.stdout.hex(),
                "stderr": result.stderr[:160].decode(errors="replace"),
            }
        finally:
            self.cleanup_cli(name)

    def cleanup_cli(self, name):
        owned = self.cli(
            "container", "inspect", "--format", '{{index .Config.Labels "' + LABEL + '"}}', name
        )
        if owned.returncode == 0 and owned.stdout.decode().strip() == self.name:
            p = self.cli("rm", "-fv", name)
            expect(p.returncode, 0, p.stderr)

    def exec_check(self):
        path = self.create("exec sleep 120")
        try:
            status, _, data = self.request("POST", path + "/start")
            expect(status, 204, data)
            p = self.cli(
                "exec",
                path.split("/")[-1],
                "sh",
                "-c",
                'printf "%s" "$1"; printf error >&2; exit 41',
                "sh",
                "two words",
            )
            return {"code": p.returncode, "stdout": p.stdout.decode(), "stderr": p.stderr.decode()[:160]}
        finally:
            self.remove(path)

    def compose(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "compose.json"
            config.write_text(
                json.dumps(
                    {
                        "services": {
                            "job": {
                                "image": self.image,
                                "container_name": self.name,
                                "labels": self.labels,
                                "network_mode": "none",
                                "entrypoint": ["/bin/sh"],
                                "command": ["-c", "echo compose-ok"],
                            }
                        }
                    }
                )
            )
            cmd = ["compose", "-p", self.name, "-f", str(config)]
            try:
                p = self.cli(*cmd, "up", "--pull", "never", "--no-build", "-d")
                expect(p.returncode, 0, p.stderr)
                wait = self.cli("wait", self.name)
                expect(wait.returncode, 0, wait.stderr)
                logs = self.cli("logs", self.name)
                expect(logs.returncode, 0, logs.stderr)
                return {"exit": wait.stdout.decode().strip(), "log": logs.stdout.decode().strip()}
            finally:
                p = self.cli(*cmd, "down", "--timeout", "1")
                expect(p.returncode, 0, p.stderr)

    def buildx(self):
        tag = "micropod-internal/engine-test:" + self.name
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "Dockerfile").write_text("FROM scratch\nCOPY marker /marker\n")
            (Path(directory) / "marker").write_bytes(b"engine-test")
            try:
                p = self.cli(
                    "buildx",
                    "build",
                    "--builder",
                    "default",
                    "--load",
                    "--network",
                    "none",
                    "--provenance=false",
                    "--label",
                    LABEL + "=" + self.name,
                    "--tag",
                    tag,
                    directory,
                    timeout=60,
                )
                expect(p.returncode, 0, p.stderr)
                owned = self.cli(
                    "image", "inspect", "--format", '{{index .Config.Labels "' + LABEL + '"}}', tag
                )
                expect(owned.returncode, 0, owned.stderr)
                return owned.stdout.decode().strip() == self.name
            finally:
                info = self.cli(
                    "image", "inspect", "--format", '{{index .Config.Labels "' + LABEL + '"}}', tag
                )
                if info.returncode == 0 and info.stdout.decode().strip() == self.name:
                    p = self.cli("image", "rm", tag)
                    expect(p.returncode, 0, p.stderr)

    def postgres(self):
        name = self.name + "-pg"
        try:
            result = self.cli(
                "run",
                "--rm",
                "--pull=never",
                "--name",
                name,
                "--network",
                "host",
                "--label",
                LABEL + "=" + self.name,
                "-v",
                self.guest_socket + ":/var/run/docker.sock",
                "-e",
                "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=" + self.guest_socket,
                "-e",
                "TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1",
                "--entrypoint",
                "/out/postgres-test",
                self.postgres_runner,
                "-test.v",
                "-test.timeout=180s",
                timeout=195,
            )
            expect(result.returncode, 0, result.stdout + result.stderr)
            return {
                "sql_round_trip": b"verified SQL round trip" in result.stdout,
                "passed": b"--- PASS: TestPostgresReady" in result.stdout,
            }
        finally:
            self.cleanup_cli(name)


def multiplexed(data):
    streams = {1: bytearray(), 2: bytearray()}
    while data:
        if len(data) < 8:
            raise ValueError("truncated Docker log header")
        stream, length = struct.unpack(">BxxxI", data[:8])
        if stream not in streams or length > len(data) - 8:
            raise ValueError("invalid Docker log frame")
        streams[stream].extend(data[8 : 8 + length])
        data = data[8 + length :]
    return [v.hex() for v in streams.values()]


def as_json(data):
    return json.loads(data)


def expect(actual, expected, diagnostic):
    if actual != expected:
        raise ValueError(
            f"expected {expected}, got {actual}: {diagnostic.decode(errors='replace')[-400:]}"
        )


def operation_inventory(raw):
    """Read the route index of the exact, checksummed v1.56 spec using the standard library."""
    if hashlib.sha256(raw).hexdigest() != SPEC_SHA256:
        raise ValueError("expected the pinned Engine 1.56 specification")
    operations = []
    path = None
    lines = iter(raw.decode().split("\npaths:\n", 1)[1].splitlines())
    for line in lines:
        if line.startswith("  /"):
            path = line.strip().removesuffix(":")
        elif match := re.fullmatch(r"    (get|post|put|patch|head|delete|options):", line):
            operations.append({"method": match[1].upper(), "path": path})
        elif line.startswith("      operationId: "):
            operations[-1]["id"] = json.loads(line.split(": ", 1)[1])
        elif line.startswith("      tags: "):
            operations[-1]["group"] = json.loads(line.split(": ", 1)[1])[0]
        elif line == "      tags:":
            operations[-1]["group"] = json.loads(next(lines).removeprefix("        - "))
    return {op.pop("id"): op for op in operations}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for side in ["reference", "candidate"]:
        p.add_argument("--" + side, type=Path, required=True, help="Local Unix socket")
        p.add_argument("--" + side + "-image", required=True, help="Preloaded offline shell fixture")
        p.add_argument(
            "--" + side + "-guest-socket",
            default="/var/run/docker.sock",
            help="Socket path inside this engine's trusted guest, mounted by the optional integration fixture",
        )
    p.add_argument(
        "--postgres-runner",
        help="Optional preloaded ci/samples/go-app/Dockerfile.checks image on both engines",
    )
    p.add_argument(
        "--spec", type=Path, required=True, help="Unmodified Moby api/v1.56.1 docs/v1.56.yaml"
    )
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--database", type=Path, default=DEFAULT_DB)
    args = p.parse_args()
    try:
        inventory = operation_inventory(args.spec.read_bytes())
    except ValueError as exc:
        p.error(str(exc))
    if args.reference.samefile(args.candidate):
        p.error("select two different Unix sockets")
    result = {
        "run": uuid.uuid4().hex,
        "version": VERSION,
        "spec_sha256": SPEC_SHA256,
        "operations": inventory,
    }
    for name in ["reference", "candidate"]:
        engine = Engine(
            getattr(args, name),
            getattr(args, name + "_image"),
            args.postgres_runner,
            getattr(args, name + "_guest_socket"),
        )
        engine.run()
        result[name] = engine.cases
    for name, ref in result["reference"].items():
        peer = result["candidate"][name]
        peer["comparison"] = (
            "reference-failed"
            if "error" in ref
            else "different"
            if "error" in peer or ref["observed"] != peer["observed"]
            else "matched"
        )
        for op in ref["operations"]:
            inventory[op].setdefault("cases", []).append(name)
    result["captured_unix"] = time.time()
    args.output.write_bytes(gzip.compress(json.dumps(result, sort_keys=True).encode(), mtime=0))
    store(args.database, result["run"], "docker-engine-contract", result)
    for name, value in result["candidate"].items():
        print(value["comparison"], name, value.get("error", "")[:150])
    if any(v["comparison"] == "reference-failed" for v in result["candidate"].values()):
        raise SystemExit(2)
    if any(v["comparison"] != "matched" for v in result["candidate"].values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
