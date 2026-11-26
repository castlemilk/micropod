"""Measure file delivery and build placement on the stock Linux CI worker."""

import hashlib
import http.client
import json
import os
import random
import re
import shutil
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor

import churn
from qualify import HERE, relay, request, require, terminal

SIZE = 8 << 20
BODY_SHA = hashlib.sha256(b"micropod" * (SIZE // 8)).hexdigest()
MODES = ("memory", "file-copy", "file", "file-spare")


def small_queue_state(original, limit, tenants=None, alternate=None):
    macs = {key for key in original if re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", key)}
    default = original["tsq-root"]
    gso = {key: "65536" for key in macs | {"parent"}}
    queues = {"tsq-" + key: default for key in macs}
    defaults = {**gso, **queues, "tsq-root": default, "ipv4-tso": "on"}
    targets = dict.fromkeys(macs, str(limit))
    if tenants is not None:
        targets = {row["identity"]["published_mac"]: str((alternate or limit) if i % 2 else limit)
                   for i, row in enumerate(tenants)}
        require(len(tenants) == len(targets) == 32 and set(targets) < macs
                and all(row["identity"]["tcp_queue"] == targets[row["identity"]["published_mac"]] for row in tenants),
                "Docker service did not see its requested TCP queue in its namespace")
    expected = {**defaults, **{"tsq-" + mac: value for mac, value in targets.items()}}
    require(len(macs) == 33 and int(default) > max(limit, alternate or limit)
            and original == (defaults if tenants is None else expected),
            "unexpected publication namespaces, TCP queues, or segmentation settings")
    return expected


def stage(workspace, oci, *, qdisc_probe=False):
    shared = workspace / "kernel-observations"
    shared.mkdir()
    shutil.copy2(HERE / "kernel-observer.sh", shared / "observer.sh")
    if qdisc_probe:
        env = {**os.environ, "GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0", "GOPROXY": "off"}
        env.pop("GOROOT", None)
        subprocess.run(["go", "build", "-trimpath", "-o", shared / "qdisc", HERE / "private_qdisc_linux.go"],
                       cwd=HERE.parents[3] / "guest/runner", env=env, check=True)
    with (oci / "runner/fixture-facts.sh").open("a") as f:
        f.write(
            '\nsh "$MICROPOD_ENGINE_WORKSPACE/kernel-observations/observer.sh" </dev/null '
            '>"$MICROPOD_ENGINE_WORKSPACE/kernel-observations/guest.log" 2>&1 &\n'
        )


class Observer:
    def __init__(self, cohort):
        self.cohort = cohort
        self.shared = cohort.workspace / "kernel-observations"
        self.step = 0

    def collect(self, action):
        idx = self.step
        self.step += 1
        temp = self.shared / "next.tmp"
        temp.write_text(action + "\n")
        temp.rename(self.shared / f"request-{idx}")
        target = self.shared / f"result-{idx}"
        deadline = time.monotonic() + 8
        while not target.exists():
            self.cohort.runner.guard()
            if time.monotonic() > deadline:
                raise RuntimeError(f"guest {action}: " + (self.shared / "guest.log").read_text()[-1200:])
            time.sleep(0.03)
        out = target.read_text()
        (self.cohort.folder / f"guest-{idx:03}-{action}.txt").write_text(out)
        return out

    def sample(self):
        fields = dict(line.split("=", 1) for line in self.collect("sample").splitlines())
        require(
            fields["driver"] == "virtio_net" and fields["tx_kicks"] == fields["tx0_kicks"],
            "unexpected publication NIC",
        )
        return fields


def set_mode(jobs, mode):
    def change(job):
        require(
            request(job, "/artifact-mode?mode=" + mode, "POST").decode() == job["name"],
            "wrong service mode receipt",
        )

    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(change, jobs))


def download(job, partial=False):
    conn = http.client.HTTPConnection("127.0.0.1", job["port"], timeout=10)
    try:
        headers = {"Range": "bytes=137-65674"} if partial else {}
        conn.request("GET", "/data", headers=headers)
        response = conn.getresponse()
        data = response.read()
        if partial:
            want = (b"micropod" * 8211)[137:65675]
            require(
                response.status == 206
                and response.getheader("Content-Range") == f"bytes 137-65674/{SIZE}"
                and data == want,
                "wrong range or content",
            )
        else:
            require(
                response.status == 200 and len(data) == SIZE and hashlib.sha256(data).hexdigest() == BODY_SHA,
                "incorrect full file transfer",
            )
    finally:
        conn.close()


def trace_proof(observer, job):
    observer.collect("trace-on")
    try:
        download(job)
    finally:
        lines = observer.collect("trace-off").splitlines()
    return trace_events(lines)


def trace_events(lines):
    events = [line for line in lines if not line.lstrip().startswith("#") and line.strip()]
    returns = []
    for line in events:
        require(
            re.search(r"\btenant-[0-9]+\b", line) and "sendfile" in line, f"unattributed trace event: {line}"
        )
        m = re.search(r"(?:->|ret[:=])\s*(-?(?:0x[0-9a-f]+|[0-9]+))", line, re.IGNORECASE)
        require(m, f"unparsed syscall return: {line}")
        value = int(m[1], 0)
        if 0 < value <= SIZE:
            returns.append(value)
    return {"return_events": len(events), "positive_bytes": sum(returns)}


def schedule():
    rows = [[0, 1, 3, 2], [1, 2, 0, 3], [2, 3, 1, 0], [3, 0, 2, 1]]
    return [[MODES[i] for i in row] for row in random.Random(7124).sample(rows, 4)]


def paired_order(conditions, seed):
    rows = [(0, 1, 3, 2), (1, 2, 0, 3), (2, 3, 1, 0), (3, 0, 2, 1)]
    return [[conditions[i] for i in row] for row in random.Random(seed).sample(rows, len(rows))]


def peer_modes(mixed):
    return ("file-even", "file-odd") if mixed else ("memory", "file")


def flow_sample(monitor, action="rfs-read"):
    return dict(line.split("=", 1) for line in monitor.collect(action).splitlines())


def flow_counters(cohort, monitor, host_snapshot):
    def service(job):
        data = json.loads(request(job, "/identity"))
        require(data["cookie"] == job["cookie"] and data["cgroup"] == job["identity"]["cgroup"],
                "service cgroup changed during flow steering trial")
        stats = dict(line.split() for line in data["cpu_stat"].splitlines())
        return str(data["cgroup"]), {k: int(stats[k]) for k in ("usage_usec", "nr_throttled", "throttled_usec")}

    def collect(position):
        if position == "after":
            host = host_snapshot(position)
        with ThreadPoolExecutor(max_workers=8) as workers:
            services = dict(workers.map(service, cohort.jobs))
        require(len(services) == 32, "flow steering sample needs all 32 service cgroups")
        queue = {"guest_queue": flow_sample(monitor)} if monitor else {}
        if position == "before":
            host = host_snapshot(position)
        return {**host, **queue, "service_cgroups": services}

    return collect


def mixed_service_modes(cohort, mode, *, apply):
    file_parity = int(mode == "file-odd")
    if apply:
        set_mode(cohort.jobs[file_parity::2], "file")
        set_mode(cohort.jobs[1 - file_parity::2], "memory")
    with ThreadPoolExecutor(max_workers=8) as pool:
        actual = list(pool.map(lambda job: request(job, "/artifact-mode").decode(), cohort.jobs))
    expected = [job["name"] + "\t" + ("file" if i % 2 == file_parity else "memory")
                for i, job in enumerate(cohort.jobs)]
    require(len(actual) == 32 and actual == expected, "mixed service modes differ from their assigned sockets")
    return actual


def peer_confirmation(cohorts, folder, fixed, seed=13438, observers=None, build_slots=4, before_retirement=None,
                      mixed_artifacts=False, build_placement=None, build_scratch=None, build_accounting=False, observe_vm_memory=False):
    # Equal CPU access on both engines. A given block and source build identical revisions.
    modes = peer_modes(mixed_artifacts)
    order = paired_order([arm + "-" + mode for arm in "AB" for mode in modes], seed)
    terminal.save(
        folder / "file-peer-plan.json",
        {
            "order": order,
            "order_seed": seed,
            **({"mixed_artifacts": True} if mixed_artifacts else {}),
            "build_cpus": ["0-1", "2-3"] if build_placement == "pairs" else "0-3",
            **({"dispatch_sha256": hashlib.sha256(churn.job_command(True, accounting=build_accounting).encode()).hexdigest()} if build_placement else {}),
            "build_slots": build_slots,
            "service_file_sha256": BODY_SHA,
            "fixed_client_sha256": terminal.digest(fixed),
        },
    )
    for cohort in cohorts.values():
        cohort.add(32)
        cohort.record_service_cpus("before")
        for mode in ("memory", "file"):
            set_mode(cohort.jobs, mode)
            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(download, cohort.jobs))
                list(pool.map(lambda j: download(j, True), cohort.jobs))
    if observe_vm_memory:
        from build_pages import snapshot_vm
        for cohort in cohorts.values():
            snapshot_vm(cohort, "before")
    for block, row in enumerate(order):
        for condition in row:
            arm, mode = condition.split("-", 1)
            cohort = cohorts[arm]
            idx = 2 * block + modes.index(mode)
            if mixed_artifacts:
                before = mixed_service_modes(cohort, mode, apply=True)
                terminal.save(folder / f"service-modes-{idx}-{arm}-before.json", before)
            else:
                set_mode(cohort.jobs, mode)
            print(f"file confirmation block {block + 1}, {condition}", flush=True)
            churn.batch(cohort, idx, fixed, cpu_list="0-3",
                        observe=observers[arm] if observers else None, build_slots=build_slots,
                        build_placement=build_placement, build_scratch=build_scratch, build_accounting=build_accounting)
            if mixed_artifacts:
                after = mixed_service_modes(cohort, mode, apply=False)
                terminal.save(folder / f"service-modes-{idx}-{arm}-after.json", after)
    if observe_vm_memory:
        for cohort in cohorts.values():
            snapshot_vm(cohort, "after")
    if before_retirement:
        before_retirement()
    for cohort in cohorts.values():
        cohort.record_service_cpus("after")
        if build_scratch == "volume":
            service = cohort.jobs[0]["id"]
            mounts = cohort.cmd("exec", service, "sh", "-ec", '''
                for scratch in /cache/mci-work.*; do test ! -e "$scratch"; done
                test -d /cache/build && test -d /cache/mod
                stat -c '%n %d:%i' /cache/build /cache/mod''')
            terminal.save(folder / f"build-scratch-cleanup-{cohort.arm}.json",
                          {"service": service, "remaining_scratch": [], "shared_caches": mounts.splitlines()})
        cohort.audit_memory()
        churn.replace(cohort)
        cohort.check_docker_cpuset()


def steering_study(cohorts, folder, fixed, seed, observers, build_slots):
    control = Observer(cohorts["A"])

    def read_queue(action):
        sample = dict(line.split("=", 1) for line in control.collect(action).splitlines())
        require(sample["driver"] == "virtio_net" and sample["effective"] == "3",
                "expected one publication queue interrupting vCPU 3")
        return sample

    def observe_micropod(phase):
        return dict(observers["A"](phase), guest_queue=read_queue("rps-read"))

    initial = read_queue("rps-read")
    require(int(initial["rps_cpus"], 16) == 0, "unexpected initial receive steering")
    order = paired_order(("A-local", "A-steered", "B-ref0", "B-ref1"), seed)
    terminal.save(folder / "steering-plan.json", {
        "order": order, "order_seed": seed, "build_slots": build_slots, "initial": initial,
        "artifact": "memory", "service_file_sha256": BODY_SHA, "fixed_client_sha256": terminal.digest(fixed),
    })
    for cohort in cohorts.values():
        set_mode(cohort.jobs, "memory")
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(download, cohort.jobs))
            list(pool.map(lambda j: download(j, True), cohort.jobs))
    for i, row in enumerate(order):
        for condition in row:
            arm, mode = condition.split("-")
            count = 2 * i + int(mode in ("steered", "ref1"))
            observe = observers[arm]
            if arm == "A":
                mask = 7 if mode == "steered" else 0
                changed = read_queue(f"rps-{mask}")
                require(int(changed["rps_cpus"], 16) == mask, "guest did not accept the receive CPU mask")
                observe = observe_micropod
            print(f"Receive steering block {i + 1}, {condition}", flush=True)
            churn.batch(cohorts[arm], count, fixed, cpu_list="0-3", observe=observe, build_slots=build_slots)
    restored = read_queue("rps-0")
    require(int(restored["rps_cpus"], 16) == 0, "guest receive mask did not restore")
    terminal.save(folder / "steering-restored.json", restored)
    control.collect("done")
    for cohort in cohorts.values():
        cohort.audit_memory()
        churn.replace(cohort)


