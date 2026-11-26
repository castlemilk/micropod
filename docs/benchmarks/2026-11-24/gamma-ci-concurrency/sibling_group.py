"""Qualify automatic CPU placement before measuring sibling jobs."""

import json
import re
import shutil
from collections import Counter
from pathlib import Path

from qualify import LABEL, cli, require, terminal

LAYOUT = "grouped"
GROUP_LABEL = "io.micropod.ci.cpu-group"
CPUS = ("0", "1", "2", "3")
PROBE = "/mpcheck/group-affinity"
TEST_PATTERN = "^TestDockerCPU(Group.*|SetWithinAllocation|QuotaPreservesDefaultsAndExplicitLimits)$"


def stage(folder, probe, product, env):
    source = Path(__file__).with_name("sibling_group_affinity_linux.go")
    archived_source = folder / source.name
    shutil.copy2(source, archived_source)
    binary = probe / Path(PROBE).name
    tests = probe / "group-runner.test"
    runner = product.resolve().parent / "src/guest/runner"
    terminal.invoke("go", "build", "-trimpath", "-buildvcs=false", "-o", binary, source, env=env)
    terminal.invoke("go", "-C", runner, "test", "-c", "-trimpath", "-buildvcs=false", "-o", tests, ".",
                    timeout=240, env={**env, "GOPROXY": "off"})
    driver = folder / "sibling-group.py"
    shutil.copy2(__file__, driver)
    return {"cpu_groups": True, "cpu_group_label": GROUP_LABEL, "group_driver_sha256": terminal.digest(driver),
            "group_affinity_source_sha256": terminal.digest(archived_source), "group_affinity_probe_sha256": terminal.digest(binary),
            "group_runner_test_sha256": terminal.digest(tests)}


def group_name(index):
    return f"job-{index:02}"


def check_threads(threads, leader, mask):
    tids = {task["tid"] for task in threads}
    require(leader > 0 and leader in tids and len(tids) == len(threads)
            and all(task["tid"] > 0 and task["cpus_allowed_list"] == mask for task in threads),
            f"unexpected CPU affinity for PID {leader}, expected {mask}: {threads}")


def service_affinity(cmd, cid, marker, program, mask):
    affinity = json.loads(cmd("exec", cid, PROBE, "-service", marker, "-service-program", program))
    require(affinity["argv"] == [program, "-listen", ":8080", "-marker", marker], "wrong service process")
    check_threads(affinity["threads"], affinity["pid"], mask)
    return affinity


def process_mask(job):
    return job.get("home_cpu", job["mask"])


