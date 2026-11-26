"""Qualify 32 isolated Docker job networks on one disposable Micropod worker."""

import argparse
import ipaddress
import json
import os
import re
import shutil
import time
from collections import Counter
from pathlib import Path

from qualify import LABEL, cli, require, terminal
from sibling_group import CPUS, GROUP_LABEL

SMOKE = "job-network-smoke"
JOBS = 32
ROLES = ("service", "client")
GROUP = "ci-job"
ALIAS = "dependency"
REQUESTS = 2
CGROUP_FIELDS = ("cpuset.cpus.effective", "cpu.max", "visible_cpus", "gomaxprocs", "memory.max", "pids.max")


def stage(folder):
    driver = folder / (SMOKE + "-driver.py")
    shutil.copy2(__file__, driver)
    return {"job_network_smoke": True, "job_network_smoke_driver_sha256": terminal.digest(driver)}


def network_names(owner):
    return [f"{owner}-{index:02}" for index in range(JOBS)]


def commands(owner, work):
    label = f"{LABEL}={owner}"
    return {
        "network": ["network", "create", "--internal", "--driver", "bridge", "--label", label],
        "run": ["run", "-d", "--pull=never", "--label", label, "--label", f"{GROUP_LABEL}={GROUP}",
                "--cpus", "1", "--memory", "128m", "--pids-limit", "64", "-e", "GOMAXPROCS=1",
                "--mount", f"type=bind,src={work / 'probe'},dst=/mpcheck,readonly"],
        "running": ["ps", "-q", "--no-trunc", "--filter", f"label={label}", "--filter", "status=running"],
    }


def inspected(cmd, ids, *prefix):
    rows = json.loads(cmd(*prefix, "inspect", *ids)) if ids else []
    require(len(rows) == len(ids) and {row["Id"] for row in rows} == set(ids), "inspect returned different objects")
    return {row["Id"]: row for row in rows}


def member(row, limits):
    config = row["HostConfig"]
    return {"id": row["Id"], "name": row["Name"].lstrip("/"), "image": row["Image"], "labels": row["Config"]["Labels"],
            "networks": row["NetworkSettings"]["Networks"], "state": row["State"],
            "docker_cpuset": config.get("CpusetCpus") or "", "nano_cpus": config.get("NanoCpus"),
            "cgroup": {name: limits[name] for name in CGROUP_FIELDS}}


def check_http(result, marker):
    proof = result["receipt"]
    require(result["code"] == 0 and proof.get("complete") is True,
            f"HTTP to {marker} failed with exit {result['code']}: {result['stderr'] or proof.get('error', '')}")
    require(proof["url"] == f"http://{ALIAS}:8080/id" and proof["marker"] == marker
            and proof["requested"] == REQUESTS and len(proof["samples"]) == REQUESTS, f"wrong HTTP receipt for {marker}")
    for i, sample in enumerate((proof["warmup"], *proof["samples"])):
        reused = i > 0
        require(not sample.get("error") and sample["got_conn_count"] == 1 and sample["dial_starts"] == int(not reused)
                and sample["reused"] is reused and sample["same_as_warmup"] is reused
                and 0 < sample["got_conn_ns"] <= sample["wrote_request_ns"] <= sample["first_response_byte_ns"] <= sample["total_ns"],
                f"request {i} did not use the verified socket for {marker}")


def check_network_timing(proof, names):
    rows = proof["commands"]
    require([row["name"] for row in rows] == names and len(rows) == JOBS, "network create timings differ from the private network names")
    start, finish = rows[0]["started_ns"], rows[-1]["finished_ns"]
    require(start == proof["started_ns"] and finish == proof["finished_ns"] and 0 < finish - start == proof["total_ns"]
            and all(0 < row["finished_ns"] - row["started_ns"] == row["elapsed_ns"] for row in rows)
            and all(a["finished_ns"] <= b["started_ns"] for a, b in zip(rows, rows[1:]))
            and sum(row["elapsed_ns"] for row in rows) <= proof["total_ns"], "invalid bracket or timing for sequential network creates")


