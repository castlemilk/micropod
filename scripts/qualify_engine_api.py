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
VERSION = "1.56"
SPEC_DIGESTS = {
    "1.47": "f44c4514b5893e043cbe3e1675b67b9eed86fc26b6c15144bddcb02c46d2ca7e",
    "1.56": "00ccd7d2e6e0b7a943ac0067007d181d723b2513ef1f6af3b6b54145314a6fa7",
}


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=15)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.path))


class Engine:
    def __init__(self, endpoint, image, postgres_runner, guest_socket, *, api_version=None):
        self.endpoint = endpoint
        self.image = image
        self.postgres_runner = postgres_runner
        self.guest_socket = guest_socket
        self.cases = {}
        self.name = "mp-engine-" + uuid.uuid4().hex
        self.labels = {LABEL: self.name}
        self.prefix = "/v" + (api_version or VERSION)
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
        if api_version:
            self.env["DOCKER_API_VERSION"] = api_version

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

    def run(self, *, engine_only=False):
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
        self.observe("image-tag", "ImageTag ImageInspect ImageDelete", self.image_tag)
        self.observe("image-list-labels", "ImageList", self.image_list_labels)
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
        if engine_only:
            return
        self.observe("compose-up-down", "", self.compose)
        self.observe("buildx-local-export", "", self.buildx)
        if self.postgres_runner:
            self.observe("testcontainers-postgres", "", self.postgres)

    def image_tag(self):
        repo = "micropod-qa/" + self.name
        alias = repo + ":qualification"
        path = "/images/" + alias
        source = "/images/" + quote(self.image, safe=":/")
        code, _, data = self.request("GET", source + "/json")
        expect(code, 200, data)
        original = as_json(data)
        code, _, data = self.request("GET", path + "/json")
        expect(code, 404, data)
        try:
            query = urlencode({"repo": repo, "tag": "qualification"})
            code, _, data = self.request("POST", source + "/tag?" + query)
            expect(code, 201, data)
            empty = not data
            code, _, data = self.request("GET", path + "/json")
            expect(code, 200, data)
            tagged = as_json(data)
            result = {
                "empty_response": empty,
                "same_id": tagged["Id"] == original["Id"],
                "same_layers": tagged["RootFS"] == original["RootFS"],
                "listed_tag": alias in [tag.removeprefix("docker.io/") for tag in tagged["RepoTags"]],
            }
        finally:
            code, _, data = self.request("GET", path + "/json")
            if code != 404:
                expect(code, 200, data)
                if as_json(data)["Id"] != original["Id"]:
                    raise ValueError("qualification tag now points to a different image")
                code, _, data = self.request("DELETE", path)
                expect(code, 200, data)
                if not any(row.get("Untagged", "").removeprefix("docker.io/") == alias for row in as_json(data)):
                    raise ValueError("image removal did not report the qualification tag")
        result["removed"] = self.request("GET", path + "/json")[0] == 404
        code, _, data = self.request("GET", source + "/json")
        expect(code, 200, data)
        result["source_preserved"] = as_json(data)["Id"] == original["Id"]
        return result

    def image_list_labels(self):
        color, gate = (f"{LABEL}.{self.name}.{key}" for key in ("color", "gate"))
        fixture_labels = {
            "selected": {**self.labels, color: "blue", gate: "yes"},
            "empty": {**self.labels, color: "blue", gate: ""},
            "missing": {**self.labels, gate: "yes"},
        }
        refs = {role: f"micropod-qa/{self.name}-image-labels:{role}" for role in fixture_labels}

        def list_images(filters=None):
            query = {"all": 1}
            if filters is not None:
                query["filters"] = filters
            code, _, data = self.request("GET", "/images/json?" + urlencode(query))
            return code, as_json(data)

        def inventory():
            code, rows = list_images()
            if code != 200 or not isinstance(rows, list):
                raise ValueError("could not establish the image inventory")
            return {row["Id"] for row in rows}

        def owned_id(role, row, present_before):
            image_id = row["Id"]
            if (not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id) or image_id in present_before or
                row.get("Config", {}).get("Labels") != fixture_labels[role]):
                raise ValueError(f"image {role} is outside the qualification scope")
            return image_id

        code, base = self.inspect_image(self.image)
        if code != 200:
            raise ValueError("could not inspect the preloaded image")
        present_before = inventory()
        if any(self.inspect_image(ref)[0] != 404 for ref in refs.values()):
            raise ValueError("qualification image tags must be absent before loading")
        archive, config_ids = image_label_archive(refs, fixture_labels, base["Architecture"])
        image_ids = {}
        observations = {}
        try:
            loaded = self.cli("image", "load", "--quiet", data=archive)
            expect(loaded.returncode, 0, loaded.stderr + loaded.stdout)
            for role, ref in refs.items():
                code, row = self.inspect_image(ref)
                if code != 200:
                    raise ValueError(f"loaded image {role} is absent")
                image_ids[role] = owned_id(role, row, present_before)
            by_id = {image_id: role for role, image_id in image_ids.items()}
            if len(by_id) != len(refs):
                raise ValueError("qualification images must have distinct IDs")

            def selections(ids, wanted):
                return {"roles": sorted(by_id[image_id] for image_id in ids if image_id in by_id),
                        "rows": len(ids), "unexpected_rows": sum(by_id.get(image_id) not in wanted for image_id in ids)}

            def filtered(filters, wanted):
                code, rows = list_images(filters)
                result = {"status": code}
                if code == 200 and isinstance(rows, list):
                    return {**result, **selections([row["Id"] for row in rows], wanted)}
                return {**result, "json_message": isinstance(rows, dict) and bool(rows.get("message"))}

            for name, values, wanted in (
                ("key-only", [color], {"selected", "empty"}),
                ("exact", [color + "=blue"], {"selected", "empty"}),
                ("conjunction", [color + "=blue", gate + "=yes"], {"selected"}),
                ("empty-value", [gate + "="], {"empty"}),
                ("absent-is-not-empty", [color + "="], set()),
                ("wrong-value", [color + "=absent"], set()),
                ("missing-key", [color + ".absent"], set()),
            ):
                result = filtered(json.dumps({"label": values}), wanted)
                cli_filters = [part for value in values for part in ("--filter", "label=" + value)]
                listed = self.cli("image", "ls", "--all", "--no-trunc", "--quiet", *cli_filters)
                result["cli_exit"] = listed.returncode
                result["cli"] = selections(listed.stdout.decode().splitlines(), wanted)
                observations[name] = result

            for name, raw in (("malformed-json", "{"), ("malformed-values", '{"label":1}'),
                              ("unknown-filter", '{"micropod-qualification-unknown":["x"]}')):
                observations[name] = filtered(raw, set())
            status, rows = list_images('{"label":[]}')
            observations["empty-set"] = {"status": status, "same_as_unfiltered":
                                         status == 200 and isinstance(rows, list) and {row["Id"] for row in rows} == inventory()}
        finally:
            for role, ref in refs.items():
                code, row = self.inspect_image(ref)
                if code == 404:
                    continue
                if code != 200:
                    raise ValueError(f"could not check ownership of tag {role}")
                image_id = owned_id(role, row, present_before)
                if image_ids.setdefault(role, image_id) != image_id:
                    raise ValueError(f"qualification tag {role} changed targets")
                removed = self.cli("image", "rm", "--no-prune", ref)
                expect(removed.returncode, 0, removed.stderr)

            for role in refs:
                # Containerd-backed Docker reports a manifest ID. The config ID
                # also gives native a cleanup address after an interrupted load.
                image_id = image_ids.get(role, config_ids[role])
                if image_id in present_before:
                    raise ValueError(f"qualification image {role} existed before fixture load")
                self.remove_owned_image_id(image_id, fixture_labels[role])

        verified_ids = {image_ids.get(role, config_ids[role]) for role in refs}
        after = inventory()
        # The runtime image inventory may briefly lag authoritative removal.
        until = time.monotonic() + 3
        while verified_ids & after and time.monotonic() < until:
            time.sleep(0.03)
            after = inventory()
        code, current_base = self.inspect_image(self.image)
        observations["cleanup"] = {
            "tags_absent": all(self.inspect_image(ref)[0] == 404 for ref in refs.values()),
            "ids_absent": all(self.inspect_image(image_id)[0] == 404 for image_id in verified_ids),
            "listed_ids_absent": not (verified_ids & after),
            "existing_ids_preserved": present_before <= after,
            "preloaded_image_preserved": code == 200 and current_base.get("Id") == base["Id"] and current_base.get("RootFS") == base.get("RootFS"),
        }
        if not all(observations["cleanup"].values()):
            raise ValueError(f"image-filter qualification cleanup failed {observations['cleanup']}")
        return observations

    def inspect_image(self, ref):
        code, _, data = self.request("GET", "/images/" + quote(ref, safe=":/") + "/json")
        return code, as_json(data)

    def remove_owned_image_id(self, image_id, labels):
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
            raise ValueError("qualification image ID must be an exact SHA-256 digest")
        until = time.monotonic() + 3
        while True:
            code, row = self.inspect_image(image_id)
            if code == 404:
                return
            if code != 200 or row.get("Id") != image_id or (row.get("Config") or {}).get("Labels") != labels:
                raise ValueError("could not confirm ownership of the qualification image")
            if not row.get("RepoTags"):
                removed = self.cli("image", "rm", "--force", "--no-prune", image_id)
                expect(removed.returncode, 0, removed.stderr)
                if self.inspect_image(image_id)[0] != 404:
                    raise ValueError("the owned qualification image ID remained after removal")
                return
            if time.monotonic() >= until:
                raise ValueError("qualification image still has named references")
            time.sleep(0.03)

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
        if self.inspect_image(tag)[0] != 404:
            raise ValueError("qualification build tag must be absent before the build")
        image_id = None
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
                inspected = self.cli("image", "inspect", "--format", "{{json .}}", tag)
                expect(inspected.returncode, 0, inspected.stderr)
                actual = as_json(inspected.stdout)
                if (actual.get("Config") or {}).get("Labels") != self.labels:
                    raise ValueError("could not confirm ownership of the Buildx fixture")
                image_id = actual["Id"]
                return True
            finally:
                code, current = self.inspect_image(tag)
                if code != 404:
                    if (code != 200 or (current.get("Config") or {}).get("Labels") != self.labels or
                        (image_id is not None and current.get("Id") != image_id)):
                        raise ValueError("refusing to remove a tag outside the Buildx fixture")
                    image_id = current["Id"]
                    p = self.cli("image", "rm", "--no-prune", tag)
                    expect(p.returncode, 0, p.stderr)
                    if self.inspect_image(tag)[0] != 404:
                        raise ValueError("the owned Buildx fixture tag remained after removal")
                if image_id:
                    self.remove_owned_image_id(image_id, self.labels)

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