def assignment(jobs, count, builders):
    require(len(jobs) == count * 2 and len({job["id"] for job in jobs}) == len(jobs), "CPU groups need separate containers")
    groups = {}
    for index, (service, client) in enumerate(zip(jobs[:count], jobs[count:], strict=True)):
        name = group_name(index)
        home = process_mask(service)
        require(service["cpu_group"] == client["cpu_group"] == name and home == process_mask(client) in CPUS,
                f"client and dependency have different CPU placements for {name}")
        groups[name] = home
    group_counts = Counter(groups.values())
    builder_counts = Counter(groups[group_name(i)] for i in range(builders))
    groups_per_cpu = {cpu: group_counts[cpu] for cpu in CPUS}
    builders_per_cpu = {cpu: builder_counts[cpu] for cpu in CPUS}
    require(set(groups_per_cpu.values()) == {count // len(CPUS)}
            and set(builders_per_cpu.values()) == {builders // len(CPUS)},
            f"unbalanced CPU placement: {groups_per_cpu}, builders: {builders_per_cpu}")
    return {"groups": groups, "groups_per_cpu": groups_per_cpu, "builders_per_cpu": builders_per_cpu}


def qualify(engine, work, folder, owner):
    """Exercise the native create and start API on an owned preflight network."""
    network = owner + "-cpu-group-smoke"
    tests_dir = work / "gate/group-runner-tests"
    tests_dir.mkdir(mode=0o777)
    tests_dir.chmod(0o777)
    smoke_group = "smoke-job"
    cases = {}
    names = set()

    def cmd(*args, **kwargs):
        return cli(engine, *args, **kwargs)

    def inspect(cid):
        row, = json.loads(cmd("inspect", cid))
        require(row["Id"] == cid and row["Config"]["Labels"][LABEL] == owner
                and row["Name"].lstrip("/") in names, "wrong CPU group smoke identity")
        return row

    def record(cid, name, group, docker_cpu, effective_cpu, quota):
        row = inspect(cid)
        require(row["Name"] == "/" + name and row["State"]["Running"]
                and row["Config"]["Labels"].get(GROUP_LABEL) == group
                and (row["HostConfig"].get("CpusetCpus") or "") == docker_cpu
                and row["NetworkSettings"]["Networks"][network]["NetworkID"] == net["Id"],
                f"wrong Docker CPU group readback for {name}")
        cgroup = json.loads(cmd("exec", cid, "/mpcheck/netbench", "-cgroup-info"))
        require(cgroup["cpuset.cpus.effective"] == effective_cpu and cgroup["cpu.max"] == quota,
                f"wrong Linux CPU limits for {name}: {cgroup}")
        return {"docker_inspect": row, "cgroup": cgroup,
                "affinity": service_affinity(cmd, cid, name, "/netbench", effective_cpu)}

    def start(case, group, flags, docker_cpu, effective_cpu, quota="100000 100000"):
        name = network + "-" + case
        names.add(name)
        argv = ["run", "-d", "--pull=never", "--name", name, "--network", network, "--label", f"{LABEL}={owner}",
                "--memory", "128m", "--pids-limit", "64", "-e", "GOMAXPROCS=1", "-e", "TMPDIR=/gate/group-runner-tests",
                "--mount", f"type=bind,src={work / 'probe'},dst=/mpcheck,readonly",
                "--mount", f"type=bind,src={work / 'gate'},dst=/gate",
                *(["--label", f"{GROUP_LABEL}={group}"] if group else []), *flags,
                terminal.SERVICE, "-listen", ":8080", "-marker", name]
        cid = cmd(*argv)
        require(re.fullmatch(r"[0-9a-f]{64}", cid), "invalid CPU group smoke ID")
        cases[case] = {"create_argv": argv, **record(cid, name, group, docker_cpu, effective_cpu, quota)}
        return cid

    try:
        cmd("network", "create", "--internal", "--driver", "bridge", "--label", f"{LABEL}={owner}", network)
        net, = json.loads(cmd("network", "inspect", network))
        require(net["Name"] == network and net["Internal"] and net["Driver"] == "bridge"
                and net["Labels"][LABEL] == owner, "wrong CPU group smoke network")
        unlabeled = start("unlabeled", None, ["--cpus", "1"], "", "0-3")
        tests = terminal.invoke(*engine, "exec", unlabeled, "/mpcheck/group-runner.test", "-test.v", "-test.run", TEST_PATTERN,
                                check=False)
        log = tests.stdout.strip()
        test_log = folder / "linux-cpu-group-tests.txt"
        test_log.write_text(log + "\n" + tests.stderr)
        require(tests.returncode == 0 and log.endswith("PASS") and "--- PASS: TestDockerCPUGroup" in log
                and "--- PASS: TestDockerCPUSetWithinAllocation" in log
                and "--- PASS: TestDockerCPUQuotaPreservesDefaultsAndExplicitLimits" in log,
                f"Linux CPU group or compatibility tests failed: {log[-700:]} {tests.stderr[-400:]}")
        anchor = start("anchor", "smoke-anchor", [], "0", "0")
        cid = start("group", smoke_group, [], "1", "1")
        cmd("rm", "-f", anchor)
        start("explicit-cpuset", smoke_group, ["--cpus", "1", "--cpuset-cpus", "1-2"], "1-2", "1-2")
        start("explicit-quota", smoke_group, ["--cpus", "2"], "", "0-3", "200000 100000")
        cmd("stop", "-t", "1", cid)
        stopped = inspect(cid)
        require(not stopped["State"]["Running"] and stopped["HostConfig"]["CpusetCpus"] == "1",
                "stopped group member lost its assignment")
        # CPU 0 is now free. A new member must join the stopped holder on CPU 1.
        start("joined", smoke_group, [], "1", "1")
        cmd("start", cid)
        restarted = record(cid, network + "-group", smoke_group, "1", "1", "100000 100000")
        require(restarted["docker_inspect"]["State"]["StartedAt"] != stopped["State"]["StartedAt"],
                "group holder did not restart")
    finally:
        filter_owner = ("--filter", f"label={LABEL}={owner}")
        owned = cmd("ps", "-aq", "--no-trunc", *filter_owner).splitlines()
        if owned:
            for cid in owned:
                inspect(cid)
            cmd("rm", "-f", *owned)
        require(not cmd("ps", "-aq", *filter_owner), "CPU group smoke containers remain")
        if network in cmd("network", "ls", "--format", "{{.Name}}").splitlines():
            row, = json.loads(cmd("network", "inspect", network))
            require(row["Labels"].get(LABEL) == owner and not row.get("Containers"), "ambiguous CPU group smoke cleanup")
            cmd("network", "rm", network)
        require(network not in cmd("network", "ls", "--format", "{{.Name}}").splitlines(), "CPU group smoke network remains")
    terminal.save(folder / "cpu-group-smoke.json", {"network": net, "cases": cases, "stopped": stopped,
                  "restarted": restarted, "test_log_sha256": terminal.digest(test_log), "removed": True})
