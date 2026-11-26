"""Verify real Go process slices from an untimed compile under the measured launcher."""

from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import shutil

from qualify import fanout, require, terminal
from sibling_group import check_threads


PAIRS, BUILDERS = 32, 8
MODES = ("inherit", "long")
RUNTIME = "/mpcheck/compiler-runtime"
SOURCE = Path(__file__).name
WITNESS = "sibling_compiler_slice_proof.sh"
RECEIPT = "compiler-runtime-tools.json"
SOURCES = {SOURCE: "compiler_runtime_tool_evidence_sha256", WITNESS: "compiler_runtime_tool_witness_sha256"}
ROLES = {"dispatcher", "go", "compile"}
SHA256 = re.compile(r"[a-f0-9]{64}")


def read(folder, name):
    return json.loads((folder / name).read_bytes())


def stage(folder):
    for name in SOURCES:
        shutil.copyfile(Path(__file__).with_name(name), folder / name)
    return {key: terminal.digest(folder / name) for name, key in SOURCES.items()}


def expected_ns(arm, mode):
    require(arm in ("A", "B") and mode in MODES, "unknown compiler runtime arm or mode")
    return 250_000 if arm == "A" and mode == "inherit" else 2_100_000


def launcher(job, arm, mode):
    requested_us = 2100 if arm == "A" and mode == "long" else 0
    return ["exec", job["id"], "nice", "-n", 0, "taskset", "-c", job["home_cpu"], RUNTIME, "-policy", "normal",
            "-build-slice-us", requested_us, "/bin/sh", "-ec"]


def docker_identity(raw):
    (network, endpoint), = raw["NetworkSettings"]["Networks"].items()
    require(raw["State"]["Running"] is True and raw["State"]["StartedAt"] and endpoint["NetworkID"]
            and endpoint["IPAddress"], "compiler proof needs its running Docker network endpoint")
    return {"id": raw["Id"], "name": raw["Name"], "started_at": raw["State"]["StartedAt"],
            "network": network, "network_id": endpoint["NetworkID"], "ip": endpoint["IPAddress"]}


def read_witness(raw, job, boot, runtime, probe_sha256):
    values, files, processes, threads = {}, {}, {}, {}
    for line in raw.splitlines():
        kind, data = line.split(maxsplit=1)
        if kind in ("file", "process", "threads"):
            role, fields = data.split(maxsplit=1)
            section = {"file": files, "process": processes, "threads": threads}[kind]
            require(role not in section, f"duplicate {role} {kind} evidence")
            section[role] = json.loads(fields) if kind == "threads" else fields.split()
        else:
            require(kind not in values, f"duplicate compiler runtime receipt field {kind}")
            values[kind] = data
    require(values.keys() == {"boot", "limits", "cgroup_inode", "link", "object"} and values["boot"] == boot,
            "real compiler was not observed in the expected guest")
    limit = job["cgroup"]
    require(values["limits"] == f"{limit['cpuset.cpus.effective']} {limit['cpu.max']}" == "0-3 100000 100000"
            and re.fullmatch(r"\d+:[1-9]\d*", values["cgroup_inode"]),
            "real compiler was not observed in the measured cgroup")
    link = json.loads(values["link"])
    require(link == job["endpoint"] and link["ipv4"] == [job["ip"]],
            "real compiler was not observed in the measured job network")
    size, object_sha = values["object"].split()
    require(int(size) > 0 and SHA256.fullmatch(object_sha), "the real compiler did not produce its proof object")

    require(files.keys() == ROLES | {"taskset", "compiler-runtime"} and processes.keys() == threads.keys() == ROLES,
            "missing a launcher, Go executable or real process observation")
    identities = {}
    for role, (path, digest) in files.items():
        require(Path(path).is_absolute() and SHA256.fullmatch(digest), f"invalid path or digest for {role}")
        identities[role] = {"path": path, "sha256": digest}
    require(identities["compiler-runtime"] == {"path": RUNTIME, "sha256": probe_sha256},
            "running compiler runtime helper differs from its staged binary")

    pids, parents, memberships, observed_tids = {}, {}, set(), set()
    for role, (pid, ppid, executable, cgroup, netns, cgroupns) in processes.items():
        pids[role], parents[role] = int(pid), int(ppid)
        # The exec supervisor can be outside the container's PID namespace.
        parent_min = 0 if role == "dispatcher" else 1
        require(pids[role] > 0 and parents[role] >= parent_min and executable == identities[role]["path"]
                and re.fullmatch(r"0::/\S*", cgroup) and re.fullmatch(r"net:\[\d+\]", netns)
                and re.fullmatch(r"cgroup:\[\d+\]", cgroupns), f"invalid real {role} process identity")
        memberships.add((cgroup, netns, cgroupns))
        rows = threads[role]
        check_threads(rows, pids[role], job["home_cpu"])
        require(all(all(type(t[key]) is int and t[key] == expected for key, expected in
                        (("policy", 0), ("nice", 0), ("priority", 0), ("slice_ns", runtime)))
                    and type(t["tid"]) is int and t["tid"] not in observed_tids for t in rows),
                f"real {role} threads did not have SCHED_NORMAL, nice 0 and slice {runtime} ns")
        observed_tids.update(t["tid"] for t in rows)
    require(len(set(pids.values())) == 3 and parents["go"] == pids["dispatcher"]
            and parents["compile"] == pids["go"] and len(memberships) == 1,
            "compiler was not a real descendant in the dispatcher's namespaces and cgroup")
    _, network_ns, _ = memberships.pop()
    return identities, network_ns, values["cgroup_inode"]