def study(cohort, folder, clients, fixture):
    observer = Observer(cohort)
    cohort.add(32)
    a = observer.sample()
    proof = {}
    for mode in ("memory", "file-copy", "file"):
        set_mode(cohort.jobs, mode)
        proof[mode] = trace_proof(observer, cohort.jobs[0])
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(download, cohort.jobs))
            list(pool.map(lambda j: download(j, True), cohort.jobs))
        terminal.save(folder / "sendfile-proof.json", proof)
    require(
        not proof["memory"]["return_events"]
        and not proof["file-copy"]["return_events"]
        and SIZE - 4096 <= proof["file"]["positive_bytes"] <= SIZE,
        "Linux sendfile path did not match the selected source",
    )
    b = observer.sample()

    def vector(row, key):
        return list(map(int, row[key].split(",")))

    irqs = [y - x for x, y in zip(vector(a, "irq_counts"), vector(b, "irq_counts"), strict=True)]
    cpu = irqs.index(max(irqs))
    require(
        a["boot"] == b["boot"] == fixture["boot"]
        and a["virtio"] == b["virtio"]
        and len(irqs) == 4
        and sum(irqs) > 0
        and max(irqs) / sum(irqs) >= 0.9,
        "no dominant interrupt CPU in delivery preflight",
    )
    spare = ("1-3", "0,2-3", "0-1,3", "0-2")[cpu]
    plan = {
        "order": schedule(),
        "irq_cpu": cpu,
        "other_cpus": spare,
        "preflight_irqs": irqs,
        "service_file_sha256": BODY_SHA,
        "guest_start": a,
        "guest_after_preflight": b,
        "build_slots": 4,
    }
    terminal.save(folder / "kernel-plan.json", plan)
    print(
        f"Published NIC {a['virtio']} IRQ {a['irq']}: per-CPU deltas {irqs}; sendfile {proof['file']['positive_bytes']} bytes",
        flush=True,
    )

    def service_usage(job):
        fields = json.loads(request(job, "/identity"))
        require(
            fields["cookie"] == job["cookie"]
            and fields["cgroup"] == job["identity"]["cgroup"]
            and fields["iflink"] == b["ifindex"],
            "wrong service or macvlan parent",
        )
        stat = dict(line.split() for line in fields["cpu_stat"].splitlines())
        return int(stat["usage_usec"])

    def counters(position):
        if position == "after":
            host = relay.snapshot(clients, fixture)
            guest = observer.sample()
        with ThreadPoolExecutor(max_workers=8) as pool:
            usage = list(pool.map(service_usage, cohort.jobs))
        if position == "before":
            guest = observer.sample()
            host = relay.snapshot(clients, fixture)
        require(guest["boot"] == b["boot"] and guest["ifindex"] == b["ifindex"], "network device changed")
        return {"host": host, "guest": guest, "service_cpu_usec": usage}

    for block, order in enumerate(plan["order"]):
        for index, condition in enumerate(order):
            mode = "file" if condition == "file-spare" else condition
            set_mode(cohort.jobs, mode)
            print(f"kernel block {block + 1}, {condition}", flush=True)
            churn.batch(
                cohort,
                block * 4 + index,
                clients / "fixed",
                cpu_list=spare if condition == "file-spare" else "0-3",
                observe=counters,
            )
    observer.collect("done")
    cohort.audit_memory()
    churn.replace(cohort)
