"""Observe live payload membership before and after the paced job-parent crossover."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager, nullcontext
from hashlib import sha256
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import time

import sibling_cgroup_hierarchy as hierarchy
import sibling_compiler_affinity_evidence as affinity
import sibling_group
import sibling_tmpfs
from qualify import IMAGE, LABEL as OWNER_LABEL, ROOT, fanout, require, terminal


COUNT, BUILDERS = 32, 8
LABEL = "io.micropod.bench.ci.job-cgroup"
PROBE = "/mpcheck/job-parent-probe"
GUEST = "sibling_job_parent_linux.go"
BASE = "sibling-job-parent-base.go"
BOOT_HOOK = "job-parent-boot.sh"
COMPILER = "job-parent-compiler.sh"
DATA, TRIGGER = "job-parent-data", "job-parent-trigger"
TESTS = ("TestDockerJobParentSelection", "TestDockerJobParentOCISpec", "TestDockerJobParentRetiresAfterLastLease")
TEST_LOG = "linux-docker-job-parent-tests.txt"
PROBES = "job-parent-probes.json"
SOURCES = {
    "sibling-job-parent.py": "job_parent_driver_sha256",
    "sibling-job-parent-evidence.py": "job_parent_evidence_sha256",
    GUEST: "job_parent_guest_sha256", BASE: "job_parent_base_sha256",
    BOOT_HOOK: "job_parent_boot_hook_sha256", COMPILER: "job_parent_compiler_hook_sha256",
}

BOOT = r'''
(
    set -eu
    workspace="$MICROPOD_ENGINE_WORKSPACE"
    control=/run/job-parent-observer
    mkdir -m 0700 "$control"
    mkfifo -m 0600 "$control/command"
    mount --bind "$control" "$workspace/job-parent-trigger"
    unmount() {
        attempts=0
        until umount "$workspace/job-parent-trigger"; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 40 ] || return 1
            sleep .05
        done
    }
    trap unmount EXIT
    printf ready > "$workspace/job-parent-data/ready"
    for phase in before after; do
        IFS= read -r requested < "$control/command"
        [ "$requested" = "$phase" ]
        output="$workspace/job-parent-data/$phase"
        # The host publishes the request after the disposable trigger retires.
        tries=0
        until [ -f "$output-request.json" ]; do
            tries=$((tries + 1))
            [ "$tries" -lt 240 ] || exit 75
            sleep .05
        done
        result=0
        "$workspace/probe/job-parent-probe" worker "$output-request.json" > "$output.tmp" || result=$?
        mv "$output.tmp" "$output-tree.json"
        printf '%s\n' "$result" > "$output-status.tmp"
        mv "$output-status.tmp" "$output-status"
        [ "$result" = 0 ] || exit "$result"
    done
    # The parent starts polling only after the final, post-work observation.
    retirement="$workspace/job-parent-data/retire"
    tries=0
    until [ -f "$retirement-request.json" ]; do
        tries=$((tries + 1))
        [ "$tries" -lt 300 ] || exit 75
        sleep .2
    done
    "$workspace/probe/job-parent-probe" absent "$retirement-request.json" > "$retirement.tmp"
    mv "$retirement.tmp" "$retirement.json"
    unmount
    trap - EXIT
    rm "$control/command"
    rmdir "$control"
    printf 'unmounted\n' > "$retirement-status.tmp"
    mv "$retirement-status.tmp" "$retirement-status"
) </dev/null >"$MICROPOD_ENGINE_WORKSPACE/job-parent-data/observer.log" 2>&1 &
'''


def read(folder, name):
    return json.loads((folder / name).read_bytes())


def boots(folder):
    return {arm: fanout.parse_job(line, 0)["boot"] for arm, line in read(folder, "grouped-prime.json").items()}


def stage(oci, work, folder):
    here = Path(__file__).parent
    for name in (DATA, TRIGGER):
        (work / name).mkdir(mode=0o700)
    shutil.copyfile(__file__, folder / "sibling-job-parent-evidence.py")
    shutil.copyfile(here / GUEST, folder / GUEST)
    previous = (here / hierarchy.SOURCE).read_text()
    require(previous.count("func main() {") == 1, "unknown cgroup hierarchy base source")
    (folder / BASE).write_text(previous.replace("func main() {", "func legacyMain() {"))
    anchor = 'report_process compile "$compile_pid" "$compile_path"\n'
    previous = (here / affinity.PROOF).read_text()
    require(previous.count(anchor) == 1, "unknown real compiler proof source")
    compiler = previous.replace(anchor, anchor + PROBE + ' wait "$2" "$3"\n')
    (folder / COMPILER).write_text(compiler)
    (work / "probe" / COMPILER).write_text(compiler)
    (folder / BOOT_HOOK).write_text(BOOT)
    with (oci / "runner/fixture-facts.sh").open("a") as hook:
        hook.write(BOOT)
    binary = work / "probe" / Path(PROBE).name
    env = {**os.environ, "GOARCH": "arm64", "GOOS": "linux", "CGO_ENABLED": "0", "GOPROXY": "off"}
    terminal.invoke("go", "-C", ROOT / "guest/runner", "build", "-trimpath", "-buildvcs=false", "-o", binary,
                    folder / BASE, folder / GUEST, env=env, timeout=120)
    return {**{key: terminal.digest(folder / name) for name, key in SOURCES.items() if name != "sibling-job-parent.py"},
            "job_parent_probe_sha256": terminal.digest(binary)}


def http_command(jobs, slot, tag):
    server, client = jobs[slot], jobs[COUNT + slot]
    return ["exec", client["id"], "/mpcheck/quiet-http",
            "-url", "http://" + server["ip"] + ":8080", "-marker", server["name"], "-requests", "1",
            "-ready-file", f"/gate/{tag}-http-{slot}", "-start-file", f"/gate/{tag}-start"]


def compiler_command(jobs, slot, tag):
    job = jobs[COUNT + slot]
    return ["exec", job["id"], "/bin/sh", "/mpcheck/" + COMPILER, job["mask"],
            f"/gate/{tag}-go-{slot}", f"/gate/{tag}-release"]


@contextmanager
def working_children(cohort):
    tag = "job-parent-" + cohort.arm.lower()
    commands = [http_command(cohort.jobs, i, tag) for i in range(COUNT)]
    commands += [compiler_command(cohort.jobs, i, tag) for i in range(BUILDERS)]
    gate = cohort.work / "gate"
    ready = [(gate / f"{tag}-{kind}-{i}") for kind, slots in (("http", COUNT), ("go", BUILDERS)) for i in range(slots)]
    proof = []
    with ThreadPoolExecutor(max_workers=len(commands)) as pool:
        pending = [pool.submit(cohort.cmd, *argv, timeout=85) for argv in commands]
        try:
            deadline = time.monotonic() + 16
            while not all(path.is_file() and path.stat().st_size for path in ready):
                for future in pending:
                    if future.done():
                        future.result()
                        raise ValueError("structural workload exited before inspection")
                require(time.monotonic() < deadline, "structural workload did not become ready")
                time.sleep(.03)
            yield proof
        finally:
            # Release the Go FIFO and HTTP gate even if a readback above failed.
            (gate / f"{tag}-release").touch()
            stamps = [int(path.read_text()) for path in ready[:COUNT] if path.is_file() and path.stat().st_size]
            start = max([time.time_ns(), *stamps]) + 80_000_000
            temp = gate / f"{tag}-start.tmp"
            temp.write_text(str(start))
            temp.replace(gate / f"{tag}-start")
        for slot, (argv, result) in enumerate(zip(commands, pending, strict=True)):
            proof.append({"slot": slot % COUNT, "role": "http" if slot < COUNT else "compiler",
                          "argv": argv, "stdout": result.result()})


def worker_snapshot(folder, cohort, phase, inside):
    work = cohort.work
    directory = work / DATA
    require((directory / "ready").is_file(), "guest-root cgroup observer was not started")
    request = [{"id": row["id"], "leaf": row["inside"]["leaf"]} for row in inside]
    pending = directory / f"{phase}-request.pending"
    terminal.save(pending, request)
    name = f"{cohort.owner}-job-parent-{phase}"
    selector = ("ps", "-aq", "--no-trunc", "--filter", f"name={name}", "--filter",
                f"label={OWNER_LABEL}={cohort.owner}")
    require(not cohort.cmd(*selector), "parent proof trigger name is already in use")
    try:
        cohort.cmd("run", "--rm", "--pull=never", "--name", name, "--network", "none",
                   "--label", f"{OWNER_LABEL}={cohort.owner}", "--memory", "64m", "--pids-limit", "16",
                   "--mount", f"type=bind,src={work / TRIGGER},dst=/parent-control", "--entrypoint", "/bin/sh",
                   IMAGE, "-ec", 'printf "%s\\n" "$1" > /parent-control/command', "trigger", phase, timeout=12)
    finally:
        remaining = cohort.cmd(*selector).splitlines()
        if remaining:
            require(len(remaining) == 1, "ambiguous parent proof trigger cleanup")
            cid = remaining[0]
            row, = json.loads(cohort.cmd("inspect", cid, timeout=10))
            require(row["Id"] == cid and row["Name"] == "/" + name
                    and row["Config"]["Labels"].get(OWNER_LABEL) == cohort.owner,
                    "parent proof trigger changed owner before cleanup")
            cohort.cmd("rm", "-f", cid, timeout=10)
        require(not cohort.cmd(*selector), "parent proof trigger remains active")
    pending.replace(directory / f"{phase}-request.json")
    status = directory / f"{phase}-status"
    deadline = time.monotonic() + 12
    while not status.exists() and time.monotonic() < deadline:
        time.sleep(.025)
    log = directory / "observer.log"
    if log.exists():
        shutil.copyfile(log, folder / "job-parent-observer.log")
    require(status.exists() and status.read_text().strip() == "0", f"guest-root parent observation failed in {phase}")
    return read(directory, f"{phase}-tree.json")


def inside_state(cohort):
    def observe(job):
        raw = cohort.cmd("exec", job["id"], PROBE, "inside", job["affinity"]["pid"], timeout=12)
        return {"id": job["id"], "inside": json.loads(raw)}

    with ThreadPoolExecutor(max_workers=8) as pool:
        return list(pool.map(observe, cohort.jobs))


def capture(folder, cohorts, phase):
    require(phase in ("before", "after"), "unknown job-parent phase")
    if phase == "before":
        native = cohorts["A"]
        output = native.cmd("exec", native.jobs[COUNT]["id"], "/mpcheck/group-runner.test", "-test.v", "-test.run",
                            "^TestDockerJobParent", timeout=20)
        (folder / TEST_LOG).write_text(output + "\n")
        sibling_tmpfs.check_linux_tests(output, TESTS)
    started = time.time_ns()
    results, probes = {}, {}
    for arm, cohort in cohorts.items():
        with working_children(cohort) if phase == "before" else nullcontext([]) as proof:
            inside = inside_state(cohort)
            tree = worker_snapshot(folder, cohort, phase, inside) if arm == "A" else None
        inspected = json.loads(cohort.cmd("inspect", *(job["id"] for job in cohort.jobs), timeout=16))
        results[arm] = {"containers": inside, "worker": tree,
                        "starts": [{k: row[k] for k in ("Id", "Name")} |
                                   {k: row["State"][k] for k in ("StartedAt", "Running")} for row in inspected]}
        probes[arm] = proof
    saved = {"phase": phase, "host_started_unix_ns": started, "host_finished_unix_ns": time.time_ns(), "arms": results}
    terminal.save(folder / f"job-parent-{phase}.json", saved)
    if phase == "before":
        terminal.save(folder / PROBES, probes)
        plan = read(folder, "plan.json")
        inventory = read(folder, "grouped-inventory.json")
        check_probes(plan, inventory, boots(folder), saved, probes)
        check_phase(plan, inventory, boots(folder), saved)


def expected_parent(job, mode):
    if mode == "flat":
        return "/k8s.io"
    endpoint, = job["docker_inspect"]["NetworkSettings"]["Networks"].values()
    network = endpoint["NetworkID"]
    require(re.fullmatch(r"[a-f0-9]{64}", network), "invalid native job network identity")
    digest = sha256(network.encode("ascii") + b"\0" + job["cpu_group"].encode("utf-8")).hexdigest()
    return "/k8s.io/micropod-job-" + digest


def stable_member(row):
    return tuple(row[key] for key in ("local_pid", "birth_ticks", "pid_namespace", "cpus_allowed_list",
                                      "policy", "nice", "priority", "slice_ns")) + (tuple(row["argv"]),)


def ids(raw):
    pids = [int(value) for value in raw.split()]
    require(all(pid > 0 for pid in pids) and len(set(pids)) == len(pids), "invalid cgroup PID list")
    return set(pids)


def resident(job, state, boot, arm, before):
    leaf, members = state["leaf"], state["members"]
    local = leaf["resident"]
    expected = job["affinity"]
    require(leaf["boot"] == boot and leaf["inode"] > 0 and state["guest_unix_ns"] > 0 and
            local["pid"] == expected["pid"] and local["argv"] == expected["argv"] and local["cgroup"] == "0::/",
            "container resident was not in the measured leaf")
    files = state["files"]
    require(files["cpu.weight"] == "100" and all(files[key] == job["cgroup"][key] for key in
            ("cpu.max", "cpuset.cpus.effective", "memory.max", "pids.max")), "container leaf controls differ")
    pids = {row["pid"] for row in members}
    require(type(state["probe_pid"]) is int and state["probe_pid"] > 0 and state["probe_pid"] not in pids
            and pids == ids(state["cgroup.procs"]) - {state["probe_pid"]} and state["probe_pid"] in ids(state["cgroup.procs"])
            and len(pids) == len(members), "incomplete in-container process membership")
    active, = [row for row in members if row["pid"] == local["pid"]]
    require(all(active[key] == local[key] for key in ("pid", "birth_ticks", "pid_namespace", "argv", "cgroup"))
            and (before or pids == {local["pid"]}), "the resident changed or qualification children remained alive")
    slice_ns = {"A": 250_000, "B": 2_100_000}[arm]
    require(all(row["pid"] == row["local_pid"] and row["pid_namespace"] == local["pid_namespace"]
                and row["cgroup"] == "0::/" and row["cpus_allowed_list"] == job["mask"]
                and row["policy"] == row["nice"] == row["priority"] == 0 and row["slice_ns"] == slice_ns
                for row in members), "workload process mask, ordinary policy or inherited base slice changed")
    return active


def check_phase(plan, inventory, guest_boots, snapshot):
    phase = snapshot["phase"]
    require(phase in ("before", "after") and 0 < snapshot["host_started_unix_ns"] <= snapshot["host_finished_unix_ns"]
            and snapshot["arms"].keys() == inventory.keys() == {"A", "B"}, "invalid job-parent phase receipt")
    before = phase == "before"
    owner = Path(plan["scope"]).name
    for arm, state in snapshot["arms"].items():
        jobs = inventory[arm]["jobs"]
        require(len(jobs) == len({j["id"] for j in jobs}) == 2 * COUNT, "missing cohort containers")
        require(state["starts"] == [{"Id": j["id"], "Name": "/" + j["name"], "Running": True,
                                    "StartedAt": j["docker_inspect"]["State"]["StartedAt"]} for j in jobs],
                f"{arm} workload generation changed during inspection")
        inodes, namespaces = set(), set()
        for slot, (job, row) in enumerate(zip(jobs, state["containers"], strict=True)):
            labels = job["docker_inspect"]["Config"]["Labels"]
            wanted = arm == "A" and plan["job_parent"] == "job"
            option = LABEL + "=1"
            argv = job["create_argv"]
            require(row["id"] == job["id"] and labels[OWNER_LABEL] == owner and
                    job["cpu_group"] == labels[sibling_group.GROUP_LABEL] == sibling_group.group_name(slot % COUNT)
                    and job["mask"] == str(slot % COUNT % 4)
                    and (labels.get(LABEL) == "1" if wanted else LABEL not in labels)
                    and argv.count(option) == int(wanted)
                    and all(not arg.startswith(LABEL + "=") or arg == option for arg in argv),
                    f"{arm} workload ownership or job-parent selection differs")
            if wanted:
                require(argv[argv.index(option) - 1] == "--label", "job-parent option was not an explicit Docker label")
            observed = resident(job, row["inside"], guest_boots[arm], arm, before)
            inodes.add(row["inside"]["leaf"]["inode"])
            namespaces.add(observed["pid_namespace"])
        require(len(inodes) == len(namespaces) == 2 * COUNT, "workload containers share a leaf or PID namespace")
        if arm == "B":
            require(state["worker"] is None, "peer unexpectedly used the native root observer")

    native = snapshot["arms"]["A"]
    tree = native["worker"]
    jobs = inventory["A"]["jobs"]
    requests = [{"id": row["id"], "leaf": row["inside"]["leaf"]} for row in native["containers"]]
    hierarchy.check_topology(inventory["A"], requests, tree, guest_boots["A"])
    require(tree["nodes"].keys() == tree["groups"].keys() and
            tree["members"].keys() == tree["memberships"].keys(), "incomplete worker membership or parent nodes")
    paths, parents, native_pids = {}, {}, set()
    for job, proof in zip(jobs, native["containers"], strict=True):
        cid = job["id"]
        loc = tree["memberships"][cid]
        path = PurePosixPath(loc["path"])
        ancestry = str(path.parent)
        require(ancestry == expected_parent(job, plan["job_parent"]) and re.fullmatch(r"[a-f0-9]{64}", path.name),
                f"effective native parent differs for {job['name']}")
        paths[cid] = str(path)
        parents.setdefault(ancestry, []).append(path.name)
        node, group = tree["nodes"][str(path)], tree["groups"][str(path)]
        members = tree["members"][cid]
        worker = {row["local_pid"]: row for row in members}
        local = {row["pid"]: row for row in proof["inside"]["members"]}
        leaf_pids = {row["pid"] for row in members}
        require(len(leaf_pids) == len(worker) == len(members) and not leaf_pids & native_pids
                and leaf_pids == ids(node["cgroup.procs"]) <= ids(node["cgroup.threads"])
                and not node["children"] and worker.keys() == local.keys()
                and all(row["cgroup"] == "0::" + str(path) and stable_member(row) == stable_member(local[pid])
                        for pid, row in worker.items())
                and group["files"]["cpu.weight"] == "100" and group["files"]["cpu.max"] == "100000 100000",
                f"native leaf membership or CPU resources differ for {job['name']}")
        native_pids.update(leaf_pids)
        for pid, row in worker.items():
            parent = local[pid]["parent_pid"]
            if parent in worker:
                require(row["parent_pid"] == worker[parent]["pid"], "native fork relationship changed across namespaces")
    require(len(set(paths.values())) == 2 * COUNT and len(parents) == (COUNT if plan["job_parent"] == "job" else 1),
            "native mode did not produce the expected number of separate parents")
    require({"cpu", "cpuset"} <= set(tree["groups"]["/k8s.io"]["files"]["cgroup.subtree_control"].split()),
            "worker root did not enable cpu and cpuset controllers")
    for path, leaves in parents.items():
        if plan["job_parent"] == "flat":
            continue
        node, group = tree["nodes"][path], tree["groups"][path]
        files = group["files"]
        enabled = set(files["cgroup.subtree_control"].split())
        require(len(leaves) == group["children"] == 2 and set(leaves) == set(node["children"])
                and not node["cgroup.procs"] and not node["cgroup.threads"]
                and {"cpu", "cpuset"} <= enabled <= set(files["cgroup.controllers"].split())
                and files["cgroup.type"] == "domain" and files["cpu.weight"] == "100"
                and files["cpu.max"] == "max 100000" and files["cpuset.cpus.effective"] == "0-3"
                and "populated 1" in files["cgroup.events"].splitlines(),
                f"incomplete or constrained native job parent {path}")
    return {"native_paths": paths, "native_parents": sorted(parents), "native_process_count": len(native_pids)}


def check_probes(plan, inventory, guest_boots, before, probes):
    require(before["phase"] == "before" and probes.keys() == {"A", "B"}, "missing structural children")
    executables = None
    for arm, runs in probes.items():
        jobs = inventory[arm]["jobs"]
        containers = before["arms"][arm]["containers"]
        tag = "job-parent-" + arm.lower()
        http, compilers = runs[:COUNT], runs[COUNT:]
        require(len(http) == COUNT and len(compilers) == BUILDERS, "missing real HTTP or Go processes")
        for slot, row in enumerate(http):
            server = jobs[slot]
            argv = http_command(jobs, slot, tag)
            payload = json.loads(row["stdout"])
            call, = payload["samples"]
            require(row["role"] == "http" and row["slot"] == slot and row["argv"] == argv
                    and payload["complete"] is True and payload["requested"] == 1
                    and payload["url"] == f"http://{server['ip']}:8080/id" and payload["marker"] == server["name"]
                    and call["same_as_warmup"] is True and call["reused"] is True and call["dial_starts"] == 0
                    and not call.get("error") and not payload["window"].get("error"),
                    f"{arm} structural HTTP process did not complete its warmed request")
            members = containers[COUNT + slot]["inside"]["members"]
            require(sum(proc["argv"] == argv[2:] for proc in members) == 1,
                    f"{arm} real HTTP issuer did not appear in its measured leaf")
            expected = 6 if slot < BUILDERS else 2
            require(len(members) == expected, f"{arm} client slot {slot} has unexpected structural processes")
        for slot, row in enumerate(compilers):
            job = jobs[COUNT + slot]
            argv = compiler_command(jobs, slot, tag)
            require(row["role"] == "compiler" and row["slot"] == slot and row["argv"] == argv,
                    "real compiler proof command differs")
            files = affinity.read_tool_proof(row["stdout"], guest_boots[arm], job["mask"])
            if executables is None:
                executables = files
            require(files == executables, "structural compiler binary identities differed")
            members = containers[COUNT + slot]["inside"]["members"]
            shell, = [proc for proc in members if proc["argv"] == argv[2:]]
            parked, = [proc for proc in members if proc["argv"] == [PROBE, "wait", *argv[-2:]]]
            require(parked["parent_pid"] == shell["pid"], "compiler wait helper has the wrong parent")
            by_pid = {member["pid"]: member for member in members}
            for line in row["stdout"].splitlines():
                if not line.startswith("process "):
                    continue
                _, role, pid, ppid, _, executable = line.split()
                observed = by_pid[int(pid)]
                require(observed["parent_pid"] == int(ppid) and observed["executable"] == executable
                        and (role != "go" or observed["parent_pid"] == shell["pid"]),
                        "actual Go compiler process absent from the kernel membership snapshot")
        require(all(len(r["inside"]["members"]) == 1 for r in containers[:COUNT]),
                "dependency leaves contained unplanned processes")
    return executables


def retired_paths(snapshot, mode):
    paths = {row["path"] for row in snapshot["arms"]["A"]["worker"]["memberships"].values()}
    if mode == "job":
        paths.update(str(PurePosixPath(path).parent) for path in tuple(paths))
    return sorted(paths)


def retire(folder, cohort):
    plan = read(folder, "plan.json")
    after = read(folder, "job-parent-after.json")
    directory = cohort.work / DATA
    terminal.save(directory / "retire-request.json", retired_paths(after, plan["job_parent"]))
    status = directory / "retire-status"
    deadline = time.monotonic() + 25
    while not status.is_file() and time.monotonic() < deadline:
        time.sleep(.05)
    shutil.copyfile(directory / "observer.log", folder / "job-parent-observer.log")
    require(status.is_file() and status.read_text() == "unmounted\n", "guest parent observer did not retire and unmount")
    terminal.save(folder / "job-parent-retired.json",
                  {"status": status.read_text().strip(), "worker": read(directory, "retire.json")})


def verify(folder, plan, inventories, guest_boots, *, require_retired=True):
    require(plan["job_parent"] in ("flat", "job") and plan["worker_scheduler"] == "hrtick-250us"
            and plan["worker_next_buddy"] is True and "guest_fair" not in plan,
            "unexpected job-parent boot or scheduler settings")
    require(all(terminal.digest(folder / name) == plan[key] for name, key in SOURCES.items())
            and re.fullmatch(r"[a-f0-9]{64}", plan["job_parent_probe_sha256"]), "parent evidence source differs")
    sibling_tmpfs.check_linux_tests((folder / TEST_LOG).read_text(), TESTS)
    before, after = (read(folder, f"job-parent-{phase}.json") for phase in ("before", "after"))
    require(before["phase"] == "before" and after["phase"] == "after"
            and before["host_finished_unix_ns"] < after["host_started_unix_ns"], "parent snapshot order differs")
    first, last = (check_phase(plan, inventories, guest_boots, snap) for snap in (before, after))
    require(first["native_paths"] == last["native_paths"] and first["native_parents"] == last["native_parents"],
            "native parent placement changed through the timed study")
    for arm in "AB":
        require([r["inside"]["leaf"] for r in before["arms"][arm]["containers"]] ==
                [r["inside"]["leaf"] for r in after["arms"][arm]["containers"]],
                f"{arm} resident or leaf identity changed through the timed study")
    for path, group in before["arms"]["A"]["worker"]["groups"].items():
        later = after["arms"]["A"]["worker"]["groups"][path]
        require(group["inode"] == later["inode"] and
                all(later["files"][key] == value for key, value in group["files"].items() if key != "cgroup.events"),
                f"ancestor controller state changed at {path}")
    if require_retired:
        retirement = read(folder, "job-parent-retired.json")
        worker = retirement["worker"]
        require(retirement["status"] == "unmounted" and worker["boot"] == guest_boots["A"]
                and worker["observer"] == after["arms"]["A"]["worker"]["observer"]
                and worker["paths"] == retired_paths(after, plan["job_parent"]) and worker["present"] == []
                and max(r["inside"]["guest_unix_ns"] for r in after["arms"]["A"]["containers"])
                < worker["guest_unix_ns"], "native payload leaves, job parents or observer remained after cleanup")
    return {**last, "native_process_count_before": first["native_process_count"],
            "compiler_executables": check_probes(plan, inventories, guest_boots, before, read(folder, PROBES)),
            "before_host_finished_unix_ns": before["host_finished_unix_ns"],
            "after_host_started_unix_ns": after["host_started_unix_ns"]}
