#!/usr/bin/env python3
"""Exercise the stock Go Testcontainers client against one explicit Unix Docker socket."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
from tempfile import TemporaryDirectory
import time
from urllib.parse import quote, urlencode
from uuid import uuid4

from qualify_engine_api import Engine

OWNER = "io.micropod.qualification.testcontainers"
SESSION = "org.testcontainers.sessionId"
RYUK = "testcontainers/ryuk:0.13.0"
CONTAINER_ID = re.compile(r"[a-f0-9]{64}")
SESSION_ID = re.compile(r"[a-zA-Z0-9_-]{16,128}")


def sha_file(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def checked_image(engine, name):
    code, image = engine.inspect_image(name)
    require(code == 200 and (image.get("Os"), image.get("Architecture")) == ("linux", "arm64"),
            "Expected a preloaded Linux ARM64 image: " + name)
    return {key: image.get(key) for key in ("Id", "RootFS", "RepoDigests")}


class Probe:
    def __init__(self, engine, scope, report, abandon_resources=False):
        self.engine = engine
        self.scope = scope
        self.report = report
        self.session = None
        self.abandon_resources = abandon_resources
        self.networks = {scope + "-network-a", scope + "-network-b"}
        self.volumes = {scope + "-volume", scope + "-volume-control"}
        self.containers = {scope, scope + "-other", scope + "-service", scope + "-peer-0", scope + "-peer-1"}

    def request(self, method, path, body=None):
        code, _, payload = self.engine.request(method, path, body=body)
        return code, json.loads(payload) if payload else None

    def inventory(self, resource, label):
        path = {"containers": "/containers/json", "networks": "/networks", "volumes": "/volumes"}[resource]
        query = urlencode({"all": 1, "filters": json.dumps({"label": [label]})})
        code, data = self.request("GET", path + "?" + query)
        require(code == 200, "Could not verify owned " + resource + ": " + repr(data))
        if resource == "volumes":
            data = data.get("Volumes") or []
        require(isinstance(data, list), "Unexpected " + resource + " inventory")
        return data

    def scope_rows(self):
        label = OWNER + "=" + self.scope
        return {kind: self.inventory(kind, label) for kind in ("containers", "networks", "volumes")}

    def reapers(self):
        if self.session is None:
            return []
        rows = self.inventory("containers", SESSION + "=" + self.session)
        return [row for row in rows if row.get("Labels", {}).get("org.testcontainers.ryuk") == "true"]

    def update_event(self, event, subprocess_stdin):
        self.report["events"].append(event)
        if event.get("event") == "session":
            require(self.session is None and SESSION_ID.fullmatch(event.get("id", "")), "Unexpected fixture session")
            self.session = event["id"]
            self.report["session"] = self.session
        if event.get("event") == "abandon-ready":
            owned = self.scope_rows()["containers"]
            reapers = self.reapers()
            require(len(owned) == 1 and owned[0]["Id"] == event.get("id") and owned[0]["State"] == "running",
                    "Abandoned fixture had no live owned container")
            require(len(reapers) == 1 and reapers[0]["State"] == "running", "Stock Ryuk was not running")
            reaper = reapers[0]
            code, full = self.request("GET", "/containers/" + reaper["Id"] + "/json")
            require(code == 200 and full["Image"] == self.report["baselines_before"][RYUK]["Id"], "Different Ryuk image started")
            self.report["before_client_exit"] = {"fixture_id": owned[0]["Id"], "ryuk_id": reaper["Id"], "ryuk_image": full["Image"],
                                                 "fixture_labels": owned[0]["Labels"], "ryuk_labels": reaper["Labels"]}
            if self.abandon_resources:
                self.create_reaper_resources(self.report["before_client_exit"])
            subprocess_stdin.write(b"exit fixture\n")
            subprocess_stdin.flush()

    def create_reaper_resources(self, before):
        labels = before["fixture_labels"]
        require(labels.get(SESSION) == self.session and labels.get("org.testcontainers.reap") == "true",
                "The stock client did not label its fixture for reaping")
        active = dict(labels)
        control = {**active, SESSION: uuid4().hex + uuid4().hex}
        before["named_resources"] = {}
        for role, resource_labels in (("active", active), ("control", control)):
            network = self.scope + ("-network-a" if role == "active" else "-network-b")
            volume = self.scope + ("-volume" if role == "active" else "-volume-control")
            code, info = self.request("POST", "/networks/create",
                                      {"Name": network, "Driver": "bridge", "Labels": resource_labels})
            require(code == 201 and CONTAINER_ID.fullmatch(info.get("Id", "")), "Could not create the scoped bridge")
            before["named_resources"][role] = {"network_name": network, "network_id": info["Id"], "volume_name": volume,
                                                "labels": resource_labels}
            code, info = self.request("POST", "/volumes/create", {"Name": volume, "Driver": "local", "Labels": resource_labels})
            require(code == 201 and info.get("Name") == volume, "Could not create the scoped volume")

    def run_client(self, binary, image, mode, directory, env):
        stdout = bytearray()
        pending = b""
        result = None
        log = directory / "testcontainers-stderr.log"
        deadline = time.monotonic() + 55
        with log.open("w+b") as stderr, selectors.DefaultSelector() as select:
            proc = subprocess.Popen([str(binary), "-image", image, "-name", self.scope, "-mode", mode],
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, env=env)
            try:
                select.register(proc.stdout, selectors.EVENT_READ)
                while select.get_map():
                    remaining = deadline - time.monotonic()
                    require(remaining > 0, "The stock test process timed out")
                    for ready, _ in select.select(min(remaining, 2)):
                        chunk = os.read(ready.fileobj.fileno(), 16384)
                        if not chunk:
                            select.unregister(ready.fileobj)
                            continue
                        stdout.extend(chunk)
                        require(len(stdout) <= 250000, "The fixture printed more data than allowed")
                        lines = (pending + chunk).split(b"\n")
                        pending = lines.pop()
                        for line in lines:
                            if line.startswith(b"{"):
                                event = json.loads(line)
                                self.update_event(event, proc.stdin)
                                if event.get("event") == "result":
                                    result = event
                self.report["client_exit"] = proc.wait(timeout=3)
                require(self.report["client_exit"] == 0 and result is not None and result.get("passed"),
                        (result or {}).get("error", "Stock client exited without a successful result"))
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=3)
                proc.stdin.close()
                proc.stdout.close()
                stderr.seek(0)
                self.report["stdout"] = stdout.decode(errors="replace")
                self.report["stderr"] = stderr.read(250000).decode(errors="replace")

    def automatic_cleanup(self):
        before = self.report.get("before_client_exit")
        require(before is not None, "The live fixture and reaper were not verified before client exit")
        deadline = time.monotonic() + 28
        while True:
            fixture, _ = self.request("GET", "/containers/" + before["fixture_id"] + "/json")
            ryuk, _ = self.request("GET", "/containers/" + before["ryuk_id"] + "/json")
            self.report["automatic_cleanup"] = {"fixture_status": fixture, "ryuk_status": ryuk, "used_manual_cleanup": False}
            if self.abandon_resources:
                resources = {}
                for role, config in before["named_resources"].items():
                    network, net_info = self.request("GET", "/networks/" + config["network_id"])
                    volume, vol_info = self.request("GET", "/volumes/" + config["volume_name"])
                    resources[role] = {"network": network, "volume": volume}
                    if role == "control":
                        require(network == volume == 200 and net_info.get("Name") == config["network_name"]
                                and net_info.get("Labels") == vol_info.get("Labels") == config["labels"],
                                "Ryuk disturbed a resource belonging to another session")
                self.report["automatic_cleanup"]["named_resources"] = resources
            if fixture == ryuk == 404:
                if self.abandon_resources:
                    require(set(resources["active"].values()) == {404}, "Ryuk exited before removing its named resources")
                return
            if time.monotonic() >= deadline:
                raise RuntimeError("Ryuk did not remove the abandoned fixture and itself")
            time.sleep(0.15)

    def raw_name_filters(self, image):
        names = (self.scope, self.scope + "-other", self.scope + "-peer-0")
        for name in names:
            result = self.engine.cli("create", "--pull=never", "--network", "none", "--name", name,
                                     "--label", OWNER + "=" + self.scope, image, "true")
            require(result.returncode == 0, result.stderr.decode(errors="replace"))
        scoped = self.scope_rows()["containers"]
        ids = {row["Names"][0].lstrip("/"): row["Id"] for row in scoped}
        require(set(ids) == set(names), "Wire selector fixture identification failed")
        cases = (
            ("literal-substring", [self.scope], names, {}),
            ("exact", {"^" + self.scope + "$": True}, names[:1], {}),
            ("slash", ["^/" + self.scope + "$"], names[:1], {}),
            ("regex-alternation", ["^" + self.scope + "-(other|peer-0)$"], names[1:], {}),
            ("invalid-regex", ["["], (), {}),
            ("invalid-plus-valid", ["[", "^" + names[1] + "$"], names[1:2], {}),
            ("false-set-member", {"^" + self.scope + "$": False}, names[:1], {}),
            ("empty-list", [], names, {}),
            ("composition", [self.scope], names[1:2], {"id": [ids[names[1]][:12]], "status": ["created"], "ancestor": [image]}),
        )
        self.report["selectors"] = {}
        for name, patterns, wanted, other in cases:
            owner = OWNER + "=" + self.scope
            label = {owner: True} if isinstance(patterns, dict) else [owner]
            filters = {"label": label, "name": patterns, **other}
            code, rows = self.request("GET", "/containers/json?" + urlencode({"all": 1, "filters": json.dumps(filters)}))
            got = [row["Id"] for row in rows] if code == 200 else []
            self.report["selectors"][name] = {"status": code, "returned": got, "wanted": sorted(ids[n] for n in wanted),
                                               "filters": filters, "passed": code == 200 and sorted(got) == sorted(ids[n] for n in wanted)}
        require(all(case["passed"] for case in self.report["selectors"].values()), "Docker container-name selector controls differed")

    def raw_network_lifecycle(self, image, connect_expected):
        labels = {OWNER: self.scope}
        first, second = sorted(self.networks)
        ids = {}
        for name in (first, second):
            code, row = self.request("POST", "/networks/create", {"Name": name, "Driver": "bridge", "Labels": labels})
            require(code == 201 and CONTAINER_ID.fullmatch(row.get("Id", "")), "Could not create a scoped control bridge")
            ids[name] = row["Id"]
        name = self.scope + "-service"
        code, row = self.request("POST", "/containers/create?" + urlencode({"name": name}),
                                 {"Image": image, "Entrypoint": ["/bin/sh", "-ec"], "Cmd": ["exec sleep 30"],
                                  "Labels": labels, "HostConfig": {"NetworkMode": first}})
        require(code == 201 and CONTAINER_ID.fullmatch(row.get("Id", "")), "Could not create the control container")
        container = row["Id"]
        inspect_path = "/containers/" + container + "/json"
        code, _ = self.request("POST", "/containers/" + container + "/start")
        require(code == 204, "Could not start the network lifecycle control")
        code, before = self.request("GET", inspect_path)
        require(code == 200 and before["State"]["Running"] and set(before["NetworkSettings"]["Networks"]) == {first},
                "Control was not running on the selected first network")
        connect_path = "/networks/" + ids[second] + "/connect"
        endpoint = {"Container": container, "EndpointConfig": {"Aliases": [self.scope + "-alias-b"]}}
        code, body = self.request("POST", connect_path, endpoint)
        self.report["network_connect"] = {"method": "POST", "path": self.engine.prefix + connect_path, "request": endpoint,
                                          "status": code, "body": body}
        require(code == connect_expected, "Unexpected running NetworkConnect status: " + str(code))
        code, after = self.request("GET", inspect_path)
        expected = {first, second} if connect_expected == 200 else {first}
        attached = after["NetworkSettings"]["Networks"] if code == 200 else {}
        require(code == 200 and after["State"]["Running"] and set(attached) == expected,
                "Unexpected attachment state after NetworkConnect")
        if connect_expected == 200:
            require(self.scope + "-alias-b" in attached[second]["Aliases"], "Stock NetworkConnect lost its endpoint alias")
        self.report["network_connect"]["networks_after"] = sorted(attached)
        stop_path = "/containers/" + container + "/stop?t=1"
        code, body = self.request("POST", stop_path)
        self.report["container_stop"] = {"method": "POST", "path": self.engine.prefix + stop_path, "status": code, "body": body}
        require(code == 204, "Unexpected ContainerStop status: " + str(code))
        code, stopped = self.request("GET", inspect_path)
        require(code == 200 and not stopped["State"]["Running"] and stopped["State"]["Status"] == "exited",
                "Control did not reach exited state after ContainerStop")
        self.report["container_stop"]["container_state"] = "exited"

    def recover_scope(self):
        scoped = self.scope_rows()
        reapers = self.reapers()
        mutable = list(scoped["containers"]) + reapers
        recovered = self.report.setdefault("manual_cleanup", [])
        for row in mutable:
            key = row.get("Id", "")
            require(CONTAINER_ID.fullmatch(key), "Refusing malformed container ID")
            code, inspect = self.request("GET", "/containers/" + key + "/json")
            if code == 404:
                continue
            labels = inspect.get("Config", {}).get("Labels") or {} if code == 200 else {}
            name = inspect.get("Name", "").lstrip("/") if code == 200 else ""
            owned = labels.get(OWNER) == self.scope and name in self.containers
            owned_reaper = (self.session is not None and labels.get(SESSION) == self.session
                            and labels.get("org.testcontainers.ryuk") == "true" and labels.get("org.testcontainers.reaper") == "true"
                            and name == "reaper_" + self.session)
            require(code == 200 and (owned or owned_reaper), "Refusing nonfixture container cleanup: " + name)
            status, body = self.request("DELETE", "/containers/" + key + "?force=1&v=1")
            require(status in (204, 404), "Scoped container cleanup failed: " + repr(body))
            recovered.append({"kind": "container", "id": key, "name": name})
        for row in scoped["networks"]:
            key = row.get("Id", "")
            name = row.get("Name", "")
            require(CONTAINER_ID.fullmatch(key) and name in self.networks, "Refusing nonfixture network cleanup")
            status, details = self.request("GET", "/networks/" + key)
            if status == 404:
                continue
            require(status == 200 and details.get("Labels", {}).get(OWNER) == self.scope,
                    "Refusing to remove a network without the scope label")
            code, body = self.request("DELETE", "/networks/" + key)
            require(code in (204, 404), "Scoped network cleanup failed: " + repr(body))
            recovered.append({"kind": "network", "id": key, "name": name})
        for row in scoped["volumes"]:
            name = row.get("Name", "")
            require(self.abandon_resources and name in self.volumes, "Refusing nonfixture volume cleanup")
            status, details = self.request("GET", "/volumes/" + name)
            if status == 404:
                continue
            require(status == 200 and details.get("Labels", {}).get(OWNER) == self.scope,
                    "Refusing to remove a volume without the scope label")
            code, body = self.request("DELETE", "/volumes/" + name)
            require(code in (204, 404), "Scoped volume cleanup failed: " + repr(body))
            recovered.append({"kind": "volume", "name": name})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--image", required=True, help="preloaded Linux ARM64 Alpine with BusyBox")
    parser.add_argument("--preserve-image", action="append", default=[])
    parser.add_argument("--client", type=Path, required=True)
    parser.add_argument("--mode", choices=("core", "name-filters", "single-network", "multi-network", "ryuk-abandon", "network-api"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--api-version", default="1.47")
    parser.add_argument("--ryuk-image-id", help="exact local ID of the separately staged stock Ryuk image")
    parser.add_argument("--abandon-resources", action="store_true", help="also leave an owned bridge and volume for real Ryuk")
    parser.add_argument("--network-connect-status", choices=(200, 501), type=int, default=200)
    args = parser.parse_args()
    require(args.socket.is_socket() and args.client.is_file() and not args.output.exists(), "Expected explicit local paths and a fresh receipt")
    ryuk = args.mode == "ryuk-abandon"
    require(not ryuk or args.ryuk_image_id is not None, "Ryuk needs its exact, already-local image ID")
    require(ryuk or not args.abandon_resources, "Named resource cleanup requires an enabled reaper")
    engine = Engine(args.socket, args.image, None, None, api_version=args.api_version)
    scope = "mp-tc-" + uuid4().hex[:24]
    labels = [args.image, *args.preserve_image, *([RYUK] if ryuk else [])]
    report = {"mode": args.mode, "scope": scope, "socket": str(args.socket), "official_client": "testcontainers-go v0.40.0",
              "go_client_sha256": sha_file(args.client), "driver_sha256": sha_file(Path(__file__)),
              "api_version": args.api_version, "ryuk_enabled": ryuk, "abandon_resources": args.abandon_resources,
              "events": [], "passed": False}
    probe = Probe(engine, scope, report, args.abandon_resources)
    with TemporaryDirectory(prefix="testcontainers-config-", dir=args.output.parent) as scratch:
        config = Path(scratch)
        (config / "config.json").write_text('{"auths":{"fixture.invalid":{}}}')
        env = {key: value for key, value in engine.env.items()
               if not key.startswith(("TESTCONTAINERS_", "RYUK_")) and key not in {"DOCKER_CUSTOM_HEADERS", "DOCKER_TLS"}}
        env.update(DOCKER_HOST="unix://" + str(args.socket), DOCKER_CONFIG=str(config),
                   TESTCONTAINERS_RYUK_DISABLED="false" if ryuk else "true")
        if ryuk:
            env.update(TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE="/var/run/docker.sock",
                       TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED="false")
        engine.env = env.copy()
        engine.env.pop("DOCKER_HOST")
        begun = False
        try:
            report["baselines_before"] = {name: checked_image(engine, name) for name in labels}
            if ryuk:
                require(report["baselines_before"][RYUK]["Id"] == args.ryuk_image_id, "Stock Ryuk differs from the admitted image")
                report["reaper_socket_override"] = env["TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE"]
            require(not any(probe.scope_rows().values()), "Run label already exists")
            for name in probe.containers:
                require(probe.request("GET", "/containers/" + quote(name) + "/json")[0] == 404, "A fixture name already exists: " + name)
            for name in probe.networks:
                require(probe.request("GET", "/networks/" + quote(name))[0] == 404, "A fixture network already exists: " + name)
            if args.abandon_resources:
                for name in probe.volumes:
                    require(probe.request("GET", "/volumes/" + quote(name))[0] == 404, "A fixture volume already exists: " + name)
            begun = True
            if args.mode == "name-filters":
                probe.raw_name_filters(args.image)
            elif args.mode == "network-api":
                probe.raw_network_lifecycle(args.image, args.network_connect_status)
            else:
                probe.run_client(args.client, args.image, args.mode, config, env)
            if ryuk:
                probe.automatic_cleanup()
            report["passed"] = True
        except Exception as exc:
            report["error"] = str(exc)
        finally:
            if begun:
                try:
                    before_cleanup = probe.scope_rows()
                    reapers = probe.reapers()
                    overdue = {kind: [row for row in rows if not args.abandon_resources or
                                      (row.get("Labels") or {}).get(SESSION) == probe.session]
                               for kind, rows in before_cleanup.items()}
                    if args.mode not in {"name-filters", "network-api"} and (any(overdue.values()) or reapers):
                        report.update(passed=False, overdue_resource_counts={key: len(value) for key, value in overdue.items()},
                                      overdue_ryuk=len(reapers))
                    probe.recover_scope()
                    report["remaining"] = probe.scope_rows()
                    report["remaining_reapers"] = probe.reapers()
                    report["baselines_after"] = {name: checked_image(engine, name) for name in labels}
                    require(not any(report["remaining"].values()) and not report["remaining_reapers"]
                            and report["baselines_before"] == report["baselines_after"], "Did not verify complete scoped cleanup and base preservation")
                except Exception as exc:
                    report.update(passed=False, cleanup_error=str(exc))
            args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
