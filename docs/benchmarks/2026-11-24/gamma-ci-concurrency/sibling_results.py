"""Replay in-guest sibling samples and pool matched layout or kernel comparisons."""
import argparse
from collections import Counter
from datetime import datetime
import gzip
from functools import cache
import json
import plistlib
import random
import re
from pathlib import Path
from statistics import median

from qualify import LABEL, require, terminal
from sibling_ci import check_link, placement, quantile, score_wave
import sibling_build
import sibling_counters
import sibling_weight
import sibling_sched
import sibling_topology

METRICS = ("p50_us", "p95_us", "p99_us", "requests_per_second", "slowest_client_p95_us")
CPU_GROUP_LABEL = "io.micropod.ci.cpu-group"
GROUP_CPUS = ("0", "1", "2", "3")
FIXED_STUDY_INPUTS = (
    "host", "rounds", "healthy_pairs", "requests_per_client", "quiet_source_sha256", "harness_sha256",
    "build_driver_sha256", "group_runner_test_sha256", "group_affinity_source_sha256", "link_source_sha256",
    "build_policy_source_sha256", "build_policy_probe_sha256", "build_policy_dispatch_sha256",
    "mthp64_dispatch_sha256", "mthp64_observer_sha256",
    "weight_driver_sha256", "slice_probe_sha256", "trace_driver_sha256", "trace_server_sha256", "trace_client_sha256",
)


def metrics(plan, mode):
    if plan.get("dense_ms", 0) and mode == "all":
        extra = ("build_makespan_s", "slowest_build_s") if plan.get("builders") else ()
        return (*METRICS, "least_client_requests", "most_client_requests", *extra)
    return METRICS


def read(folder, name):
    return json.loads((folder / name).read_bytes())


def create_values(argv, flag):
    values = []
    for index, arg in enumerate(argv):
        option, equals, value = arg.partition("=")
        if option == flag:
            require(equals or index + 1 < len(argv), f"missing value for {flag}")
            values.append(value if equals else argv[index + 1])
    return values


def check_create(argv, name, network, labels, cpus, cpuset):
    require(argv[:1] == ["run"] and create_values(argv, "--name") == [name] and
            create_values(argv, "--network") == [network] and create_values(argv, "--cpus") == ([cpus] if cpus else []) and
            sorted(create_values(argv, "--label")) == sorted(f"{k}={v}" for k, v in labels.items()) and
            create_values(argv, "--cpuset-cpus") == ([cpuset] if cpuset else []) and
            not any(create_values(argv, x) for x in ("--cpu-period", "--cpu-quota")),
            f"incorrect CPU placement request for {name}")


def check_group_container(row, name, network, network_id, labels, cpus, mask):
    links = row["NetworkSettings"]["Networks"]
    host = row["HostConfig"]
    require(re.fullmatch("[a-f0-9]{64}", row["Id"]) and row["Name"].lstrip("/") == name and
            row["State"]["Running"] is True and all(row["Config"]["Labels"].get(k) == v for k, v in labels.items()) and
            set(links) == {network} and links[network]["NetworkID"] == network_id and
            (host.get("CpusetCpus") or "") == mask and (host.get("NanoCpus") or 0) == cpus * 1_000_000_000 and
            not host.get("CpuQuota") and not host.get("CpuPeriod"), f"Docker inspect differs for {name}")


def check_affinity(row, mask):
    pid, threads = row["pid"], row["threads"]
    tids = {thread["tid"] for thread in threads}
    require(type(pid) is int and len(tids) == len(threads) and pid in tids and
            all(type(t["tid"]) is int and t["tid"] > 0 and t["cpus_allowed_list"] == mask for t in threads),
            f"Linux threads for PID {pid} did not keep affinity {mask}")


def check_network(row, network, network_id, owner, driver):
    require(row["Id"] == network_id and row["Name"] == network and row["Internal"] is True and
            row["Driver"] == driver and row["Labels"].get(LABEL) == owner, "private network identity differs")
    if driver in ("macvlan", "ipvlan"):
        require(not (row.get("Options") or {}).get("parent"), "unexpected parent interface for private L2 network")


