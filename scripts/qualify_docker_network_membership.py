#!/usr/bin/env python3
"""Exercise Docker bridge attachment, DNS and live traffic through an explicit Engine socket."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import http.client
import ipaddress
import json
from pathlib import Path
import re
import threading
import time
from urllib.parse import urlencode
from uuid import uuid4

from qualify_engine_api import Engine
from qualify_testcontainers_go import checked_image, require

LABEL = "io.micropod.qualification.bridge-membership"
VERSION = "1.47"
SERVICE = r"""cat >/tmp/respond <<'END'
#!/bin/sh
cr=$(printf '\r')
while IFS= read -r -t 2 line && [ "$line" != "$cr" ]; do :; done
printf 'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: %s\r\n\r\n%s' "${#MARK}" "$MARK"
END
chmod 700 /tmp/respond
exec nc -lk -p 8080 -e /tmp/respond"""
PORT_53 = r"""set -eu
nc -l -s 0.0.0.0 -p 53 -e /tmp/respond & tcp=$!
nc -u -l -s 0.0.0.0 -p 53 > /tmp/owned-udp-body & udp=$!
trap 'kill "$tcp" "$udp" 2>/dev/null || :; wait "$tcp" "$udp" 2>/dev/null || :' EXIT
for table in tcp udp; do
    i=0
    until awk '$2 == "00000000:0035" {found=1} END {exit !found}' /proc/net/$table; do
        i=$((i+1)); [ "$i" -lt 50 ] || exit 1; sleep .02
    done