def check_workload(receipt, work, image):
    owner, jobs = receipt["owner"], receipt["jobs"]
    require(receipt["group"] == {"label": GROUP_LABEL, "value": GROUP} and receipt["service_alias"] == ALIAS
            and receipt["commands"] == commands(owner, work), "job network smoke inputs differ")
    names = network_names(owner)
    require([job["network"]["Name"] for job in jobs] == names, "expected 32 named job networks")
    check_network_timing(receipt["network_create_timing"], names)
    networks, subnets, started, assignments = set(), set(), {}, Counter()
    for job in jobs:
        network = job["network"]
        name, network_id = network["Name"], network["Id"]
        require(re.fullmatch(r"[0-9a-f]{64}", network_id) and network_id not in networks and network["Internal"] is True
                and network["Driver"] == "bridge" and network["Scope"] == "local" and network["Labels"].get(LABEL) == owner
                and not (network.get("Options") or {}).get("parent"), f"unexpected private bridge for {name}")
        networks.add(network_id)
        address, = network["IPAM"]["Config"]
        subnet = ipaddress.IPv4Network(address["Subnet"])
        require(subnet.is_private and subnet.prefixlen == 24 and subnet not in subnets, f"unexpected or duplicate subnet for {name}")
        subnets.add(subnet)
        endpoints, addresses, masks = {}, set(), set()
        members = job["members"]
        require(set(members) == set(ROLES), f"missing client or dependency for {name}")
        for role, row in members.items():
            cid, state = row["id"], row["state"]
            require(re.fullmatch(r"[0-9a-f]{64}", cid) and cid not in started and row["name"] == f"{name}-{role}"
                    and row["image"] == image and state["Running"] is True and not state.get("OOMKilled")
                    and state["StartedAt"] and not state["StartedAt"].startswith("0001-"), f"wrong live {role} for {name}")
            started[cid] = state["StartedAt"]
            require(row["labels"].get(LABEL) == owner and row["labels"].get(GROUP_LABEL) == GROUP
                    and set(row["networks"]) == {name}, f"wrong group or network for {row['name']}")
            endpoint = row["networks"][name]
            ip = ipaddress.IPv4Address(endpoint["IPAddress"])
            require(endpoint["NetworkID"] == network_id and ip in subnet and ip not in addresses
                    and (ALIAS in (endpoint.get("Aliases") or []) if role == "service" else ALIAS not in (endpoint.get("Aliases") or [])),
                    f"wrong private endpoint for {row['name']}")
            addresses.add(ip)
            endpoints[cid] = {"Name": row["name"], "IPv4Address": f"{ip}/{subnet.prefixlen}"}
            cgroup, mask = row["cgroup"], row["docker_cpuset"]
            require(mask in CPUS and cgroup["cpuset.cpus.effective"] == mask and cgroup["cpu.max"] == "100000 100000"
                    and row["nano_cpus"] == 1_000_000_000 and cgroup["visible_cpus"] == cgroup["gomaxprocs"] == 1
                    and cgroup["memory.max"] == str(128 << 20) and cgroup["pids.max"] == "64", f"wrong CPU or limits for {row['name']}")
            masks.add(mask)
        require(network["Containers"] == endpoints, f"network membership differs for {name}")
        require(len(masks) == 1, f"dependency and client use different CPUs in {name}")
        assignments.update(masks)
        check_http(job["http"], members["service"]["name"])
    require(assignments == dict.fromkeys(CPUS, JOBS // len(CPUS)), f"job networks did not balance across vCPUs: {assignments}")
    after = receipt["states_after"]
    require(sorted(started) == sorted(receipt["running_before"]) == sorted(receipt["running_after"]) == sorted(after)
            and all(state["Running"] is True and not state.get("OOMKilled") and state["StartedAt"] == started[cid]
                    for cid, state in after.items()), "all 64 containers must remain running with the same start identities")
    return dict(sorted(assignments.items()))


def check_cleanup(receipt):
    cleanup = receipt["cleanup"]
    jobs = receipt["jobs"]
    require(sorted(cleanup["containers_removed"]) == sorted(row["id"] for job in jobs for row in job["members"].values())
            and sorted(cleanup["networks_removed"]) == sorted(job["network"]["Id"] for job in jobs)
            and cleanup["containers_after"] == cleanup["networks_after"] == [], "job network scope cleanup differs")


def qualify(engine, work, folder, parent_owner, image, parallel, guard, *, after_workload=None):
    owner = f"{parent_owner}-{SMOKE}"
    names = network_names(owner)
    container_names = {f"{name}-{role}" for name in names for role in ROLES}
    argv = commands(owner, work)
    filter_owner = ("--filter", f"label={LABEL}={owner}")

    def cmd(*args, **kwargs):
        return cli(engine, *args, **kwargs)

    def containers():
        return cmd("ps", "-aq", "--no-trunc", *filter_owner).splitlines()

    def networks():
        return cmd("network", "ls", "-q", "--no-trunc", *filter_owner).splitlines()

    def create(item):
        name, role = item
        marker = f"{name}-{role}"
        alias = ["--network-alias", ALIAS] if role == "service" else []
        cid = cmd(*argv["run"], "--name", marker, "--network", name, *alias,
                  terminal.SERVICE, "-listen", ":8080", "-marker", marker)
        require(re.fullmatch(r"[0-9a-f]{64}", cid), f"wrong container ID for {marker}")
        return cid

    def retire():
        container_ids = containers()
        rows = inspected(cmd, container_ids)
        require(all(row["Config"]["Labels"].get(LABEL) == owner and row["Name"].lstrip("/") in container_names
                    for row in rows.values()), "ambiguous job network container ownership")
        if container_ids:
            cmd("rm", "-f", *container_ids, timeout=120)
        network_ids = networks()
        known = inspected(cmd, network_ids, "network")
        require(all(row["Labels"].get(LABEL) == owner and row["Name"] in names and not row["Containers"]
                    for row in known.values()), "ambiguous job network ownership or nonempty network")
        if network_ids:
            cmd("network", "rm", *network_ids, timeout=120)
        containers_after, networks_after = containers(), networks()
        require(not containers_after and not networks_after, "job network scope still owns live or stopped objects")
        return {"containers_removed": container_ids, "networks_removed": network_ids,
                "containers_after": containers_after, "networks_after": networks_after}

    require(not containers() and not networks(), "job network smoke owner already exists")
    proof = {"owner": owner, "group": {"label": GROUP_LABEL, "value": GROUP}, "service_alias": ALIAS, "commands": argv,
             "complete": False}
    try:
        net_ids, timings = [], []
        proof["network_create_timing"] = {"commands": timings}
        for name in names:
            start = time.monotonic_ns()
            network_id = cmd(*argv["network"], name)
            finish = time.monotonic_ns()
            net_ids.append(network_id)
            timings.append({"name": name, "started_ns": start, "finished_ns": finish, "elapsed_ns": finish - start})
        proof["network_create_timing"].update(started_ns=timings[0]["started_ns"], finished_ns=finish,
                                              total_ns=finish - timings[0]["started_ns"])
        require(len(set(net_ids)) == JOBS and all(re.fullmatch(r"[0-9a-f]{64}", nid) for nid in net_ids), "wrong new job network IDs")
        guard()
        positions = [(name, role) for name in names for role in ROLES]
        ids = parallel(8, create, positions)
        proof["running_before"] = cmd(*argv["running"]).splitlines()
        require(len(set(ids)) == 2 * JOBS and sorted(proof["running_before"]) == sorted(ids), "all 64 native containers must be running")
        docker_rows = inspected(cmd, ids)
        network_rows = inspected(cmd, net_ids, "network")

        def readback(cid):
            limits = json.loads(cmd("exec", cid, "/mpcheck/netbench", "-cgroup-info"))
            return member(docker_rows[cid], limits)

        members = dict(zip(positions, parallel(8, readback, ids), strict=True))
        jobs = [{"network": network_rows[nid], "members": {role: members[name, role] for role in ROLES}}
                for name, nid in zip(names, net_ids, strict=True)]
        proof["jobs"] = jobs
        guard()

        def request(job):
            pair = job["members"]
            result = terminal.invoke(*engine, "exec", pair["client"]["id"], "/mpcheck/quiet-http", "-url", f"http://{ALIAS}:8080",
                                     "-marker", pair["service"]["name"], "-requests", REQUESTS, timeout=40, check=False)
            try:
                response = json.loads(result.stdout)
            except ValueError:
                response = {"error": result.stdout[-500:]}
            return {"code": result.returncode, "stderr": result.stderr[-500:], "receipt": response}

        for job, result in zip(jobs, parallel(8, request, jobs), strict=True):
            job["http"] = result
        proof["running_after"] = cmd(*argv["running"]).splitlines()
        proof["states_after"] = {cid: row["State"] for cid, row in inspected(cmd, ids).items()}
        proof["groups_per_cpu"] = check_workload(proof, work, image)
        guard()
        if after_workload is not None:
            after_workload(proof)
    except BaseException as error:
        proof["error"] = str(error) or type(error).__name__
        raise
    finally:
        try:
            proof["cleanup"] = retire()
            if "error" not in proof:
                check_cleanup(proof)
                proof["complete"] = True
        except BaseException as error:
            proof["cleanup_error"] = str(error) or type(error).__name__
            raise
        finally:
            terminal.save(folder / (SMOKE + ".json"), proof)


def verify_archived(folder):
    plan = json.loads((folder / "plan.json").read_bytes())
    scope = Path(plan["scope"])
    status = json.loads((folder / "status.json").read_bytes())
    fixture_cleanup = json.loads((folder / "cleanup.json").read_bytes())
    baseline = json.loads((folder / "verification.json").read_bytes())
    require(status["complete"] is True and scope.is_absolute() and not os.path.lexists(scope)
            and fixture_cleanup == {"scope": str(scope), "retained": False, "errors": []}
            and plan["baseline_files"] == 24 and baseline == {"baseline_files": 24, "extra_cleanup_errors": []},
            "enclosing fixture did not complete, clean up, and preserve the baseline")
    require(plan["job_network_smoke"] is True
            and terminal.digest(folder / (SMOKE + "-driver.py")) == plan["job_network_smoke_driver_sha256"]
            and terminal.digest(folder / "quiet-http.go") == plan["quiet_source_sha256"], "job network driver or probe changed")
    proof = json.loads((folder / (SMOKE + ".json")).read_bytes())
    image = json.loads((folder / "images.json").read_bytes())
    require(proof["complete"] is True and proof["owner"] == f"{scope.name}-{SMOKE}"
            and image["inspected"]["A"]["Id"] == "sha256:" + image["expected"]["config"], "incomplete scope or unexpected image")
    groups = check_workload(proof, scope / "workspace", image["inspected"]["A"]["Id"])
    require(proof["groups_per_cpu"] == groups, "archived group counts differ")
    check_cleanup(proof)
    return {"networks": JOBS, "containers": 2 * JOBS, "groups_per_cpu": groups, "warmed_sockets": JOBS,
            "network_create_total_ns": proof["network_create_timing"]["total_ns"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    print(json.dumps(verify_archived(parser.parse_args().folder), indent=2))
