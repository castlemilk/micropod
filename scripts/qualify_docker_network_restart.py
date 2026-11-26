#!/usr/bin/env python3
"""Save a labelled Docker bridge fixture and verify it after restarting its owned worker."""

import argparse
import json
from pathlib import Path
import re

from qualify_docker_network_membership import LABEL, Membership, VERSION
from qualify_engine_api import Engine
from qualify_testcontainers_go import checked_image, require


def prepare(probe, state):
    require(not probe.inventory("containers") and not probe.inventory("networks"), "Scope collision")
    for letter, name in probe.nets.items():
        _, identity = probe.cli("network", "create", "--driver", "bridge", "--label", probe.label, name)
        require(re.fullmatch("[a-f0-9]{64}", identity), "Missing owned network ID")
        state["networks"][name] = identity
        role = "peer-" + letter
        probe.create(role, letter)
        probe.cli("start", probe.ids[role])
    probe.create("service", "a", publish=True)
    probe.attach()
    probe.cli("start", probe.ids["service"])
    probe.published()
    state["running_addresses"] = probe.inspect(True)
    probe.traffic()
    probe.cli("exec", probe.ids["service"], "sh", "-ec", 'printf %s "$MARK" > /tmp/owned-restart-sentinel')
    for identity in probe.ids.values():
        probe.cli("stop", "-t", "1", identity)
    state["containers"] = probe.ids
    verify_stopped(probe, state)


def verify_stopped(probe, state):
    require(set(state["containers"]) == set(probe.names) and set(state["networks"]) == set(probe.nets.values())
            and set(probe.inventory("containers")) == set(state["containers"].values())
            and set(probe.inventory("networks")) == set(state["networks"].values()), "Saved resource set differs")
    for role, identity in state["containers"].items():
        require(re.fullmatch("[a-f0-9]{64}", identity), "Invalid owned container ID")
        code, row = probe.api("GET", "/containers/" + identity + "/json")
        require(code == 200 and row["Name"] == "/" + probe.names[role] and row["Config"]["Labels"][LABEL] == probe.scope
                and row["State"]["Status"] == "exited" and not row["State"]["Running"], "Lost stopped " + role)
    for name, identity in state["networks"].items():
        code, row = probe.api("GET", "/networks/" + identity)
        require(code == 200 and row["Name"] == name and row["Labels"][LABEL] == probe.scope,
                "Saved network identity changed")


def verify_restored(probe, state):
    verify_stopped(probe, state)
    probe.ids = state["containers"]
    for role in ("peer-a", "peer-b", "service"):
        probe.cli("start", probe.ids[role])
    _, sentinel = probe.cli("exec", probe.ids["service"], "cat", "/tmp/owned-restart-sentinel")
    require(sentinel == probe.names["service"], "Service writable layer changed across worker restart")
    probe.published()
    addresses = probe.inspect(True)
    require(addresses == state["running_addresses"], "Durable endpoint address reservations changed")
    probe.traffic()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=("prepare", "verify", "cleanup"), required=True)
    parser.add_argument("--socket", required=True, type=Path)
    parser.add_argument("--image", required=True)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    require(args.socket.is_socket() and not args.out.exists(), "Expected a live socket and fresh receipt path")
    engine = Engine(args.socket, args.image, None, None, api_version=VERSION)
    base = checked_image(engine, args.image)
    if args.phase == "prepare":
        require(not args.state.exists(), "Expected a new restart state file")
        probe = Membership(engine, "restart")
        state = {"scope": probe.scope, "image": base, "socket": str(args.socket), "networks": {}, "containers": {}}
        with args.state.open("x") as f:
            json.dump(state, f)
    else:
        state = json.loads(args.state.read_text())
        require(state["socket"] == str(args.socket) and base == state["image"], "Wrong engine socket or image")
        probe = Membership(engine, "restart", state["scope"])
    report = {"phase": args.phase, "scope": probe.scope, "socket": str(args.socket), "history": probe.history}
    try:
        if args.phase == "prepare":
            prepare(probe, state)
            args.state.write_text(json.dumps(state, indent=2) + "\n")
        elif args.phase == "verify":
            verify_restored(probe, state)
        report["passed"] = True
    except Exception as exc:
        report.update(passed=False, error=f"{type(exc).__name__}: {exc}")
    finally:
        if args.phase != "prepare" or not report.get("passed"):
            try:
                report["remaining"] = probe.cleanup()
            except Exception as exc:
                report.update(passed=False, cleanup_error=f"{type(exc).__name__}: {exc}")
        args.out.write_text(json.dumps(report, indent=2) + "\n")
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