done
[ "$(wget -T 2 -t 1 -qO- http://127.0.0.1:53/owned)" = "$MARK" ]
printf %s "$MARK" | nc -u -w 1 127.0.0.1 53 || :
[ "$(cat /tmp/owned-udp-body)" = "$MARK" ]
printf '%s' "$MARK" """


class Membership:
    def __init__(self, engine, when, scope=None):
        self.engine = engine
        self.when = when
        self.scope = scope if scope is not None else "mp-net-" + uuid4().hex[:16]
        require(re.fullmatch(r"mp-net-[0-9a-f]{16}", self.scope), "Invalid qualification scope")
        self.label = LABEL + "=" + self.scope
        self.nets = {letter: self.scope + "-" + letter for letter in ("a", "b")}
        self.names = {role: self.scope + "-" + role for role in ("service", "peer-a", "peer-b")}
        self.ids = {}
        self.history = []

    def cli(self, *args, ok=True, combined=False):
        result = self.engine.cli(*args, timeout=25)
        out = result.stdout.decode(errors="replace").strip()
        err = result.stderr.decode(errors="replace").strip()
        self.history.append({"command": [a if a != SERVICE else "<service script>" for a in args],
                             "rc": result.returncode, "stdout": out[:400], "stderr": err[:600]})
        if ok:
            require(result.returncode == 0, f"docker {' '.join(args[:2])}: {err}")
        return result.returncode, (out + "\n" + err) if combined else out

    def api(self, method, path, body=None):
        code, _, data = self.engine.request(method, path, body=body)
        info = json.loads(data) if data.strip() else None
        self.history.append({"api": method + " " + path, "status": code,
                             "message": (info or {}).get("message") if isinstance(info, dict) else None})
        return code, info

    def inventory(self, kind):
        resource = {"containers": "/containers/json", "networks": "/networks"}[kind]
        query = urlencode({"all": "1", "filters": json.dumps({"label": [self.label]})})
        code, rows = self.api("GET", resource + "?" + query)
        require(code == 200 and isinstance(rows, list), "Cannot enumerate " + kind)
        owned = []
        for row in rows:
            # Some engines accept filters they do not implement. Never remove a
            # resource until its label and one of this run's exact names match.
            if (row.get("Labels") or {}).get(LABEL) != self.scope:
                continue
            names = {row["Name"]} if kind == "networks" else {n.lstrip("/") for n in row["Names"]}
            expected = self.nets.values() if kind == "networks" else self.names.values()
            require(names.intersection(expected), f"Unexpected owned {kind}: {names}")
            require(re.fullmatch("[0-9a-f]{64}", row["Id"]), "Invalid ID in owned inventory")
            owned.append(row["Id"])
        return sorted(owned)

    def create(self, role, letter, publish=False):
        name = self.names[role]
        args = ["create", "--pull=never", "--name", name, "--label", self.label, "--env", "MARK=" + name]
        if self.when == "multi-create" and role == "service":
            args += ["--network", f"name={self.nets[letter]},alias={name}-alias",
                     "--network", f"name={self.nets['b']},alias={self.alias_b()}"]
        else:
            args += ["--network", self.nets[letter], "--network-alias", name + "-alias"]
        if publish:
            args += ["--publish", "127.0.0.1::8080"]
        _, identity = self.cli(*args, "--entrypoint", "/bin/sh", self.engine.image, "-ec", SERVICE)
        require(re.fullmatch("[0-9a-f]{64}", identity), "Create did not return a full ID")
        self.ids[role] = identity

    def alias_b(self):
        return self.names["service"] + "-b-alias"

    def attach(self):
        rc, _ = self.cli("network", "connect", "--alias", self.alias_b(), self.nets["b"], self.ids["service"], ok=False)
        if rc:
            status, info = self.api("POST", "/networks/" + self.nets["b"] + "/connect",
                                    {"Container": self.ids["service"], "EndpointConfig": {"Aliases": [self.alias_b()]}})
            raise RuntimeError(f"docker network connect exited {rc}, API retry returned {status}: {info}")

    def filters(self, both):
        for letter, net in self.nets.items():
            _, listed = self.cli("ps", "--all", "--quiet", "--no-trunc", "--filter", "network=" + net)
            expected = {self.ids["peer-" + letter]}
            if letter == "a" or both:
                expected.add(self.ids["service"])
            require(set(listed.splitlines()) == expected, "Incorrect container network filter for " + net)

    def default_route(self):
        _, routes = self.cli("exec", self.ids["service"], "ip", "-4", "route", "show", "default")
        gateways = re.findall(r"^default via ([\d.]+) dev ", routes, re.M)
        require(len(gateways) == 1, "Expected a single IPv4 default gateway")
        return gateways[0]

    def inspect(self, both):
        service = self.ids["service"]
        code, row = self.api("GET", "/containers/" + service + "/json")
        require(code == 200 and row["Id"] == service, "Cannot inspect owned service")
        nets = row["NetworkSettings"]["Networks"]
        expected = {"a", "b"} if both else {"a"}
        require(set(nets) == {self.nets[letter] for letter in expected}, "Incorrect container attachments")
        addresses = {}
        for letter, net in self.nets.items():
            code, detail = self.api("GET", "/networks/" + net)
            require(code == 200 and detail["Labels"].get(LABEL) == self.scope, "Missing owned network")
            member = (detail.get("Containers") or {}).get(service)
            require((member is not None) == (letter in expected), "Wrong network-inspect membership on " + net)
            if member is not None:
                ep = nets[net]
                address = ipaddress.IPv4Interface(member["IPv4Address"])
                require(address.ip == ipaddress.IPv4Address(ep["IPAddress"]) and
                        ipaddress.IPv4Address(ep["Gateway"]) in address.network and ep["NetworkID"] == detail["Id"],
                        "Incorrect endpoint network, address or gateway")
                alias = self.names["service"] + "-alias" if letter == "a" else self.alias_b()
                require(alias in (ep.get("Aliases") or []), "Container inspection lost " + alias)
                require(member["Name"] == self.names["service"], "Wrong network-inspect container name")
                addresses[letter] = str(address)
        if both:
            require(ipaddress.ip_interface(addresses["a"]).network != ipaddress.ip_interface(addresses["b"]).network,
                    "Both interfaces reported the same subnet")
        self.history.append({"addresses": addresses})
        return addresses

    def published(self, expected=None):
        code, row = self.api("GET", "/containers/" + self.ids["service"] + "/json")
        require(code == 200, "Cannot read published endpoint")
        binding = next(p for p in row["NetworkSettings"]["Ports"]["8080/tcp"] if p["HostIp"] == "127.0.0.1")
        port = int(binding["HostPort"])
        require(expected is None or port == expected, "Live network change moved the published host port")
        last = ""
        for _ in range(18):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=1)
            try:
                conn.request("GET", "/owned")
                response = conn.getresponse()
                body = response.read(1024).decode()
                if response.status == 200 and body == self.names["service"]:
                    self.history.append({"published": port, "body": body})
                    return port
                last = repr((response.status, body))
            except (OSError, http.client.HTTPException) as exc:
                last = str(exc)
            finally:
                conn.close()
            time.sleep(.08)
        raise RuntimeError("Wrong published response: " + last)

    def http(self, source, target, marker):
        _, data = self.cli("exec", self.ids[source], "wget", "-T", "2", "-t", "1", "-qO-",
                           "http://" + target + ":8080/owned")
        require(data == self.names[marker], "Wrong response from " + target)

    def absent(self, source, alias):
        rc, answer = self.cli("exec", self.ids[source], "nslookup", alias, ok=False, combined=True)
        require(rc != 0, "Unexpected DNS answer for " + alias)
        # Distinguish an unavailable applet, resolver or exec path from an
        # actual negative lookup. Each caller has a known reachable peer.
        require(rc == 1 and re.search(r"NXDOMAIN|No answer|can't find|No address", answer, re.I),
                "Unclassified DNS failure")

    def traffic(self):
        pa = self.names["peer-a"] + "-alias"
        pb = self.names["peer-b"] + "-alias"
        self.http("peer-a", self.names["service"] + "-alias", "service")
        self.http("peer-b", self.alias_b(), "service")
        self.http("service", pa, "peer-a")
        self.http("service", pb, "peer-b")
        self.absent("peer-a", self.alias_b())
        self.absent("peer-b", self.names["service"] + "-alias")

    def bridge_isolation(self):
        isolated = True
        for src, dst in (("a", "b"), ("b", "a")):
            peer = self.ids["peer-" + dst]
            code, info = self.api("GET", "/containers/" + peer + "/json")
            require(code == 200, "Missing opposite-network peer")
            ip = ipaddress.IPv4Address(info["NetworkSettings"]["Networks"][self.nets[dst]]["IPAddress"])
            rc, out = self.cli("exec", self.ids["peer-" + src], "wget", "-T", "1", "-t", "1", "-qO-",
                               f"http://{ip}:8080/owned", ok=False)
            require((rc != 0 and not out) or (rc == 0 and out == self.names["peer-" + dst]),
                    "Unrecognized response from the opposite bridge")
            self.history.append({"cross_bridge": src + "->" + dst, "address": str(ip), "reachable": rc == 0})
            isolated &= rc != 0
        return isolated

    def run(self):
        require(not self.inventory("containers") and not self.inventory("networks"), "Scope collision")
        for letter, name in self.nets.items():
            self.cli("network", "create", "--driver", "bridge", "--label", self.label, name)
            self.create("peer-" + letter, letter)
            self.cli("start", self.ids["peer-" + letter])
        self.create("service", "a", publish=True)
        port = gateway = None
        if self.when == "running":
            self.cli("start", self.ids["service"])
            port = self.published()
            gateway = self.default_route()
        if self.when != "multi-create":
            self.attach()
        if self.when != "running":
            self.cli("start", self.ids["service"])
        port = self.published(port)
        self.inspect(True)
        self.traffic()
        isolated = self.bridge_isolation()
        _, body = self.cli("exec", self.ids["service"], "/bin/sh", "-c", PORT_53)
        require(body == self.names["service"], "Application could not serve on wildcard TCP and UDP port 53")
        joined_gateway = self.default_route()
        require(gateway is None or joined_gateway == gateway, "Live join replaced the original default gateway")
        self.filters(True)
        status, data = self.api("POST", "/networks/" + self.nets["b"] + "/connect",
                                {"Container": self.ids["service"], "EndpointConfig": {"Aliases": [self.alias_b()]}})
        require(400 <= status < 500 and isinstance(data, dict) and data.get("message"),
                "Duplicate live connect did not report a Docker client error")
        self.cli("stop", "-t", "1", self.ids["service"])
        self.cli("start", self.ids["service"])
        port = self.published()  # Docker can reassign an ephemeral host port at start.
        old_ip = str(ipaddress.ip_interface(self.inspect(True)["b"]).ip)
        self.traffic()
        self.cli("network", "disconnect", self.nets["b"], self.ids["service"])
        self.inspect(False)
        self.published(port)
        require(self.default_route() == joined_gateway, "Disconnect replaced the primary default gateway")
        self.http("peer-a", self.names["service"] + "-alias", "service")
        self.absent("peer-b", self.alias_b())
        self.absent("service", self.names["peer-b"] + "-alias")
        rc, data = self.cli("exec", self.ids["peer-b"], "wget", "-T", "2", "-t", "1", "-qO-",
                            "http://" + old_ip + ":8080/owned", ok=False)
        require(rc != 0 and not data, "Detached IP still served HTTP")
        self.filters(False)
        self.cli("stop", "-t", "1", self.ids["service"])
        self.cli("start", self.ids["service"])
        self.inspect(False)
        port = self.published()
        self.absent("peer-b", self.alias_b())
        self.attach()
        self.inspect(True)
        self.traffic()
        self.published(port)
        return isolated

    def cleanup(self):
        errors = []
        for kind in ("containers", "networks"):
            for identity in self.inventory(kind):
                path = "/" + kind + "/" + identity + ("?force=1" if kind == "containers" else "")
                status, data = self.api("DELETE", path)
                if status not in (204, 404):
                    errors.append((identity, status, data))
        remaining = {kind: self.inventory(kind) for kind in ("containers", "networks")}
        require(not errors and not any(remaining.values()), f"Scoped cleanup: {errors}, {remaining}")
        return remaining


def burst(values, operation):
    gate = threading.Barrier(len(values) + 1)

    def run(value):
        gate.wait(timeout=10)
        return operation(value)

    with ThreadPoolExecutor(max_workers=len(values)) as pool:
        calls = [pool.submit(run, value) for value in values]
        gate.wait(timeout=10)
        return [call.result() for call in calls]


class ConcurrentMembership(Membership):
    def run(self):
        jobs = [f"job-{slot}" for slot in range(8)]
        self.names = {role: self.scope + "-" + role for role in [*jobs, "observer"]}
        require(not self.inventory("containers") and not self.inventory("networks"), "Scope collision")
        for net in self.nets.values():
            self.cli("network", "create", "--driver", "bridge", "--label", self.label, net)

        def start(role):
            self.create(role, "b" if role == "observer" else "a")
            self.cli("start", self.ids[role])

        start("observer")
        burst(jobs, start)
        require(set(self.inventory("containers")) == set(self.ids.values()), "Incomplete labelled test cohort")
        route = "/networks/" + self.nets["b"] + "/connect"

        def join(role):
            return self.api("POST", route, {"Container": self.ids[role],
                            "EndpointConfig": {"Aliases": [self.names[role] + "-secondary"]}})[0]

        distinct = burst(jobs[:-1], join)
        competing = sorted(burst([jobs[-1]] * 8, join))
        self.history.append({"distinct_attach_status": distinct, "contended_attach_status": competing})
        require(distinct == [200] * 7 and competing == [200] + [403] * 7,
                "Unexpected concurrent attach results")
        code, net = self.api("GET", "/networks/" + self.nets["b"])
        members = net.get("Containers") or {}
        require(code == 200 and set(members) == set(self.ids.values()), "Missing or extra live members")
        ips = [str(ipaddress.ip_interface(row["IPv4Address"]).ip) for row in members.values()]
        require(len(set(ips)) == len(ips), "Concurrent endpoints allocated the same address")
        self.history.append({"member_addresses": dict(zip(members, ips))})
        burst(jobs, lambda role: self.http("observer", self.names[role] + "-secondary", role))

        def retire(role):
            if role in jobs[:4]:
                code, _ = self.api("POST", "/networks/" + self.nets["b"] + "/disconnect",
                                   {"Container": self.ids[role], "Force": False})
                require(code == 200, "Concurrent disconnect failed")
            else:
                self.cli("rm", "--force", self.ids[role])

        burst(jobs, retire)
        code, net = self.api("GET", "/networks/" + self.nets["b"])
        require(code == 200 and set(net.get("Containers") or {}) == {self.ids["observer"]},
                "Leaked members after mixed disconnect/remove")
        burst(jobs, lambda role: self.absent("observer", self.names[role] + "-secondary"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--require-bridge-isolation", action="store_true",
                        help="Require direct traffic between single-network peers to be blocked")
    parser.add_argument("--concurrent-only", action="store_true",
                        help="Exercise eight racing live attachments and mixed teardown")
    args = parser.parse_args()
    require(args.socket.is_socket() and not args.out.exists(), "Expected local socket and fresh receipt path")
    engine = Engine(args.socket, args.image, None, None, api_version=VERSION)
    report = {"socket": str(args.socket), "api": VERSION, "image": checked_image(engine, args.image), "cases": {}}
    cases = ("eight-concurrent",) if args.concurrent_only else ("created", "running", "multi-create")
    for when in cases:
        probe = ConcurrentMembership(engine, when) if args.concurrent_only else Membership(engine, when)
        case = report["cases"][when] = {"scope": probe.scope, "history": probe.history}
        try:
            isolated = probe.run()
            if isolated is not None:
                case["direct_cross_bridge_blocked"] = isolated
                require(not args.require_bridge_isolation or isolated,
                        "An unjoined peer reached an application on the other bridge directly")
            case["passed"] = True
        except Exception as exc:
            case.update(passed=False, error=f"{type(exc).__name__}: {exc}")
        finally:
            try:
                case["remaining"] = probe.cleanup()
            except Exception as exc:
                case.update(passed=False, cleanup_error=f"{type(exc).__name__}: {exc}")
            args.out.write_text(json.dumps(report, indent=2) + "\n")
    require(report["image"] == checked_image(engine, args.image), "Base image identity changed")
    return 0 if all(case["passed"] for case in report["cases"].values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