def image_label_archive(refs, labels, architecture):
    def pack(entries):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w") as archive:
            for name, data in entries:
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        return stream.getvalue()

    layer = pack([("fixture-labels", next(iter(refs.values())).encode())])
    layers = ["sha256:" + hashlib.sha256(layer).hexdigest()]
    files, entries, ids = [("layer.tar", layer)], [], {}
    for role, ref in refs.items():
        config = json.dumps({"architecture": architecture, "os": "linux", "config": {"Labels": labels[role]},
                             "rootfs": {"type": "layers", "diff_ids": layers}}, sort_keys=True).encode()
        digest = hashlib.sha256(config).hexdigest()
        ids[role] = "sha256:" + digest
        name = digest + ".json"
        files.append((name, config))
        entries.append({"Config": name, "RepoTags": [ref], "Layers": ["layer.tar"]})
    return pack([("manifest.json", json.dumps(entries).encode()), *files]), ids


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


def operation_inventory(raw, version=VERSION):
    """Read the route index of the checksummed Moby specification for this wire version."""
    if hashlib.sha256(raw).hexdigest() != SPEC_DIGESTS[version]:
        raise ValueError(f"expected the pinned Engine {version} specification")
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
        "--spec", type=Path, required=True,
        help="Unmodified Moby v27.5.1 api/swagger.yaml for 1.47 or api/v1.56.1 docs/v1.56.yaml for 1.56",
    )
    p.add_argument("--api-version", choices=SPEC_DIGESTS,
                   help="Pin both the HTTP probes and Docker client to this version (default HTTP 1.56, client negotiates)")
    p.add_argument("--engine-only", action="store_true",
                   help="Run Engine HTTP and stock docker attach/exec probes, omitting Compose, Buildx and Testcontainers")
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--database", type=Path, default=DEFAULT_DB)
    args = p.parse_args()
    version = args.api_version or VERSION
    if args.engine_only and args.postgres_runner:
        p.error("--postgres-runner requires the full qualification")
    try:
        inventory = operation_inventory(args.spec.read_bytes(), version)
    except ValueError as exc:
        p.error(str(exc))
    if args.reference.samefile(args.candidate):
        p.error("select two different Unix sockets")
    result = {
        "run": uuid.uuid4().hex,
        "version": version,
        "cli_api_version": args.api_version or "negotiated",
        "profile": "engine" if args.engine_only else "full",
        "spec_sha256": SPEC_DIGESTS[version],
        "operations": inventory,
        "scopes": {},
    }
    for name in ["reference", "candidate"]:
        engine = Engine(
            getattr(args, name),
            getattr(args, name + "_image"),
            args.postgres_runner,
            getattr(args, name + "_guest_socket"),
            api_version=args.api_version,
        )
        result["scopes"][name] = {"labels": engine.labels, "image": engine.image}
        engine.run(engine_only=args.engine_only)
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