def check_placement_inventory(inventory, plan, layout):
    owner = Path(plan["scope"]).name
    builders = plan.get("builders", 0)
    grouped = layout == "grouped"
    assigned = {}
    for arm, source in (("A", "native-group"), ("B", "explicit-cpuset")):
        cohort = inventory[arm]
        prefix = f"{owner}-{arm.lower()}-{layout}"
        jobs = cohort["jobs"]
        require(cohort["network"] == prefix and len(jobs) == len({j["id"] for j in jobs}) == 64,
                "invalid CPU placement cohort")
        mode = plan.get("network_topology")
        if mode:
            require(grouped and plan.get("network_driver") == "ipvlan", "unexpected timed network protocol")
            networks = sibling_topology.check_membership(cohort, owner, prefix, mode)
        else:
            check_network(cohort["inspect"], prefix, cohort["network_id"], owner, plan.get("network_driver", "bridge"))
            networks = {prefix: cohort["inspect"]}
        groups = {}
        for pos, job in enumerate(jobs):
            client, slot = divmod(pos, 32)
            name = f"{prefix}-{'c' if client else 's'}{slot}"
            network = sibling_topology.slot_network(prefix, mode, slot)
            labels = {LABEL: owner}
            if grouped:
                group = f"job-{slot:02d}"
                mask = job["mask"]
                requested = "" if arm == "A" else mask
                docker_mask = mask
                labels[CPU_GROUP_LABEL] = group
                require(mask in GROUP_CPUS and job["cpu_group"] == group and job["placement_source"] == source and
                        groups.setdefault(group, mask) == mask, f"incorrect CPU group {group} for {name}")
            else:
                mask = placement(layout, slot, bool(client))
                requested = docker_mask = "" if layout == "shared" else mask
                require("cpu_group" not in job and "placement_source" not in job,
                        f"unexpected automatic CPU group for {name}")
            require(job["requested_cpuset"] == requested and job["name"] == name and job["mask"] == mask,
                    f"incorrect CPU placement for {name}")
            check_create(job["create_argv"], name, network, labels, "1", requested)
            row = job["docker_inspect"]
            check_group_container(row, name, network, networks[network]["Id"], labels, 1, docker_mask)
            require(row["Id"] == job["id"] and job["docker_cpuset"] == docker_mask and
                    row["Config"]["Labels"].get(CPU_GROUP_LABEL) == labels.get(CPU_GROUP_LABEL) and
                    row["NetworkSettings"]["Networks"][network]["IPAddress"] == job["ip"], f"wrong container identity for {name}")
            program = "/mpcheck/netbench" if client and slot < builders else "/netbench"
            affinity = job["affinity"]
            start, span, end = mask.partition("-")
            visible = int(end) - int(start) + 1 if span else 1
            require(affinity["argv"] == [program, "-listen", ":8080", "-marker", name] and
                    job["cgroup"]["visible_cpus"] == visible, f"incorrect service process or CPU count for {name}")
            check_affinity(affinity, mask)

        if not grouped:
            require("placement" not in cohort, f"unexpected automatic CPU group placement on engine {arm}")
            continue
        groups_per_cpu = Counter(groups.values())
        builders_per_cpu = Counter(groups[f"job-{i:02d}"] for i in range(builders))
        actual = {"groups": groups, "groups_per_cpu": dict(groups_per_cpu),
                  "builders_per_cpu": {cpu: builders_per_cpu[cpu] for cpu in GROUP_CPUS}}
        require(all(groups_per_cpu[cpu] == 8 and builders_per_cpu[cpu] == builders // 4 for cpu in GROUP_CPUS) and
                cohort["placement"] == actual, f"unbalanced or incorrect placement summary for engine {arm}")
        assigned[arm] = actual
    require(assigned.get("A") == assigned.get("B"), "peer did not match the native vCPU of every pair")
    return assigned.get("A")


def docker_time_ns(value):
    stamp = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)", value)
    require(stamp is not None, f"invalid Docker timestamp: {value!r}")
    seconds = int(datetime.fromisoformat(stamp[1] + stamp[3]).timestamp())
    return seconds * 1_000_000_000 + int((stamp[2] or "0").ljust(9, "0"))


def container_startup(jobs):
    created, started = [], []
    for job in jobs:
        row = job["docker_inspect"]
        created.append(docker_time_ns(row["Created"]))
        started.append(docker_time_ns(row["State"]["StartedAt"]))
        require(0 < created[-1] < started[-1], f"invalid create-to-start interval for {job['name']}")
    return {"containers": len(jobs), "created_to_started_span_s": (max(started) - min(created)) / 1e9,
            "median_container_created_to_started_s": median(b - a for a, b in zip(created, started)) / 1e9}


def check_cpu_delta(job, sample):
    before, after = job["cgroup"], sample["cgroup"]
    require(all(after[k] == before[k] for k in ("cpu.max", "cpuset.cpus.effective", "visible_cpus", "gomaxprocs",
                                               "memory.max", "pids.max")), f"CPU group resources changed for {job['name']}")
    def stat(values):
        return {k: int(v) for k, v in (line.split() for line in values["cpu.stat"].splitlines())}
    old, new = stat(before), stat(after)
    require({"usage_usec", "system_usec", "nr_periods", "nr_throttled", "throttled_usec"} <= old.keys() <= new.keys(),
            f"missing CPU group counters for {job['name']}")
    delta = {k: new[k] - value for k, value in old.items()}
    require(all(value >= 0 for value in delta.values()) and delta == sample["delta"],
            f"CPU group counters changed for {job['name']}")


def check_group_smoke(folder, plan):
    smoke = read(folder, "cpu-group-smoke.json")
    owner = Path(plan["scope"]).name
    network = owner + "-cpu-group-smoke"
    net_id = smoke["network"]["Id"]
    check_network(smoke["network"], network, net_id, owner, "bridge")
    cases = {
        "unlabeled": (None, "1", "", "", "0-3", "100000 100000"),
        "anchor": ("smoke-anchor", "", "", "0", "0", "100000 100000"),
        "group": ("smoke-job", "", "", "1", "1", "100000 100000"),
        "explicit-cpuset": ("smoke-job", "1", "1-2", "1-2", "1-2", "100000 100000"),
        "explicit-quota": ("smoke-job", "2", "", "", "0-3", "200000 100000"),
        "joined": ("smoke-job", "", "", "1", "1", "100000 100000"),
    }
    require(smoke["removed"] is True and smoke["cases"].keys() == cases.keys(), "incomplete CPU group smoke")

    def check(case, record):
        group, cpus, requested, docker_mask, mask, quota = cases[case]
        name = f"{network}-{case}"
        labels = {LABEL: owner}
        if group:
            labels[CPU_GROUP_LABEL] = group
        if "create_argv" in record:
            check_create(record["create_argv"], name, network, labels, cpus, requested)
        row = record["docker_inspect"]
        check_group_container(row, name, network, net_id, labels, int(cpus or "0"), docker_mask)
        require(row["Config"]["Labels"].get(CPU_GROUP_LABEL) == group, f"wrong smoke CPU group for {name}")
        limits = record["cgroup"]
        require(limits["cpuset.cpus.effective"] == mask and limits["cpu.max"] == quota and
                limits["memory.max"] == str(128 << 20) and limits["pids.max"] == "64" and limits["gomaxprocs"] == 1 and
                limits["visible_cpus"] == {"0-3": 4, "1-2": 2}.get(mask, 1), f"wrong smoke CPU resources for {name}")
        affinity = record["affinity"]
        require(affinity["argv"] == ["/netbench", "-listen", ":8080", "-marker", name], f"wrong smoke process for {name}")
        check_affinity(affinity, mask)
        return row

    require(all("create_argv" in case for case in smoke["cases"].values()), "missing smoke create requests")
    rows = {name: check(name, smoke["cases"][name]) for name in cases}
    require(len({row["Id"] for row in rows.values()}) == len(cases), "smoke cases reused a container")
    initial, stopped, restarted = rows["group"], smoke["stopped"], check("group", smoke["restarted"])
    require(stopped["Id"] == initial["Id"] == restarted["Id"] and stopped["State"]["Running"] is False and
            stopped["Config"]["Labels"] == initial["Config"]["Labels"] and stopped["HostConfig"]["CpusetCpus"] == "1" and
            stopped["State"]["StartedAt"] == initial["State"]["StartedAt"] != restarted["State"]["StartedAt"],
            "CPU group placement did not survive a stop and restart")

    test_log = folder / "linux-cpu-group-tests.txt"
    log = test_log.read_text()
    require(log.rstrip().endswith("\nPASS") and "--- PASS: TestDockerCPUGroup" in log and
            "--- PASS: TestDockerCPUSetWithinAllocation (" in log and
            "--- PASS: TestDockerCPUQuotaPreservesDefaultsAndExplicitLimits (" in log and
            terminal.digest(test_log) == smoke["test_log_sha256"],
            "unverified Linux CPU group tests")


