"""Create and verify the internal IPvlan networks used by a timed CI cohort."""
import ipaddress
import json
import re
import shutil
import time

from qualify import LABEL, require, terminal


POOL = ipaddress.IPv4Network("10.231.192.0/23")
PAIRS = 32
MODES = ("shared", "per-job")


def stage(folder, mode):
    target = folder / "sibling-topology.py"
    shutil.copyfile(__file__, target)
    return {"network_topology": mode, "topology_driver_sha256": terminal.digest(target)}


def networks(prefix, mode):
    require(mode in MODES, "unknown timed network topology")
    if mode == "shared":
        return {prefix: POOL}
    return {f"{prefix}-job-{i:02}": subnet for i, subnet in enumerate(POOL.subnets(new_prefix=28))}


def slot_network(prefix, mode, slot):
    return f"{prefix}-job-{slot:02}" if mode == "per-job" else prefix


def inspect(cmd, names):
    rows = json.loads(cmd("network", "inspect", *names))
    require([r["Name"] for r in rows] == list(names), "network inspection returned unexpected names")
    return {row["Name"]: row for row in rows}


def create(cmd, owner, prefix, mode):
    wanted = networks(prefix, mode)
    times = {}
    for name, subnet in wanted.items():
        start = time.monotonic_ns()
        nid = cmd("network", "create", "--driver", "ipvlan", "--internal", "--subnet", str(subnet),
                  "--label", f"{LABEL}={owner}", name)
        times[name] = {"id": nid, "started_ns": start, "finished_ns": time.monotonic_ns()}
    rows = inspect(cmd, wanted)
    for name, row in rows.items():
        require(row["Id"] == times[name]["id"] and not row.get("Containers"), f"unexpected new network {name}")
        check_network(row, name, wanted[name], owner)
    return rows, times


def check_network(row, name, subnet, owner):
    addresses = row["IPAM"]["Config"]
    require(re.fullmatch(r"[a-f0-9]{64}", row["Id"]) and row["Name"] == name and row["Driver"] == "ipvlan"
            and row["Internal"] is True and row["Scope"] == "local" and row["Labels"].get(LABEL) == owner
            and not (row.get("Options") or {}).get("parent") and len(addresses) == 1
            and addresses[0]["Subnet"] == str(subnet), f"wrong internal IPvlan network {name}")


def check_membership(cohort, owner, prefix, mode):
    wanted = networks(prefix, mode)
    attached, created = cohort["attached_networks"], cohort["network_creates"]
    jobs = cohort["jobs"]
    require(attached.keys() == created.keys() == wanted.keys() and len(jobs) == 2 * PAIRS
            and len({r["Id"] for r in attached.values()}) == len(wanted),
            "incomplete or duplicate timed job networks")
    expected = {name: {} for name in wanted}
    previous = 0
    for name, subnet in wanted.items():
        row, event = attached[name], created[name]
        check_network(row, name, subnet, owner)
        require(row["Id"] == event["id"] and previous <= event["started_ns"] < event["finished_ns"],
                f"wrong network creation receipt for {name}")
        previous = event["finished_ns"]
    for index, job in enumerate(jobs):
        name = slot_network(prefix, mode, index % PAIRS)
        subnet = wanted[name]
        row = attached[name]
        links = job["docker_inspect"]["NetworkSettings"]["Networks"]
        ip = ipaddress.IPv4Address(job["ip"])
        require(set(links) == {name} and links[name]["NetworkID"] == row["Id"]
                and links[name]["IPAddress"] == str(ip) and ip in subnet and ip not in (subnet.network_address, subnet.broadcast_address)
                and job["endpoint"]["ipv4"] == [str(ip)] and job["endpoint"]["default_route"] is False,
                f"wrong timed network endpoint for {job['name']}")
        expected[name][job["id"]] = (job["name"], f"{ip}/{subnet.prefixlen}")
    for name, row in attached.items():
        endpoints = {cid: (ep["Name"], ep["IPv4Address"]) for cid, ep in row["Containers"].items()}
        require(endpoints == expected[name], f"unexpected members of timed CI network {name}")
    return attached


def retire(cmd, owner, prefix, mode):
    names = set(networks(prefix, mode))
    selector = ("--filter", f"label={LABEL}={owner}", "--format", "{{.Name}}")
    present = cmd("network", "ls", *selector).splitlines()
    require(set(present) <= names, "ambiguous timed network ownership")
    if present:
        rows = inspect(cmd, present)
        require(all(row["Labels"].get(LABEL) == owner and not row.get("Containers") for row in rows.values()),
                "timed CI network still has endpoints or lost its owner label")
        cmd("network", "rm", *(row["Id"] for row in rows.values()), timeout=120)
    require(not cmd("network", "ls", *selector), "timed CI networks remain")