def verify(folder, plan, inventory, boots):
    for name, key in SOURCES.items():
        require(terminal.digest(folder / name) == plan[key], f"archived compiler runtime proof changed: {name}")
    witness = read(folder, RECEIPT)
    require(set(witness) == {"A", "B"} and boots["A"] != boots["B"], "missing or duplicate compiler runtime guest")
    mode = plan["compiler_runtime"]
    require(mode in MODES and plan["compiler_affinity"] == "home", "runtime proof needs home-pinned compiler jobs")
    tools = None
    for arm in "AB":
        jobs = inventory[arm]["jobs"]
        require(len(jobs) == PAIRS * 2, "missing compiler runtime containers")
        nets, cgroups, ids = set(), set(), set()
        for slot, (job, receipt) in enumerate(zip(jobs[PAIRS:PAIRS + BUILDERS], witness[arm], strict=True)):
            identity = docker_identity(job["docker_inspect"])
            require(job["home_cpu"] == str(slot % 4) and receipt["slot"] == slot and identity["id"] == job["id"]
                    and receipt["container"] == identity and receipt["launcher"] == launcher(job, arm, mode),
                    f"compiler runtime proof belongs to another {arm} job or command")
            files, netns, inode = read_witness(receipt["raw"], job, boots[arm], expected_ns(arm, mode),
                                             plan["compiler_runtime_probe_sha256"])
            if tools is None:
                tools = files
            require(files == tools, "real compiler, dispatcher or launcher identity changed")
            nets.add(netns)
            cgroups.add(inode)
            ids.add(identity["network_id"])
        require(len(nets) == len(cgroups) == len(ids) == BUILDERS, "compiler proof repeated a network or container cgroup")
    return {"executables": tools, "runtime_ns": {arm: expected_ns(arm, mode) for arm in "AB"}}


def qualify(folder, cohorts, mode):
    plan = read(folder, "plan.json")
    require(plan["compiler_runtime"] == mode, "compiler runtime proof mode differs from the plan")
    witness = (folder / WITNESS).read_text()
    records = {}
    for arm, cohort in cohorts.items():
        jobs = cohort.jobs[PAIRS:PAIRS + BUILDERS]
        inspected = json.loads(cohort.cmd("inspect", *(job["id"] for job in jobs), timeout=12))
        require([row["Id"] for row in inspected] == [job["id"] for job in jobs], "compiler proof inspected different jobs")

        def probe(item):
            slot, (job, row) = item
            argv = launcher(job, arm, mode)
            raw = cohort.cmd(*argv, witness, timeout=20)
            return {"slot": slot, "container": docker_identity(row), "launcher": argv, "raw": raw}

        with ThreadPoolExecutor(max_workers=4) as pool:
            records[arm] = list(pool.map(probe, enumerate(zip(jobs, inspected, strict=True))))
    terminal.save(folder / RECEIPT, records)
    boots = {arm: fanout.parse_job(line, 0)["boot"] for arm, line in read(folder, "grouped-prime.json").items()}
    inventory = {arm: {"jobs": cohort.jobs} for arm, cohort in cohorts.items()}
    return verify(folder, plan, inventory, boots)