def mixed_profile(raw, builders, cutoff_us):
    out = {}
    all_tail_shares = []
    for name, clients in (("with_build", raw[:builders]), ("http_only", raw[builders:])):
        samples = [s for r in clients for s in r["receipt"]["samples"]]
        latency = [s["total_ns"] / 1000 for s in samples]
        tail = [s for s in samples if s["total_ns"] >= round(1000 * cutoff_us)]
        all_tail_shares.extend((s["first_response_byte_ns"] - s["wrote_request_ns"]) / s["total_ns"] for s in tail)
        out[name] = {"calls_per_client": len(samples) / len(clients), "p50_us": median(latency),
                     "p95_us": quantile(latency, .95), "p99_us": quantile(latency, .99),
                     "wave_tail_calls_per_1000": 1000 * len(tail) / len(samples)}
    out["wave_tail"] = {"median_fraction_write_to_first_byte": median(all_tail_shares)}
    return out


@cache
def verified(folder):
    plan = read(folder, "plan.json")
    require(not plan.get("offered_rps"), "use sibling_paced_results.py for prescribed arrivals")
    require(read(folder, "status.json")["complete"] is True and read(folder, "verification.json") ==
            {"baseline_files": 24, "extra_cleanup_errors": []}, "incomplete sibling run")
    cleanup = read(folder, "cleanup.json")
    require(not cleanup["retained"] and not cleanup["errors"] and cleanup["scope"] == plan["scope"]
            and not Path(cleanup["scope"]).exists(), "sibling worker scope remains")
    require(plan["healthy_pairs"] == 32 and plan["requests_per_client"] == 200 and plan["rounds"] >= 4,
            "need a full sibling cohort")
    cpu_group_study = plan.get("cpu_groups", False)
    require(cpu_group_study is ("grouped" in plan["layouts"]), "CPU group qualification mode differs")
    require(terminal.digest(folder / "quiet-http.go") == plan["quiet_source_sha256"] and
            terminal.digest(folder / "sibling-driver.py") == plan["harness_sha256"], "archived driver changed")
    build = read(folder, "worker-build.json")
    images = read(folder, "images.json")
    proof = images["expected"]
    require(images["inspected"]["A"]["Id"] == "sha256:" + proof["config"] and
            images["inspected"]["B"]["Id"] == "sha256:" + proof["manifest"] and
            images["inspected"]["B"]["RootFS"]["Layers"] == ["sha256:" + proof["diff_id"]], "image identity differs")
    if "fair_slice_us" in plan:
        require(terminal.digest(folder / "sibling_slice_linux.go") == plan["slice_source_sha256"], "slice observer changed")
    builders = plan.get("builders", 0)
    build_policy = plan.get("build_policy")
    build_slice_us = plan.get("build_slice_us")
    require(build_slice_us is None or (build_policy == "normal" and build_slice_us in (0, 250)), "invalid build slice")
    mthp = plan.get("mthp_64k")
    if mthp:
        import build_mthp16
        import sibling_mthp
        require(builders == 8 and cpu_group_study and mthp in ("never", "always"), "unexpected anonymous page trial")
        sibling_mthp.verify_dispatch(folder, plan)
        sibling_mthp.check_boot(folder / "a/guest-facts.txt", mthp)
    if build_policy is not None:
        require(builders == 8 and cpu_group_study and build_policy in sibling_build.BUILD_POLICIES and
                terminal.digest(folder / sibling_build.POLICY_SOURCE) == plan["build_policy_source_sha256"] and
                terminal.digest(folder / sibling_build.POLICY_DISPATCH_FILE) == plan["build_policy_dispatch_sha256"] and
                (folder / sibling_build.POLICY_DISPATCH_FILE).read_text() == sibling_build.POLICY_DISPATCH and
                re.fullmatch(r"[a-f0-9]{64}", plan["build_policy_probe_sha256"]), "build policy observation inputs differ")
    group_placement = None
    startup = {}
    if cpu_group_study:
        require(plan["cpu_group_label"] == CPU_GROUP_LABEL and builders in (0, 4, 8) and not plan.get("socket_sched_trace") and
                terminal.digest(folder / "sibling-group.py") == plan["group_driver_sha256"] and
                terminal.digest(folder / "sibling_group_affinity_linux.go") == plan["group_affinity_source_sha256"] and
                all(re.fullmatch("[a-f0-9]{64}", plan[key]) for key in ("group_affinity_probe_sha256", "group_runner_test_sha256")),
                "unverified CPU group qualification inputs")
        check_group_smoke(folder, plan)
    shares = plan.get("builder_shares")
    fair = plan.get("guest_fair")
    network_driver = plan.get("network_driver")
    if network_driver:
        require(terminal.digest(folder / "sibling_link_linux.go") == plan["link_source_sha256"],
                "network observer source differs")
    counters = {}
    if plan.get("timer_counters"):
        require(terminal.digest(folder / "sibling_counters_linux.go") == plan["counter_source_sha256"],
                "counter observer source changed")
    if plan.get("socket_sched_trace"):
        require(terminal.digest(folder / "sibling_trace_linux.go") == plan["trace_source_sha256"] and
                terminal.digest(folder / "trace-driver.py") == plan["trace_driver_sha256"] and
                plan.get("trace_server_sha256") == proof["netbench"] and
                plan.get("trace_client_sha256") == plan["quiet_sha256"], "unverified traced executables")
    worker_scheduler = plan.get("worker_scheduler")
    if fair or worker_scheduler:
        receipt = sibling_sched.read(folder / "fair-scheduler", fair or "inherit", worker_scheduler, plan.get("worker_next_buddy", False))
        require(terminal.digest(folder / "fair-scheduler.sh") == plan["fair_hook_sha256"] and
                receipt == read(folder, "fair-scheduler.json") and receipt["clocksource"] == "arch_sys_counter",
                "unverified guest scheduler state")
    allocation = {}
    if builders:
        go = read(folder, "go-image.json")
        require(go["expected"]["ci_config_sha256"] == sibling_build.CONFIG
                and go["inspected"]["A"]["Id"] == "sha256:" + sibling_build.CONFIG
                and go["inspected"]["B"]["Id"] == go["expected"]["manifest_id"]
                and go["inspected"]["B"]["RootFS"]["Layers"] == go["expected"]["layer_ids"]
                and terminal.digest(folder / "sibling-build.py") == plan["build_driver_sha256"]
                and (folder / "job.sh").read_text() == sibling_build.fanout.JOB
                and (folder / "go-dispatch.sh").read_text() == sibling_build.DISPATCH, "CI build input mismatch")
    if shares is not None:
        require(plan["layouts"] == ["same"] and builders == 8 and
                terminal.digest(folder / "weight-driver.py") == plan["weight_driver_sha256"] and
                terminal.digest(folder / "sibling_weight_linux.go") == plan["weight_source_sha256"] and
                "--- PASS: TestDockerCPUShares" in (folder / "linux-weight-tests.txt").read_text(),
                "CPU weight qualification inputs differ")
    job = plistlib.loads((folder / "a/job.plist").read_bytes())
    env = job["EnvironmentVariables"]
    if worker_scheduler:
        args = [] if worker_scheduler == "inherit" else ["micropod.ci_sched=" + worker_scheduler]
        if plan.get("worker_next_buddy"):
            args.append("micropod.ci_wakeup=next-buddy")
        if mthp:
            args.extend(build_mthp16.kernel_args(mthp))
        require(env.get("MICROPOD_SANDBOX_KERNEL_ARGS") == (" ".join(args) or None) and
                build["guest_start_sha256"] == build["compiled_sources"]["ci/runner/start.sh"] ==
                terminal.digest(Path(build["arena"]) / "micropod-oci-tools/runner/start.sh"),
                "worker boot selection or packaged guest startup changed")
    pages = plan["pages"]
    effective = read(folder, "a/worker.json")
    facts = (folder / "a/guest-facts.txt").read_text().splitlines()
    if mthp:
        boot_id, = [line.removeprefix("boot=") for line in facts if line.startswith("boot=")]
    role = plan.get("mac_process_type", "Standard")
    require(job["ProgramArguments"] == [build["worker_executable"], "ci", "serve"] and job["ProcessType"] == role
            and env["MICROPOD_CI_CPUS"] == "4" and env["MICROPOD_CI_MEMORY_MIB"] == "4096"
            and env["MICROPOD_CI_KERNEL"] == effective["kernel"]
            and "config_sha256=" + pages["kernel_config_sha256"] in facts, "live worker differs")
    active_kernel = Path(effective["kernel"])
    require(terminal.digest(active_kernel) == pages["kernel_image_sha256"], "selected kernel changed")
    if (folder / "launch-role.json").is_file():
        require(read(folder, "launch-role.json")["spawn_type"] == {"Standard": "daemon (3)", "Interactive": "interactive (4)"}[role]
                and read(folder, "worker-identity.json")["candidate_sha256"] == build["worker_executable_sha256"], "wrong launch role")
    ipvlan_kernel = pages.get("kernel_ipvlan", False)
    require(type(ipvlan_kernel) is bool and (network_driver != "ipvlan" or ipvlan_kernel),
            "IPvlan requires the verified kernel variant")
    require(bool(pages.get("kernel_mthp16")) == bool(mthp), "64 KiB allocation policy and kernel differ")
    if mthp:
        require(ipvlan_kernel and pages["kernel_page_kib"] == 16 and not pages.get("kernel_bounded_buddy"),
                "wrong anonymous page kernel parent")
        kernels = build_mthp16.verify_archived(folder, active_kernel)["candidate"]
        require(terminal.digest(folder / build_mthp16.PROOF) == pages["mthp64_build_sha256"], "wrong THP build receipt digest")
    elif pages.get("kernel_bounded_buddy"):
        import build_bounded_buddy
        require(ipvlan_kernel and pages["kernel_page_kib"] == 16 and worker_scheduler
                and "NO_BOUNDED_BUDDY" in receipt["before"] and
                ("BOUNDED_BUDDY" in receipt["after"]) == (fair == "bounded-buddy"),
                "bounded scheduler feature or kernel readback differs")
        kernels = build_bounded_buddy.verify_archived(folder, active_kernel)["candidate"]
    elif ipvlan_kernel:
        import build_ipvlan

        require(pages["kernel_page_kib"] == 16 and "kernel_hz" not in pages, "wrong base kernel for IPvlan")
        kernels = build_ipvlan.verify_archived(folder, active_kernel)["candidate"]
    elif pages.get("kernel_hz") == 1000:
        kernels = read(folder, "tick-build.json")["candidate"]
    else:
        kernels = read(folder, "kernel-page-pair.json")["candidate" if pages["kernel_page_kib"] == 16 else "control"]
    require(kernels["image_sha256"] == pages["kernel_image_sha256"] and kernels["config_sha256"] == pages["kernel_config_sha256"]
            and kernels["page_kib"] == pages["kernel_page_kib"] and kernels["embedded_config_verified"],
            "kernel build receipt mismatch")
    orders = random.Random(plan["seed"])
    saved = read(folder, "windows.json")
    grouped = {}
    profiles = {}
    cgroup = {}
    overlap = []
    totals = Counter()
    memory = {}
    inherited_slices = {}
    for layout in plan["layouts"]:
        inventory = read(folder, layout + "-inventory.json")
        if mthp:
            prime = read(folder, layout + "-prime.json")
            primed_boot = {arm: sibling_build.check_revision(prime[arm], "sib-prime", inventory[arm]["jobs"][32]["name"])["boot"]
                           for arm in "AB"}
            require(primed_boot["A"] == boot_id and primed_boot["A"] != primed_boot["B"], "unexpected priming guest identity")
            idle_vm = read(folder, layout + "-idle.json")
            pid = idle_vm["pids"]["micropod_vmm"]
            vm_task, = [t for t in idle_vm["after"]["tasks"] if t["pid"] == pid]
            vm_identity = (pid, vm_task["birth_ticks"])
        if build_policy:
            for cohort in inventory.values():
                for item in cohort["jobs"]:
                    sibling_build.check_http_policy(item["http_policy_threads"], item["affinity"]["pid"], item["mask"])
        counts = read(folder, layout + "-cpu.json")
        if cpu_group_study:
            placement_proof = check_placement_inventory(inventory, plan, layout)
            startup[layout] = {arm: container_startup(inventory[arm]["jobs"]) for arm in "AB"}
            if layout == "grouped":
                group_placement = placement_proof
        for a in "AB":
            jobs = inventory[a]["jobs"]
            if network_driver and not cpu_group_study:
                check_network(inventory[a]["inspect"], inventory[a]["network"], inventory[a]["network_id"],
                              Path(plan["scope"]).name, network_driver)
            require(len(jobs) == len({j["id"] for j in jobs}) == len({j["ip"] for j in jobs}) == 64, "invalid sibling count")
            require([v["id"] for v in counts[a]] == [j["id"] for j in jobs], "cgroup snapshots differ")
            if builders:
                delta = [x["delta"] for x in counts[a][32:32 + builders]]
                cgroup[layout, a] = {name: sum(s[name] for s in delta)
                                     for name in ("usage_usec", "system_usec", "nr_periods", "nr_throttled", "throttled_usec")}
            for i, j in enumerate(jobs):
                is_builder = 32 <= i < 32 + builders
                if network_driver:
                    check_link(j["endpoint"], network_driver, j["ip"])
                if cpu_group_study:
                    check_cpu_delta(j, counts[a][i])
                if layout == "grouped":
                    mask = group_placement["groups"][j["cpu_group"]]
                else:
                    mask = placement(layout, i % 32, i >= 32)
                    if "docker_cpuset" in j or layout in ("duo", "free-client", "free-server"):
                        require(j["docker_cpuset"] == ("" if layout == "shared" else mask),
                                "Docker CPU placement differs from the request")
                require(j["mask"] == j["cgroup"]["cpuset.cpus.effective"] == mask
                        and j["cgroup"]["memory.max"] == str((512 if is_builder else 128) << 20)
                        and j["cgroup"]["pids.max"] == ("192" if is_builder else "64")
                        and j["cgroup"]["cpu.max"] == "100000 100000"
                        and j.get("go_image") == (sibling_build.IMAGE if is_builder else None)
                        and j["cgroup"]["gomaxprocs"] == 1, "sibling resources differ")
                if "fair_slice_us" in plan:
                    ns = 1000 * plan["fair_slice_us"]
                    target = plan.get("slice_target", "all")
                    if i >= 32 and "slice_target" in plan:
                        require(j["client_slice_ns"] == (ns if target != "build-clients" or is_builder else 0),
                                "wrong receiving client slice selection")
                    require(j["requested_slice_ns"] == (ns if target == "all" else 0) and
                            all(t["policy"] == t["priority"] == t["nice"] == 0 and t["slice_ns"] > 0 and
                                (not j["requested_slice_ns"] or t["slice_ns"] == j["requested_slice_ns"]) for t in j["threads"])
                            and j["server_pid"] in {t["tid"] for t in j["threads"]}, "wrong running service slice")
                if shares is not None:
                    expected_shares = shares if is_builder else 0
                    require(j["cpu_shares"] == expected_shares and
                            (0 < j["weight"] < 100 if expected_shares else j["weight"] == 100),
                            "wrong kernel weight or Docker shares")
            if builders:
                prime = read(folder, layout + "-prime.json")[a]
                sibling_build.check_revision(prime, "sib-prime", jobs[32]["name"])
            if shares is not None:
                cases = read(folder, "cpu-weight-" + a + ".json")
                require([x["case"] for x in cases] == ["solo", "paired", "reversed"], "missing CPU contention cases")
                for x, indices in zip(cases, ([32], [32, 40], [40, 32])):
                    clients = [jobs[index] for index in indices]
                    require(x["ids"] == [j["id"] for j in clients] and
                            sibling_weight.check(x["raw"], clients) == x["summary"], "CPU allocation proof differs")
                allocation[a] = {"effective_weight": jobs[32]["weight"], "peer_weight": jobs[40]["weight"],
                                 "solo_cpu_fraction": cases[0]["summary"]["cpu_utilization"],
                                 "contended_cpu_fraction": median([cases[1]["summary"]["first_cpu_fraction"],
                                                                  1 - cases[2]["summary"]["first_cpu_fraction"]])}
        schedule = ["AB", "BA"] * (plan["rounds"] // 2)
        orders.shuffle(schedule)
        for block, order in enumerate(schedule):
            for mode in ("one", "all"):
                targets = [block % 32] if mode == "one" else list(range(32))
                key = f"{layout}-{block}-{mode}"
                require(saved[key]["order"] == order, "engine order changed")
                result = {}
                for a in order:
                    raw = json.loads(gzip.decompress((folder / f"{key}-{a}.json.gz").read_bytes()))
                    if build_policy:
                        for item in raw:
                            w = item["receipt"]["window"]
                            sibling_build.check_http_policy(w["threads"], w["pid"], inventory[a]["jobs"][32 + item["index"]]["mask"])
                    if plan.get("slice_target") in ("clients", "build-clients"):
                        for response in raw:
                            job = inventory[a]["jobs"][32 + response["index"]]
                            if not job["client_slice_ns"]:
                                require({t["slice_ns"] for t in response["receipt"]["window"]["threads"]} ==
                                        {t["slice_ns"] for t in job["threads"]}, "untargeted HTTP client slice changed")
                    result[a] = score_wave(raw, inventory[a]["jobs"], 32, targets, 200, a, plan.get("dense_ms", 0) if mode == "all" else 0)
                    if a == "A" and mode == "all" and plan.get("timer_counters"):
                        tag = f"{key}-{a}"
                        counters[layout, block] = sibling_counters.score(folder / (tag + "-counters.json"), tag,
                                                                        raw, plan["dense_ms"]*1_000_000)
                    if builders and mode == "all":
                        if a == "A" and plan.get("socket_sched_trace"):
                            from sibling_trace_results import phases
                            tag = f"{key}-{a}"
                            require(phases(folder, tag, raw, result[a]["p99_us"]) == read(folder, tag + "-phases.json"),
                                    "kernel trace attribution differs from raw receipts")
                        build_rows = read(folder, f"{key}-{a}-go.json")
                        load = sibling_build.score(build_rows, raw,
                                                  inventory[a]["jobs"][32:32 + builders], block, plan["build_nice"],
                                                  build_policy=build_policy,
                                                  **({"build_slice_us": build_slice_us} if build_slice_us is not None else {}))
                        result[a]["build"] = load
                        if build_slice_us is not None and plan.get("fair_slice_us") is None:
                            inherited = sibling_build.inherited_http_slice(build_rows, inventory[a]["jobs"], raw)
                            require(inherited_slices.setdefault(a, inherited) == inherited, "ordinary slice changed during the boot")
                            load["inherited_slice_ns"] = inherited
                        if mthp:
                            tag = f"{key}-{a}"
                            memory[tag] = sibling_mthp.verify_wave(folder, tag, mthp, expected_boot=primed_boot[a],
                                                                   expected_vm=vm_identity if a == "A" else None)
                        for field in ("jobs", "revisions", "test_passes"):
                            totals[field] += load[field]
                    require(all(row["receipt"]["window"]["page_bytes"] == (pages["kernel_page_kib"] * 1024 if a == "A" else 4096)
                                and row["receipt"]["url"] == "http://" + inventory[a]["jobs"][row["index"]]["ip"] + ":8080/id"
                                for row in raw), "endpoint or userspace ABI changed")
                    require(result[a] == saved[key][a], "stored metrics differ from the raw receipts")
                    if builders and mode == "all":
                        result[a]["build_makespan_s"] = result[a]["build"]["makespan_s"]
                        result[a]["slowest_build_s"] = result[a]["build"]["slowest_job_s"]
                        profiles[layout, block, a] = mixed_profile(raw, builders, result[a]["p99_us"])
                    totals["requests"] += result[a]["requests"]
                    totals["warm_connections"] += len(raw)
                    if mode == "all":
                        overlap.append(result[a]["overlap_ns"] / result[a]["window_ns"])
                if builders and mode == "all":
                    require(result["A"]["build"]["products"] == result["B"]["build"]["products"], "Go artifacts differ")
                grouped[(layout, mode, block)] = result
    require(len(grouped) == len(saved), "unplanned windows")
    idle = {}
    for layout in plan["layouts"]:
        if not (folder / (layout + "-idle.json")).is_file():
            continue
        cost = read(folder, layout + "-idle.json")
        old, new = cost["before"], cost["after"]
        elapsed_ns = new["epoch_ns"] - old["epoch_ns"]
        require(elapsed_ns >= 2e9 and (old["tick_numer"], old["tick_denom"]) == (new["tick_numer"], new["tick_denom"]),
                "invalid idle interval")
        for name, pid in cost["pids"].items():
            a, = [x for x in old["tasks"] if x["pid"] == pid]
            b, = [x for x in new["tasks"] if x["pid"] == pid]
            require(a["birth_ticks"] == b["birth_ticks"], "idle process changed")
            ticks = (b["user_ticks"] - a["user_ticks"]) + (b["system_ticks"] - a["system_ticks"])
            idle.setdefault(name, []).append(ticks * new["tick_numer"] / new["tick_denom"] / elapsed_ns)
    return {"plan": plan, "rows": grouped, "profiles": profiles, "cgroup": cgroup, "allocation": allocation, "totals": totals,
            "counters": counters, "memory": memory, "inherited_slices": inherited_slices,
            "group_placement": group_placement, "container_startup": startup,
            "min_overlap_fraction": min(overlap), "idle_cpu_s_per_s": idle,
            "worker": build["worker_executable_sha256"], "guest": build["guest_runner_sha256"],
            "guest_start": build.get("guest_start_sha256"),
            "fair": read(folder, "fair-scheduler.json") if fair or worker_scheduler else None}


def paired(old, new):
    require(len(old) == len(new) and len(old) > 0, "unpaired measurements")
    return {"first": median(old), "second": median(new), "median_ratio": median(b/a for a, b in zip(old, new)),
            "higher": sum(b > a for a, b in zip(old, new)), "pairs": len(new)}


def run_sources(folders):
    folders = [folder.resolve() for folder in folders]
    require(len(set(folders)) == len(folders) > 0, "duplicate or missing sibling run directories")
    plans = [read(folder, "plan.json") for folder in folders]
    seeds = [plan["seed"] for plan in plans]
    scopes = {plan["scope"] for plan in plans}
    require(len(scopes) == len(folders), "duplicate sibling worker scope")
    require(len(set(seeds)) == len(folders), "duplicate sibling trial seed")
    return dict(zip(seeds, folders)), scopes


def pool(folders):
    folders = list(folders)
    sources, _ = run_sources(folders)
    runs = [verified(d) for d in sources.values()]
    first = runs[0]
    plan = first["plan"]
    layouts = plan["layouts"]
    for run in runs:
        require(run["worker"] == first["worker"] and run["guest"] == first["guest"] and run["guest_start"] == first["guest_start"]
                and all(run["plan"].get(field) == plan.get(field) for field in FIXED_STUDY_INPUTS)
                and run["fair"] == first["fair"] and run["inherited_slices"] == first["inherited_slices"]
                and run["plan"]["pages"] == plan["pages"] and run["plan"]["quiet_sha256"] == plan["quiet_sha256"]
                and run["plan"].get("fair_slice_us") == plan.get("fair_slice_us")
                and run["plan"].get("dense_ms", 0) == plan.get("dense_ms", 0)
                and run["plan"].get("builders", 0) == plan.get("builders", 0)
                and run["plan"].get("build_nice") == plan.get("build_nice")
                and run["plan"].get("build_policy") == plan.get("build_policy")
                and run["plan"].get("build_slice_us") == plan.get("build_slice_us")
                and run["plan"].get("mthp_64k") == plan.get("mthp_64k")
                and run["plan"].get("builder_shares") == plan.get("builder_shares")
                and run["plan"].get("guest_fair") == plan.get("guest_fair")
                and run["plan"].get("worker_scheduler") == plan.get("worker_scheduler")
                and run["plan"].get("worker_next_buddy", False) == plan.get("worker_next_buddy", False)
                and run["plan"].get("slice_target", "all") == plan.get("slice_target", "all")
                and run["plan"].get("socket_sched_trace", False) == plan.get("socket_sched_trace", False)
                and run["plan"].get("timer_counters", False) == plan.get("timer_counters", False)
                and run["plan"].get("counter_probe_sha256") == plan.get("counter_probe_sha256")
                and run["plan"].get("network_driver") == plan.get("network_driver")
                and run["plan"].get("link_probe_sha256") == plan.get("link_probe_sha256")
                and run["plan"].get("group_driver_sha256") == plan.get("group_driver_sha256")
                and run["plan"].get("group_affinity_probe_sha256") == plan.get("group_affinity_probe_sha256")
                and run["plan"].get("mac_process_type", "Standard") == plan.get("mac_process_type", "Standard")
                and set(run["plan"]["layouts"]) == set(layouts), "unmatched pooled worker or workload")
    result = {"runs": [f.name for f in folders], "kernel": plan["pages"], "worker": first["worker"], "guest": first["guest"],
              "requests": sum(r["totals"]["requests"] for r in runs), "warm_connections": sum(r["totals"]["warm_connections"] for r in runs),
              "min_dense_common_fraction": min(r["min_overlap_fraction"] for r in runs), "layouts": {}, "changes_from_shared": {}}
    if first["idle_cpu_s_per_s"]:
        result["idle_cpu_s_per_s"] = {name: median(value for r in runs for value in r["idle_cpu_s_per_s"][name])
                                       for name in first["idle_cpu_s_per_s"]}
    if "fair_slice_us" in plan:
        result["fair_slice_us"] = plan["fair_slice_us"]
        if "slice_target" in plan:
            result["slice_target"] = plan["slice_target"]
    if "guest_fair" in plan:
        result["guest_fair"] = read(folders[0], "fair-scheduler.json")
    if worker_scheduler := plan.get("worker_scheduler"):
        result["worker_scheduler"] = worker_scheduler
        result["fair_scheduler"] = read(folders[0], "fair-scheduler.json")
        if plan.get("worker_next_buddy"):
            result["worker_next_buddy"] = True
    if plan.get("socket_sched_trace"):
        result["socket_sched_trace"] = True
    if plan.get("network_driver"):
        result["network_driver"] = plan["network_driver"]
    if plan.get("cpu_groups"):
        result["cpu_groups"] = {"label": CPU_GROUP_LABEL,
                                "boot_count": len(runs),
                                "placement_sources": {"A": "native-group", "B": "explicit-cpuset"},
                                "by_run": [{"run": folder.name, "container_startup": run["container_startup"],
                                            **run["group_placement"]}
                                           for folder, run in zip(folders, runs)]}
    if plan.get("timer_counters"):
        result["guest_counters"] = {}
        for layout in layouts:
            samples = [r["counters"][layout, block] for r in runs for block in range(r["plan"]["rounds"])]
            result["guest_counters"][layout] = {k: median(v[k] for v in samples) for k in samples[0]}
    if "builder_shares" in plan:
        result["builder_shares"] = plan["builder_shares"]
        result["cpu_allocation"] = {arm: {k: median(r["allocation"][arm][k] for r in runs)
                                          for k in first["allocation"][arm]} for arm in "AB"}
    if plan.get("builders"):
        result["builders"] = plan["builders"]
        result["build_nice"] = plan["build_nice"]
        if plan.get("build_policy"):
            result["build_policy"] = plan["build_policy"]
        if plan.get("build_slice_us") is not None:
            result["build_slice_us"] = plan["build_slice_us"]
            result["inherited_slices_ns"] = first["inherited_slices"]
        if plan.get("mthp_64k"):
            result["mthp_64k"] = plan["mthp_64k"]
            result["memory_by_run"] = {folder.name: run["memory"] for folder, run in zip(folders, runs, strict=True)}
        for field in ("jobs", "revisions", "test_passes"):
            result[field] = sum(r["totals"][field] for r in runs)
        result["mixed_profiles"] = {}
        result["builder_cgroup_totals"] = {}
        for layout in layouts:
            for arm in "AB":
                samples = [r["profiles"][layout, block, arm] for r in runs for block in range(r["plan"]["rounds"])]
                key = f"{layout}-{arm}"
                result["mixed_profiles"][key] = {group: {field: median(v[group][field] for v in samples)
                                                        for field in samples[0][group]} for group in samples[0]}
                counts = [r["cgroup"][layout, arm] for r in runs]
                result["builder_cgroup_totals"][key] = {field: sum(v[field] for v in counts) for field in counts[0]}
    references = ["shared"]
    if "same" in layouts and any(l in layouts for l in ("duo", "free-client", "free-server", "grouped")):
        references.append("same")
        result["changes_from_same"] = {}
    for mode in ("one", "all"):
        for layout in layouts:
            keys = [(r, block) for r in runs for block in range(r["plan"]["rounds"])]
            rows = [r["rows"][layout, mode, block] for r, block in keys]
            key = f"{layout}-{mode}"
            fields = metrics(plan, mode)
            result["layouts"][key] = {m: paired([x["B"][m] for x in rows], [x["A"][m] for x in rows]) for m in fields}
            for ref in references:
                if layout != ref and ref in layouts:
                    result[f"changes_from_{ref}"][key] = {
                        a: {m: paired([r["rows"][ref, mode, block][a][m] for r, block in keys],
                                      [x[a][m] for x in rows]) for m in fields} for a in "AB"}
    return result


def compare(controls, candidates):
    controls, control_scopes = run_sources(controls)
    candidates, candidate_scopes = run_sources(candidates)
    require(not set(controls.values()) & set(candidates.values()) and not control_scopes & candidate_scopes,
            "sibling run appears in both comparison arms")
    require(controls.keys() == candidates.keys(), "unmatched sibling trial seeds")
    seeds = sorted(controls)
    left = [verified(controls[seed]) for seed in seeds]
    right = [verified(candidates[seed]) for seed in seeds]
    change = None
    for a, b in zip(left, right):
        p, q = a["plan"], b["plan"]
        require(a["worker"] == b["worker"] and a["guest"] == b["guest"] and a["guest_start"] == b["guest_start"]
                and all(p.get(field) == q.get(field) for field in FIXED_STUDY_INPUTS)
                and a["inherited_slices"] == b["inherited_slices"]
                and all(p[k] == q[k] for k in ("seed", "layouts", "quiet_sha256"))
                and p["pages"]["kernel_page_kib"] == q["pages"]["kernel_page_kib"]
                and p.get("slice_target", "all") == q.get("slice_target", "all")
                and p.get("weight_probe_sha256") == q.get("weight_probe_sha256")
                and p.get("socket_sched_trace", False) == q.get("socket_sched_trace", False)
                and p.get("timer_counters", False) == q.get("timer_counters", False)
                and p.get("counter_probe_sha256") == q.get("counter_probe_sha256")
                and p.get("link_probe_sha256") == q.get("link_probe_sha256")
                and p.get("group_driver_sha256") == q.get("group_driver_sha256")
                and p.get("group_affinity_probe_sha256") == q.get("group_affinity_probe_sha256")
                and p.get("runner_test_sha256") == q.get("runner_test_sha256")
                and p.get("builders", 0) == q.get("builders", 0)
                and p.get("dense_ms", 0) == q.get("dense_ms", 0), "nonmatching sibling trial")
        changes = {k: [p.get(k), q.get(k)] for k in ("fair_slice_us", "mac_process_type", "build_nice", "build_policy", "build_slice_us", "mthp_64k", "builder_shares", "guest_fair", "worker_scheduler", "worker_next_buddy", "network_driver")
                   if p.get(k) != q.get(k)}
        if p["pages"] != q["pages"]:
            require("network_driver" not in changes, "network driver contrast requires the same kernel Image and configuration")
            require(p["pages"].get("kernel_hz", 250) == 250 and q["pages"].get("kernel_hz") == 1000 and
                    not p["pages"].get("kernel_ipvlan"), "wrong tick contrast")
            changes["kernel_hz"] = [250, 1000]
        if changes.keys() & {"guest_fair", "worker_scheduler", "worker_next_buddy"}:
            require(a["fair"] and b["fair"], "missing scheduler readback in a scheduler contrast")
            first, second = a["fair"], b["fair"]
            features = {v.removeprefix("NO_") for v in set(first["after"]) ^ set(second["after"])}
            require(("guest_fair" not in changes or first["before"] == second["before"]) and
                    len(features) + (first["base_slice_ns"] != second["base_slice_ns"]) == 1,
                    "comparison changed multiple effective guest scheduler controls")
        else:
            require(a["fair"] == b["fair"], "guest scheduler changed outside the declared contrast")
        require(len(changes) == 1 and (change is None or changes == change), "trial changed multiple controls")
        change = changes
    out = {}
    for layout in left[0]["plan"]["layouts"]:
        for mode in ("one", "all"):
            pairs = [(a["rows"][layout, mode, block], b["rows"][layout, mode, block])
                     for a, b in zip(left, right) for block in range(a["plan"]["rounds"])]
            fields = metrics(left[0]["plan"], mode)
            out[f"{layout}-{mode}"] = {arm: {m: paired([a[arm][m] for a,b in pairs],
                                                       [b[arm][m] for a,b in pairs]) for m in fields} for arm in "AB"}
            out[f"{layout}-{mode}"]["relative_to_peer"] = {
                m: median((b["A"][m] / a["A"][m]) / (b["B"][m] / a["B"][m]) for a, b in pairs)
                for m in fields}
    return {"change": change, "modes": out}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pool", nargs="+", type=Path, required=True)
    parser.add_argument("--compare-to", nargs="+", type=Path)
    args = parser.parse_args()
    if args.compare_to:
        contrast = compare(args.compare_to, args.pool)
        result = {"control": pool(args.compare_to), "candidate": pool(args.pool),
                  "contrast": contrast}
    else:
        result = pool(args.pool)
    print(json.dumps(result, indent=2))
