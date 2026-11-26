"""Measure socket-verified HTTP between CI siblings on a user-defined Docker bridge."""
import argparse
import gzip
import ipaddress
import json
import math
import os
import random
import re
import shutil
import signal
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
from datetime import UTC, datetime
from pathlib import Path
from statistics import median

from qualify import Admission, HERE, LABEL, ROOT, check_baseline, cli, peer, require, terminal
import build_pages
import private_link
import sibling_build
import sibling_client_slice
import sibling_counters
import sibling_group
import sibling_paced
import sibling_weight
import sibling_sched
import sibling_tmpfs
import sibling_topology
import sibling_trace


def quantile(values, frac):
    return sorted(values)[math.ceil(len(values) * frac) - 1]


def placement(layout, index, client):
    if layout == "shared":
        return "0-3"
    cpu = index % 4
    # Both ends keep the same two-vCPU affinity domain. The asymmetric
    # placements give just one end freedom to migrate within that domain.
    if layout == "duo" or (layout == "free-client" and client) or (layout == "free-server" and not client):
        first = cpu - cpu % 2
        return f"{first}-{first + 1}"
    if layout == "split" and client:
        cpu = (cpu + 1) % 4
    return str(cpu)


def parallel(width, fn, items):
    with ThreadPoolExecutor(max_workers=width) as pool:
        return list(pool.map(fn, items))

def idle_cost(probe, pids):
    def counters():
        snap = json.loads(cli([probe], *map(str, pids.values())))
        require({r["pid"] for r in snap["tasks"]} == set(pids.values()), "missing idle CPU counters")
        return snap
    time.sleep(1)
    before = counters()
    time.sleep(2)
    after = counters()
    require(after["epoch_ns"] > before["epoch_ns"] and
            {(r["pid"], r["birth_ticks"]) for r in before["tasks"]} ==
            {(r["pid"], r["birth_ticks"]) for r in after["tasks"]}, "idle processes changed")
    return {"pids": pids, "before": before, "after": after}


def check_threads(rows, leader, requested):
    require(rows and leader in {t["tid"] for t in rows} and len({t["tid"] for t in rows}) == len(rows)
            and all(t["policy"] == t["nice"] == t["priority"] == 0 and t["slice_ns"] > 0
                    and (not requested or t["slice_ns"] == requested) for t in rows),
            f"thread slice or policy differs for PID {leader}, requested {requested}: {rows}")


class Siblings:
    def __init__(self, engine, arm, owner, work, admission, layout, count, slice_us, builders, build_nice, builder_shares, trace_sockets, slice_target, network_driver=None, verify_affinity=False, build_policy=None, build_slice_us=None, network_topology=None, build_scratch=None, compiler_affinity=None):
        self.engine, self.arm, self.owner = engine, arm, owner
        self.work, self.admission, self.layout, self.count = work, admission, layout, count
        self.slice_ns = slice_us * 1000 if slice_us is not None else None
        self.slice_target = slice_target
        self.builders = builders
        self.build_nice = build_nice
        self.build_policy = build_policy
        self.build_slice_us = build_slice_us
        self.build_scratch = build_scratch
        self.compiler_affinity = compiler_affinity
        self.builder_shares = builder_shares
        self.named_sockets = trace_sockets
        self.trace_sockets = trace_sockets and arm == "A"
        self.network = owner + "-" + arm.lower() + "-" + layout
        self.network_driver = network_driver
        self.network_topology = network_topology
        self.verify_affinity = verify_affinity or layout == sibling_group.LAYOUT
        self.peer_groups = None
        self.names = [self.network + ("-c" if client else "-s") + str(i)
                      for client in (False, True) for i in range(count)]
        self.jobs = []

    def cmd(self, *args, **kwargs):
        return cli(self.engine, *args, **kwargs)

    def client_slice(self, index):
        if self.slice_target == sibling_client_slice.TARGET:
            return sibling_client_slice.requested_ns(self.arm, self.slice_ns)
        return self.slice_ns if self.slice_target != "build-clients" or index < self.builders else 0

    def create(self):
        grouped = self.layout == sibling_group.LAYOUT
        if grouped and self.arm == "B":
            require(self.peer_groups is not None, "need the verified native CPU group placement first")
        if self.arm == "B":
            self.admission.names.update(self.names)
        driver = self.network_driver or "bridge"
        if self.network_topology:
            nets, events = sibling_topology.create(self.cmd, self.owner, self.network, self.network_topology)
        else:
            self.cmd("network", "create", "--driver", driver, "--internal",
                     "--label", f"{LABEL}={self.owner}", self.network)
            net, = json.loads(self.cmd("network", "inspect", self.network))
            require(net["Internal"] and net["Driver"] == driver and net["Labels"][LABEL] == self.owner,
                    "wrong private network")
            if driver in ("macvlan", "ipvlan"):
                require(not (net.get("Options") or {}).get("parent"), "private L2 network has an external parent")
            nets = {self.network: net}
        if self.builders:
            sibling_build.volume(self, True)

        def start(item):
            pos, name = item
            index = pos % self.count
            job_network = sibling_topology.slot_network(self.network, self.network_topology, index)
            group = sibling_group.group_name(index) if grouped else None
            if grouped:
                requested_mask = self.peer_groups[group] if self.arm == "B" else ""
            else:
                requested_mask = "" if self.layout == "shared" else placement(self.layout, index, pos >= self.count)
            builds = self.count <= pos < self.count + self.builders
            broad_builder = builds and self.compiler_affinity is not None
            program = "/mpcheck/netbench" if builds else "/netbench"
            named_service = self.named_sockets and pos < self.count
            if named_service:
                program = f"/mpcheck/trace-names/msvc{pos:02}"
            entry = (["--entrypoint", "/mpcheck/slice"] if self.slice_ns is not None else
                     ["--entrypoint", program] if builds or named_service else [])
            launch = ["-slice-ns", str(self.slice_ns if self.slice_target == "all" else 0), program] if self.slice_ns is not None else []
            if broad_builder:
                requested_mask = "0-3"
                entry = ["--entrypoint", "taskset"]
                launch = ["-c", str(index % 4), program]
            argv = ["run", "-d", "--pull=never", "--name", name, "--network", job_network,
                    "--label", f"{LABEL}={self.owner}", "--cpus", "1", "--memory", "512m" if builds else "128m",
                    "--pids-limit", "192" if builds else "64", "-e", "GOMAXPROCS=1",
                    *(["--label", f"{sibling_group.GROUP_LABEL}={group}"] if grouped else []),
                    *(["--cpuset-cpus", requested_mask] if requested_mask else []),
                    "--mount", f"type=bind,src={self.work / 'probe'},dst=/mpcheck,readonly",
                    "--mount", f"type=bind,src={self.work / 'gate'},dst=/gate",
                    *(sibling_build.options(self, name) if builds else []),
                    *(sibling_tmpfs.flags(self.arm, self.build_scratch, index) if builds and self.build_scratch else []),
                    *entry,
                    *(["--cpu-shares", str(self.builder_shares)] if builds and self.builder_shares else []),
                    sibling_build.IMAGE if builds else terminal.SERVICE,
                    *launch,
                    "-listen", ":8080", "-marker", name]
            cid = self.cmd(*argv)
            require(re.fullmatch("[a-f0-9]{64}", cid), "invalid sibling ID")
            return cid, argv, requested_mask, group, program

        # The builder dependencies reserve their groups before admitting
        # HTTP-only groups. Both batches create concurrently in every trial layout.
        first = self.builders if self.verify_affinity else 0
        created = parallel(8, start, enumerate(self.names[:first])) if first else []
        created.extend(parallel(8, start, enumerate(self.names[first:], start=first)))
        ids = [item[0] for item in created]
        rows = json.loads(self.cmd("inspect", *ids))
        require([r["Id"] for r in rows] == ids and len(set(ids)) == self.count * 2, "wrong sibling cohort")

        def verify(item):
            pos, (row, (_, argv, requested_mask, group, program)) = item
            name = self.names[pos]
            builds = self.count <= pos < self.count + self.builders
            broad_builder = builds and self.compiler_affinity is not None
            if not row["State"]["Running"]:
                log = terminal.invoke(*self.engine, "logs", row["Id"], check=False)
                raise ValueError(f"{name} exited during setup: {row['State']} {log.stderr[-300:]}")
            network = row["NetworkSettings"]["Networks"]
            job_network = sibling_topology.slot_network(self.network, self.network_topology, pos % self.count)
            require(row["Name"].lstrip("/") == name and row["State"]["Running"]
                    and row["Config"]["Labels"][LABEL] == self.owner and set(network) == {job_network}
                    and network[job_network]["NetworkID"] == nets[job_network]["Id"], "wrong running sibling")
            ip = str(ipaddress.IPv4Address(network[job_network]["IPAddress"]))
            require(ipaddress.ip_address(ip).is_private and not ipaddress.ip_address(ip).is_loopback, "wrong sibling IP")
            docker_mask = row["HostConfig"].get("CpusetCpus") or ""
            if grouped:
                mask = docker_mask
                allowed = ("0-3",) if broad_builder else sibling_group.CPUS
                require(mask in allowed and (not requested_mask or mask == requested_mask),
                        f"wrong Docker CPU group assignment for {name}")
            else:
                mask = requested_mask or "0-3"
                require(docker_mask == requested_mask, f"wrong Docker CPU set for {name}")
            cgroup = json.loads(self.cmd("exec", row["Id"], "/mpcheck/netbench", "-cgroup-info"))
            quota, period = map(int, cgroup["cpu.max"].split())
            require(cgroup["cpuset.cpus.effective"] == mask and quota == period
                    and cgroup["memory.max"] == str((512 if builds else 128) << 20)
                    and cgroup["pids.max"] == ("192" if builds else "64"),
                    f"incorrect resource limits for {name}: {cgroup}")
            result = {"id": row["Id"], "name": name, "ip": ip, "mask": mask, "docker_cpuset": docker_mask, "cgroup": cgroup}
            if grouped:
                source = "native-group" if self.arm == "A" else "explicit-cpuset"
                result.update(cpu_group=row["Config"]["Labels"][sibling_group.GROUP_LABEL],
                              placement_source="explicit-build-cpuset" if broad_builder else source)
                if self.compiler_affinity is not None:
                    home = str(pos % self.count % 4)
                    require(broad_builder or mask == home, f"unexpected home CPU for {name}")
                    result["home_cpu"] = home
            if self.verify_affinity:
                first_cpu, _, last_cpu = mask.partition("-")
                width = int(last_cpu or first_cpu) - int(first_cpu) + 1
                require(row["Config"]["Labels"].get(sibling_group.GROUP_LABEL) == group
                        and row["HostConfig"].get("NanoCpus") == 1_000_000_000
                        and cgroup["cpu.max"] == "100000 100000" and cgroup["visible_cpus"] == width and cgroup["gomaxprocs"] == 1,
                        f"wrong CPU label, bandwidth or visible CPUs for {name}: {cgroup}")
                result.update(requested_cpuset=requested_mask, create_argv=argv, docker_inspect=row,
                              affinity=sibling_group.service_affinity(self.cmd, row["Id"], name, program,
                                                                     sibling_group.process_mask(result)))
                if self.build_policy:
                    pid = result["affinity"]["pid"]
                    threads = json.loads(self.cmd("exec", row["Id"], sibling_build.POLICY_PROBE, "-inspect", pid))
                    sibling_build.check_http_policy(threads, pid, mask)
                    result["http_policy_threads"] = threads
            if self.network_driver:
                endpoint = json.loads(self.cmd("exec", row["Id"], "/mpcheck/guest-link"))
                check_link(endpoint, driver, ip)
                result["endpoint"] = endpoint
            if self.builder_shares is not None:
                shares = self.builder_shares if builds else 0
                weight = json.loads(self.cmd("exec", row["Id"], "/mpcheck/cpu-weight"))["weight"]
                require((row["HostConfig"].get("CpuShares") or 0) == shares and
                        (1 <= weight < 100 if 0 < shares < 1024 else weight == 100),
                        f"incorrect requested shares or effective CPU weight for {name}: {shares} {weight}")
                result.update(cpu_shares=shares, weight=weight)
            if builds:
                require(row["Config"]["Image"] == sibling_build.IMAGE or row["Config"]["Image"].endswith("/" + sibling_build.IMAGE),
                        "unexpected builder image")
                result["go_image"] = sibling_build.IMAGE
            if self.slice_ns is not None:
                wanted = self.slice_ns if self.slice_target == "all" else 0
                proc = json.loads(self.cmd("exec", row["Id"], "/mpcheck/slice", "-service", name,
                                           "-service-program", "/mpcheck/netbench" if builds else "/netbench"))
                check_threads(proc["threads"], proc["pid"], wanted)
                result.update(threads=proc["threads"], server_pid=proc["pid"], requested_slice_ns=wanted)
                if pos >= self.count:
                    result["client_slice_ns"] = self.client_slice(pos - self.count)
                if self.slice_target == sibling_client_slice.TARGET:
                    sibling_client_slice.check_service(result)
            return result

        self.jobs = parallel(8, verify, enumerate(zip(rows, created, strict=True)))
        require(len({r["ip"] for r in self.jobs}) == 2 * self.count, "duplicate bridge IP")
        inventory = {"network": self.network, "jobs": self.jobs}
        if grouped:
            inventory["placement"] = sibling_group.assignment(self.jobs, self.count, self.builders)
        if self.network_topology:
            inventory.update(attached_networks=sibling_topology.inspect(self.cmd, nets), network_creates=events)
            sibling_topology.check_membership(inventory, self.owner, self.network, self.network_topology)
        else:
            inventory["network_id"] = nets[self.network]["Id"]
            if self.network_driver or self.verify_affinity:
                inventory["inspect"] = nets[self.network]
        return inventory

    def run_wave(self, folder, block, indices, requests, dense_ms, offered_rps=None):
        mode = "one" if len(indices) == 1 else "all"
        duration = dense_ms if mode == "all" else 0
        rate = offered_rps if duration else None
        tag = f"{self.layout}-{block}-{mode}-{self.arm}"
        base = self.work / "gate" / tag
        thread_probe = sibling_group.PROBE if self.verify_affinity else (
            "/mpcheck/slice" if self.slice_ns is not None else None)
        if self.build_policy:
            thread_probe = sibling_build.POLICY_PROBE
        def run(index):
            server, client = self.jobs[index], self.jobs[self.count + index]
            prefix = ["/mpcheck/slice", "-slice-ns", str(self.client_slice(index))] if self.slice_ns is not None else []
            if self.compiler_affinity is not None and index < self.builders:
                prefix = ["taskset", "-c", client["home_cpu"]]
            program = f"/mpcheck/trace-names/mcli{index:02}" if self.named_sockets else "/mpcheck/quiet-http"
            argv = ["exec", client["id"], *prefix, program,
                    *(["-thread-probe", thread_probe] if thread_probe else []),
                    "-url", "http://" + server["ip"] + ":8080", "-marker", server["name"],
                    "-requests", 0 if duration else requests, "-duration-ms", duration,
                    *sibling_paced.client_args(rate, index),
                    "-ready-file", f"/gate/{tag}.{index}", "-start-file", f"/gate/{tag}"]
            result = terminal.invoke(*self.engine, *argv, timeout=40, check=False)
            try:
                row = json.loads(result.stdout)
            except ValueError:
                row = {"error": result.stdout[-500:]}
            raw = {"index": index, "code": result.returncode, "stderr": result.stderr[-500:], "receipt": row}
            if self.compiler_affinity is not None:
                raw["exec_argv"] = argv
            return raw

        build_rows = None
        with ThreadPoolExecutor(max_workers=len(indices)) as pool, ExitStack() as stack:
            tasks = [pool.submit(run, i) for i in indices]
            ready = [base.with_name(f"{tag}.{i}") for i in indices]
            until = time.monotonic() + 18
            while True:
                missing = [i for i, path in zip(indices, ready, strict=True)
                           if not (path.is_file() and path.stat().st_size)]
                if not missing:
                    break
                finished_before_gate = [i for i, task in zip(indices, tasks, strict=True) if task.done()]
                if finished_before_gate or time.monotonic() >= until:
                    break
                time.sleep(.015)
            if not missing:
                start = max(int(p.read_text()) for p in ready) + 600_000_000
                if self.trace_sockets and duration:
                    sibling_trace.start(self, folder, block, tag)
                if self.builders and duration:
                    builders = sibling_build.BuildWave(self, tag, block, folder, build_policy=self.build_policy,
                                                       build_slice_us=self.build_slice_us)
                    stack.callback(builders.close)
                    start = builders.start() + 35_000_000
                tmp = base.with_suffix(".tmp")
                tmp.write_text(str(start))
                tmp.replace(base)
                if duration:
                    done = [p.with_name(p.name + ".done") for p in ready]
                    while not all(p.is_file() for p in done):
                        if any(f.done() for f in tasks) or time.monotonic() >= until:
                            break
                        time.sleep(.01)
                    if self.builders:
                        build_rows = builders.finish()
                    if self.trace_sockets:
                        sibling_trace.stop(self, folder, tag)
                    base.with_name(base.name + ".drain").touch(exist_ok=False)
            rows = []
            for index, task in zip(indices, tasks, strict=True):
                try:
                    rows.append(task.result())
                except Exception as error:
                    if not missing:
                        raise
                    detail = f"{type(error).__name__}: {error}"
                    rows.append({"index": index, "code": -1, "stderr": detail[-500:], "receipt": {"error": detail[-500:]}})
        with gzip.GzipFile(filename=str(folder / (tag + ".json.gz")), mode="xb", mtime=0) as f:
            f.write(json.dumps(rows, separators=(",", ":")).encode())
        if missing:
            failures = []
            for row in rows:
                if row["index"] not in finished_before_gate:
                    continue
                receipt = row["receipt"] if isinstance(row["receipt"], dict) else {}
                window_error = (receipt.get("window") or {}).get("error")
                error = window_error or receipt.get("error")
                if row["code"] != 0 or error:
                    failures.append({"slot": row["index"], "code": row["code"], "error": row["stderr"].strip() or error or ""})
            primary = next((failure for failure in failures if failure["error"] and
                            "context deadline exceeded" not in failure["error"].lower()), failures[0] if failures else None)
            terminal.save(folder / f"{tag}-startup-failure.json", {
                "phase": "http-ready", "arm": self.arm, "ready_slots": [i for i in indices if i not in missing],
                "missing_slots": missing, "finished_slots": finished_before_gate, "failures": failures, "primary": primary,
            })
            if primary:
                detail = primary["error"] or f"exit status {primary['code']}"
                raise ValueError(f"{tag} HTTP startup failed at slot {primary['slot']} before the gate. {detail}")
            raise ValueError(f"{tag} HTTP startup gate withheld with missing ready slots {missing}")
        if self.build_policy:
            for row in rows:
                w = row["receipt"].get("window") or {}
                require(w.get("threads"), f"missing HTTP policy: {row['stderr']} {w.get('error', '')}")
                job = self.jobs[self.count + row["index"]]
                if self.slice_target == sibling_client_slice.TARGET:
                    sibling_client_slice.check_client(row["receipt"], job, self.arm, self.slice_ns, paced=rate is not None)
                else:
                    sibling_build.check_http_policy(w["threads"], w["pid"], job["mask"])
        if rate:
            result = sibling_paced.score_wave(rows, self.jobs, self.count, indices, self.arm, rate, check_threads=check_threads)
        else:
            result = score_wave(rows, self.jobs, self.count, indices, requests, self.arm, duration)
        if self.trace_sockets and duration:
            from sibling_trace_results import phases
            terminal.save(folder / (tag + "-phases.json"), phases(folder, tag, rows, result["p99_us"]))
        if self.builders and duration:
            score_build = sibling_paced.score_build if rate else sibling_build.score
            result["build"] = score_build(build_rows, rows, self.jobs[self.count:self.count + self.builders],
                                          block, self.build_nice, build_policy=self.build_policy, build_slice_us=self.build_slice_us)
            if self.slice_target == sibling_client_slice.TARGET:
                sibling_client_slice.check_builds(build_rows)
            if self.build_slice_us is not None and self.slice_ns is None:
                result["build"]["inherited_slice_ns"] = sibling_build.inherited_http_slice(build_rows, self.jobs, rows)
        return result

    def cpu_deltas(self):
        def sample(job):
            limits = json.loads(self.cmd("exec", job["id"], "/mpcheck/netbench", "-cgroup-info"))
            require(limits["cpuset.cpus.effective"] == job["mask"], "CPU placement changed")
            def stat(values):
                return {k: int(v) for k, v in (line.split() for line in values["cpu.stat"].splitlines())}
            old, new = stat(job["cgroup"]), stat(limits)
            delta = {k: new[k] - old[k] for k in old}
            require(all(v >= 0 for v in delta.values()), "cgroup counters reset")
            result = {"id": job["id"], "delta": delta}
            if self.verify_affinity:
                require({key: value for key, value in limits.items() if key != "cpu.stat"}
                        == {key: value for key, value in job["cgroup"].items() if key != "cpu.stat"},
                        f"CPU group resources changed for {job['name']}")
                result["cgroup"] = limits
            return result
        return parallel(8, sample, self.jobs)

    def clean(self):
        ids = self.cmd("ps", "-aq", "--no-trunc", "--filter", f"label={LABEL}={self.owner}").split()
        if ids:
            rows = json.loads(self.cmd("inspect", *ids))
            require(all(r["Config"]["Labels"].get(LABEL) == self.owner and r["Name"].lstrip("/") in self.names for r in rows),
                    "ambiguous sibling cleanup")
            self.cmd("rm", "-f", *ids, timeout=100)
        require(not self.cmd("ps", "-aq", "--filter", f"label={LABEL}={self.owner}"), "sibling containers remain")
        if self.builders:
            sibling_build.volume(self, False)
        if self.network_topology:
            sibling_topology.retire(self.cmd, self.owner, self.network, self.network_topology)
            return
        if self.network in self.cmd("network", "ls", "--format", "{{.Name}}").splitlines():
            row, = json.loads(self.cmd("network", "inspect", self.network))
            require(row["Labels"].get(LABEL) == self.owner and not row.get("Containers"), "ambiguous network cleanup")
            self.cmd("network", "rm", self.network)
        require(self.network not in self.cmd("network", "ls", "--format", "{{.Name}}").splitlines(),
                "sibling network remains")


def check_link(endpoint, driver, ip):
    kind, mode = {"bridge": ("veth", None), "macvlan": ("macvlan", "bridge"), "ipvlan": ("ipvlan", "l2")}[driver]
    require(endpoint["kind"] == kind and endpoint.get("mode") == mode and endpoint["ipv4"] == [ip]
            and endpoint["mtu"] == 1500 and not endpoint["default_route"], f"unexpected private endpoint: {endpoint}")


def score_wave(rows, jobs, count, indices, requests, arm, duration=0):
    durations, starts, ends, deadlines, by_client = [], [], [], [], []
    require([r["index"] for r in rows] == indices, "missing sibling responses")
    for item in rows:
        i, row = item["index"], item["receipt"]
        valid_samples = bool(row.get("samples")) if duration else len(row.get("samples", [])) == requests
        require(item["code"] == 0 and row.get("complete") and valid_samples,
                f"incomplete {arm} client {i}: {item['stderr']} {row.get('error') or row.get('window')} "
                f"{[s for s in row.get('samples', []) if s.get('error')][:1]}")
        server, client = jobs[i], jobs[count + i]
        w = row["window"]
        require(row["requested"] == (0 if duration else requests) and w.get("duration_ns", 0) == duration * 1_000_000
                and w["finished_unix_ns"] >= w["scheduled_unix_ns"] + duration * 1_000_000, "wrong requested window")
        if "requested_slice_ns" in client:
            check_threads(w["threads"], w["pid"], client.get("client_slice_ns", client["requested_slice_ns"]))
        if "affinity" in client:
            sibling_group.check_threads(w["threads"], w["pid"], sibling_group.process_mask(client))
        require(w["remote"] == server["ip"] + ":8080" and w["local"].rsplit(":", 1)[0] == client["ip"]
                and row["marker"] == server["name"] and w["page_bytes"] in (4096, 16384)
                and w["ready_unix_ns"] < w["scheduled_unix_ns"] <= w["started_unix_ns"] < w["finished_unix_ns"]
                and row["warmup"]["dial_starts"] == 1 and not row["warmup"]["reused"], "wrong guest endpoints or start")
        for s in row["samples"]:
            require(s["got_conn_count"] == 1 and s["same_as_warmup"] and s["reused"] and not s["dial_starts"]
                    and not s.get("error") and s["total_ns"] >= s["first_response_byte_ns"] > 0,
                    "unverified reused connection")
        samples = [s["total_ns"] / 1000 for s in row["samples"]]
        durations.extend(samples)
        by_client.append(quantile(samples, .95))
        starts.append(w["started_unix_ns"])
        ends.append(w["finished_unix_ns"])
        deadlines.append(w["scheduled_unix_ns"])
    common = min(ends) - max(starts)
    elapsed = max(ends) - min(starts)
    require(len(set(deadlines)) == 1 and common > 0, "clients did not share a measured interval")
    result = {"requests": len(durations), "p50_us": median(durations), "p95_us": quantile(durations, .95),
            "p99_us": quantile(durations, .99), "slowest_client_p95_us": max(by_client),
            "requests_per_second": len(durations) * 1e9 / elapsed, "overlap_ns": common,
            "window_ns": elapsed, "start_spread_ns": max(starts) - min(starts)}
    if duration:
        require(common >= .9 * duration * 1_000_000, "less than 90% of sustained window shared by all clients")
        result.update(least_client_requests=min(len(r["receipt"]["samples"]) for r in rows),
                      most_client_requests=max(len(r["receipt"]["samples"]) for r in rows))
    return result


def study(folder, args):
    compiler_affinity = getattr(args, "compiler_affinity", None)
    if compiler_affinity is not None:
        require(compiler_affinity in ("home", "pool") and args.layouts == ["grouped"]
                and args.cpu_groups and args.builders == 8 and args.slice_us is None and args.build_policy is None
                and not args.trace_sockets, "compiler migration needs the fixed grouped workload")
    native_client_slice = args.slice_target == sibling_client_slice.TARGET
    fixture_sources = Path(__file__).parent if native_client_slice else HERE
    opts = terminal.parse_options(["--mode", "host-role", "--socket-evidence", "route", "--run"])
    files = terminal.fixture_files(opts)
    build = private_link.select(files, args.product)
    if args.tick_kernel:
        import build_tick
        require(args.page_kib == 16, "the matched tick kernel uses 16 KiB pages")
        pages = build_tick.select(args.tick_kernel, args.page_kernel_pair, files, folder)
    elif args.mthp_kernel:
        import build_mthp16
        pages = build_mthp16.select(args.mthp_kernel, args.ipvlan_kernel, args.page_kernel_pair, args.mthp_64k, files, folder)
    elif args.buddy_kernel:
        import build_bounded_buddy
        pages = build_bounded_buddy.select(args.buddy_kernel, args.ipvlan_kernel, args.page_kernel_pair, files, folder)
    elif args.ipvlan_kernel:
        import build_ipvlan
        pages = build_ipvlan.select(args.ipvlan_kernel, args.page_kernel_pair, files, folder)
    else:
        pages = build_pages.select(args.page_kernel_pair, args.page_kib, files, folder)
    terminal.check_archives(files)
    terminal.verify_cache()
    require(cli(["orbctl"], "config", "get", "cpu") == "4" and cli(["orbctl"], "config", "get", "memory_mib") == "4096",
            "peer resource limits differ")
    admission = Admission(folder)
    admission.check(force=True)
    runner = terminal.Run(opts, folder, admission)
    admission.owner = runner.root.name
    try:
        work, oci, _ = terminal.stage(runner.root, files)
        (work / "gate").mkdir(mode=0o777)
        (work / "gate").chmod(0o777)
        env = {**os.environ, "CGO_ENABLED": "0", "GOOS": "linux", "GOARCH": "arm64"}
        source = work / "main.go"
        quiet_source = args.quiet_source or ROOT / "scripts/netbench/quiet/main.go"
        extra = {}
        if native_client_slice:
            extra.update(sibling_client_slice.stage(quiet_source, source, folder))
        else:
            shutil.copyfile(quiet_source, source)
        probe = work / "probe/quiet-http"
        terminal.invoke("go", "build", "-trimpath", "-buildvcs=false", "-o", probe, source, env=env)
        if args.build_scratch:
            extra.update(sibling_tmpfs.stage(oci, work, folder, args.build_scratch))
        if args.mthp_64k:
            extra["mthp_64k"] = args.mthp_64k
        if args.offered_rps:
            extra.update(sibling_paced.stage(folder, args.offered_rps))
        if args.cpu_groups:
            extra.update(sibling_group.stage(folder, work / "probe", args.product, env))
        if args.job_network_smoke:
            import sibling_job_network
            extra.update(sibling_job_network.stage(folder))
        if args.ipam_route_product:
            import sibling_ipam
            extra.update(sibling_ipam.stage(oci, work, folder, args.ipam_route_product, env, args.seed))
        if args.network_driver:
            src = fixture_sources / "sibling_link_linux.go"
            target = work / "probe/guest-link"
            terminal.invoke("go", "-C", ROOT / "guest/runner", "build", "-trimpath", "-buildvcs=false", "-o", target,
                            src, env={**env, "GOPROXY": "off"})
            shutil.copyfile(src, folder / src.name)
            extra.update(network_driver=args.network_driver, link_source_sha256=terminal.digest(src),
                         link_probe_sha256=terminal.digest(target))
        if args.network_topology:
            extra.update(sibling_topology.stage(folder, args.network_topology))
        if args.timer_counters:
            extra.update(sibling_counters.stage(oci, work, folder, env, args))
        if args.trace_sockets:
            extra.update(sibling_trace.stage(oci, work, folder, env, files["netbench_image_tar"]))
        if args.guest_fair or args.worker_scheduler:
            sibling_sched.stage(oci, folder, args.guest_fair or "inherit")
            extra["fair_hook_sha256"] = terminal.digest(folder / "fair-scheduler.sh")
            if args.guest_fair:
                extra["guest_fair"] = args.guest_fair
            if args.worker_scheduler:
                extra["worker_scheduler"] = args.worker_scheduler
            if args.worker_next_buddy:
                extra["worker_next_buddy"] = True
        if args.slice_us is not None:
            slice_src = fixture_sources / "sibling_slice_linux.go"
            target = work / "probe/slice"
            terminal.invoke("go", "-C", ROOT / "guest/runner", "build", "-trimpath", "-buildvcs=false",
                            "-o", target, slice_src, env={**env, "GOPROXY": "off"})
            shutil.copy2(slice_src, folder / slice_src.name)
            extra.update(fair_slice_us=args.slice_us, slice_target=args.slice_target, slice_probe_sha256=terminal.digest(target),
                         slice_source_sha256=terminal.digest(slice_src))
        shutil.copy2(files["role_probe"], work / "probe/netbench")
        shutil.copy2(source, folder / "quiet-http.go")
        shutil.copy2(Path(__file__), folder / "sibling-driver.py")
        if args.builders:
            shutil.copy2(sibling_build.__file__, folder / "sibling-build.py")
            extra.update(builders=args.builders, build_nice=args.build_nice,
                         build_driver_sha256=terminal.digest(folder / "sibling-build.py"))
        if args.builder_shares is not None:
            extra.update(sibling_weight.stage(folder, work / "probe", args.product, env), builder_shares=args.builder_shares)
        terminal.save(folder / "worker-build.json", build)
        plan = {"scope": str(runner.root), "host": cli(["hostname"]), "pages": pages, "baseline_files": check_baseline(),
                "healthy_pairs": args.pairs, "requests_per_client": args.requests, "seed": args.seed,
                "quiet_sha256": terminal.digest(probe), "quiet_source_sha256": terminal.digest(source),
                "harness_sha256": terminal.digest(Path(__file__)), "rounds": args.rounds, "layouts": args.layouts,
                "mac_process_type": args.process_type, "dense_ms": args.dense_ms, **extra}
        terminal.save(folder / "plan.json", plan)
        scope, facts = runner.arm("a", 4, files, work, oci, process_type=args.process_type, publication_mtu=9000,
                                  product_mtu=True, relay_mode="kqueue-throughput", published_rps=True,
                                  ci_scheduler=args.worker_scheduler if args.worker_scheduler != "inherit" else None,
                                  ci_next_buddy=args.worker_next_buddy, anon_thp_64k=args.mthp_64k)
        if args.build_scratch:
            sibling_tmpfs.capture_boot(work, folder, args.build_scratch, facts)
        if args.mthp_64k:
            import sibling_mthp
            sibling_mthp.check_boot(facts, args.mthp_64k)
        if args.guest_fair or args.worker_scheduler:
            scheduler = sibling_sched.verify(work, folder, args.guest_fair or "inherit", args.worker_scheduler, args.worker_next_buddy)
            if native_client_slice:
                sibling_client_slice.check_scheduler(scheduler)
        identity, local = private_link.service_preflight.identity(scope, build, 9000)
        terminal.save(folder / "worker-identity.json", identity)
        job = runner.arms[0]["job"]
        live = cli(["launchctl"], "print", job)
        spawn, = re.findall(r"(?m)^\s*spawn type = (.+)$", live)
        relay_pid = int((scope / "relay").read_text())
        require(re.findall(r"(?m)^\s*pid = (\d+)$", live) == [str(relay_pid)] and
                spawn == {"Standard": "daemon (3)", "Interactive": "interactive (4)"}[args.process_type],
                "live CPU scheduling role differs")
        terminal.save(folder / "launch-role.json", {"job": job, "pid": relay_pid, "spawn_type": spawn})
        helper, = [line.split(None, 1)[0] for line in cli(["ps"], "-A", "-o", "pid=,comm=").splitlines()
                   if line.endswith("/Contents/MacOS/OrbStack Helper")]
        pids = {"micropod_vmm": int((scope / "vmm").read_text()), "micropod_supervisor": relay_pid,
                "orbstack_helper": int(helper)}
        require("config_sha256=" + pages["kernel_config_sha256"] in facts.read_text().splitlines(), "wrong guest kernel")
        expected = terminal.verify_service(files["netbench_image_tar"])
        images = {}
        for arm, engine in (("A", local), ("B", peer.DOCKER)):
            img, = json.loads(cli(engine, "image", "inspect", terminal.SERVICE))
            require(img["Architecture"] == "arm64" and img["Os"] == "linux", "service image platform differs")
            if arm == "A":
                require(img["Id"] == "sha256:" + expected["config"], "imported service config differs")
            else:
                require(img["Id"] == "sha256:" + expected["manifest"] and
                        img["RootFS"]["Layers"] == ["sha256:" + expected["diff_id"]], "peer service layers differ")
            images[arm] = img
        terminal.save(folder / "images.json", {"expected": expected, "inspected": images})
        if args.builders:
            fields = sibling_build.stage(folder, runner, work, local, args.image_archive, build_policy=args.build_policy,
                                         build_slice_us=args.build_slice_us, env=env)
            if args.mthp_64k:
                fields.update(sibling_mthp.stage_dispatch(folder, work, args.build_policy))
            if fields:
                plan.update(fields)
                terminal.save(folder / "plan.json", plan)
        if native_client_slice:
            sibling_client_slice.check_plan(plan)
        cli(local, "rm", "-f", identity["container"])
        runner.arms[0]["cid"] = None
        require(not cli(local, "ps", "-q"), "extra private workload")
        if args.cpu_groups:
            runner.guard()
            sibling_group.qualify(local, work, folder, runner.root.name)
            require(not cli(local, "ps", "-aq"), "private CPU group smoke did not clean up")
        if args.build_scratch:
            runner.guard()
            public = sibling_tmpfs.cli_smoke(local, folder, runner.root.name, sibling_build.IMAGE)
            require(public["code"] == 0 and public["auto_removed"], f"public scratch command failed: {public}")
            sibling_tmpfs.restart_smoke(local, folder, runner.root.name, sibling_build.IMAGE)
        if args.job_network_smoke:
            runner.guard()
            def after_workload(proof):
                sibling_ipam.collect(work, folder, proof, extra["ipam_orders"], runner.guard)
            sibling_job_network.qualify(local, work, folder, runner.root.name, images["A"]["Id"], parallel, runner.guard,
                                        after_workload=after_workload if args.ipam_route_product else None)
        randomizer = random.Random(args.seed)
        summary = {}
        for layout in args.layouts:
            cohorts = {a: Siblings(engine, a, runner.root.name, work, admission, layout, args.pairs,
                                   args.slice_us, args.builders, args.build_nice, args.builder_shares, args.trace_sockets,
                                   args.slice_target, args.network_driver, verify_affinity=args.cpu_groups,
                                   build_policy=args.build_policy, build_slice_us=args.build_slice_us,
                                   network_topology=args.network_topology, build_scratch=args.build_scratch,
                                   compiler_affinity=compiler_affinity)
                       for a, engine in (("A", local), ("B", peer.DOCKER))}
            try:
                inventory_path = folder / (layout + "-inventory.json")
                inventories = {"A": cohorts["A"].create()}
                if layout == sibling_group.LAYOUT:
                    terminal.save(inventory_path, inventories)
                    cohorts["B"].peer_groups = inventories["A"]["placement"]["groups"]
                inventories["B"] = cohorts["B"].create()
                if layout == sibling_group.LAYOUT:
                    require(inventories["A"]["placement"] == inventories["B"]["placement"], "peer placement differs from native groups")
                if args.builder_shares is not None:
                    for cohort in cohorts.values():
                        sibling_weight.qualify(cohort, folder)
                terminal.save(inventory_path, inventories)
                if args.builders:
                    terminal.save(folder / (layout + "-prime.json"), {a: sibling_build.prime(cohort) for a, cohort in cohorts.items()})
                if args.build_scratch:
                    sibling_tmpfs.qualify(folder, cohorts, args.build_scratch, "before")
                terminal.save(folder / (layout + "-idle.json"), idle_cost(files["rusage"], pids))
                orders = ["AB", "BA"] * ((args.rounds + 1) // 2)
                randomizer.shuffle(orders)
                for block, order in enumerate(orders[:args.rounds]):
                    for mode in ("one", "all"):
                        indices = [block % args.pairs] if mode == "one" else list(range(args.pairs))
                        tag = f"{layout}-{block}-{mode}"
                        summary[tag] = {"order": order}
                        for a in order:
                            runner.guard()
                            if args.mthp_64k and mode == "all":
                                vm = {"vm_probe": files["rusage"], "vm_pid": pids["micropod_vmm"]} if a == "A" else {}
                                sibling_mthp.snapshot(folder, cohorts[a], tag + "-" + a, "before", args.mthp_64k, **vm)
                            summary[tag][a] = cohorts[a].run_wave(folder, block, indices, args.requests, args.dense_ms, args.offered_rps)
                            if args.mthp_64k and mode == "all":
                                sibling_mthp.snapshot(folder, cohorts[a], tag + "-" + a, "after", args.mthp_64k, **vm)
                                sibling_mthp.collect_builds(folder, cohorts[a], tag + "-" + a, block)
                        if args.builders and mode == "all":
                            require(summary[tag]["A"]["build"]["products"] == summary[tag]["B"]["build"]["products"],
                                    "built artifacts differ between engines")
                        if args.timer_counters and mode == "all":
                            sibling_counters.collect(work, folder, tag + "-A")
                        terminal.save(folder / "windows.json", summary)
                    print(layout, block + 1, "/", args.rounds, flush=True)
                if args.build_scratch:
                    sibling_tmpfs.qualify(folder, cohorts, args.build_scratch, "after")
                    sibling_tmpfs.verify_archived(folder, plan, inventories)
                terminal.save(folder / (layout + "-cpu.json"), {a: cohort.cpu_deltas() for a, cohort in cohorts.items()})
            finally:
                try:
                    cohorts["B"].clean()
                finally:
                    cohorts["A"].clean()
    finally:
        runner.tearing_down = True
        runner.cleanup()
        terminal.save(folder / "verification.json", {"baseline_files": check_baseline(), "extra_cleanup_errors": runner.errors})
        require(not runner.root.exists() and not runner.errors, "private worker cleanup incomplete")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--product", required=True, type=Path)
    parser.add_argument("--quiet-source", type=Path, help="build the HTTP client from an archived source file")
    parser.add_argument("--page-kernel-pair", required=True, type=Path)
    parser.add_argument("--page-kib", choices=(4, 16), type=int, default=16)
    kernel = parser.add_mutually_exclusive_group()
    kernel.add_argument("--tick-kernel", type=Path, help="verified 1,000 Hz variant of the 16 KiB kernel")
    kernel.add_argument("--ipvlan-kernel", type=Path, help="verified 16 KiB kernel with built-in IPvlan")
    parser.add_argument("--buddy-kernel", type=Path, help="experimental EEVDF Image built from the selected IPvlan parent")
    parser.add_argument("--mthp-kernel", type=Path, help="matched 16 KiB IPvlan Image with transparent huge page support")
    parser.add_argument("--mthp-64k", choices=("never", "always"), help="anonymous 64 KiB allocation policy on the matched THP Image")
    parser.add_argument("--process-type", choices=("Standard", "Interactive"), default="Standard")
    parser.add_argument("--guest-fair", choices=tuple(sibling_sched.FEATURES), help="test a guest fair-scheduler setting")
    parser.add_argument("--worker-scheduler", choices=tuple(sibling_sched.WORKER), help="verify the production worker scheduler at boot")
    parser.add_argument("--worker-next-buddy", action="store_true", help="enable the production worker's Linux wakeup preference")
    parser.add_argument("--trace-sockets", action="store_true", help="trace socket syscall and scheduler boundaries on two private-guest pairs")
    parser.add_argument("--timer-counters", action="store_true", help="sample guest ARM interrupts and context switches at each dense window's boundaries")
    parser.add_argument("--network-driver", choices=("bridge", "macvlan", "ipvlan"),
                        help="create an internal network and verify every interface via Linux netlink on both engines")
    parser.add_argument("--network-topology", choices=sibling_topology.MODES,
                        help="use one explicit IPvlan subnet for the cohort or a separate subnet for every CI job")
    parser.add_argument("--slice-us", type=int, choices=(0, 100, 250, *sibling_client_slice.INTERMEDIATE_SLICE_US, 1000),
                        help="ordinary Linux task slice, zero measures the inherited value")
    parser.add_argument("--slice-target", choices=("all", "clients", "build-clients", sibling_client_slice.TARGET), default="all",
                        help="apply the requested slice to all endpoints, clients, build-sharing clients, or Micropod clients only")
    parser.add_argument("--pairs", choices=(4, 32), type=int, default=32)
    parser.add_argument("--rounds", choices=(1, 4, 8), type=int, default=4)
    parser.add_argument("--requests", type=int, choices=(100, 200), default=200)
    parser.add_argument("--dense-ms", type=int, choices=(0, 500, 1500), default=0, help="duration of the 32-client sustained window")
    parser.add_argument("--offered-rps", type=int, choices=sibling_paced.RATES, help="offer a fixed aggregate rate across 32 warmed HTTP connections")
    parser.add_argument("--builders", type=int, choices=(0, 4, 8), default=0, help="run two Go revisions per build slot during dense traffic")
    parser.add_argument("--build-nice", type=int, choices=(0, 5), default=0, help="ordinary Linux nice value for CI build processes")
    parser.add_argument("--build-policy", choices=tuple(sibling_build.BUILD_POLICIES), help="apply a Linux scheduling policy to the build command and its descendants")
    parser.add_argument("--build-slice-us", choices=(0, 250), type=int, help="fair slice for the actual build process tree, zero keeps the inherited slice")
    parser.add_argument("--build-scratch", choices=sibling_tmpfs.MODES, help="compare overlay and private executable tmpfs for native compiler scratch")
    parser.add_argument("--builder-shares", type=int, choices=(0, 512), help="verify and measure native Docker CPU shares for build containers")
    parser.add_argument("--image-archive", type=Path, help="existing pinned offline Go CI archive")
    parser.add_argument("--cpu-groups", action="store_true", help="verify 32 automatic CPU groups and match their placement on OrbStack")
    parser.add_argument("--job-network-smoke", action="store_true", help="qualify 32 separate internal job networks on Micropod")
    parser.add_argument("--ipam-route-product", type=Path, help="production source snapshot with the read-only route benchmark")
    parser.add_argument("--layouts", nargs="+", choices=("shared", "same", "split", "duo", "free-client", "free-server", sibling_group.LAYOUT))
    parser.add_argument("--seed", required=True, type=int)
    args = parser.parse_args()
    require(not args.ipam_route_product or args.job_network_smoke, "the route benchmark needs 32 private job networks")
    if args.ipvlan_kernel and args.page_kib != 16:
        parser.error("--ipvlan-kernel requires --page-kib 16")
    if args.layouts is None:
        args.layouts = [sibling_group.LAYOUT] if args.cpu_groups else ["shared", "same", "split"]
    require(args.cpu_groups == (sibling_group.LAYOUT in args.layouts), "grouped placement requires --cpu-groups")
    require(not args.network_topology or (args.cpu_groups and args.layouts == ["grouped"] and args.network_driver == "ipvlan"
                                         and args.builders == 8 and args.offered_rps),
            "timed network topology needs grouped IPvlan jobs, eight builds and a fixed offer schedule")
    require(not args.cpu_groups or args.pairs == 32, "CPU group placement needs 32 job pairs")
    if args.worker_next_buddy and not args.worker_scheduler:
        args.worker_scheduler = "inherit"
    require(len(set(args.layouts)) == len(args.layouts), "duplicate placement")
    require(not args.builders or (args.builders <= args.pairs and args.dense_ms),
            "mixed Go builds need enough clients and sustained traffic")
    require(args.slice_target == "all" or args.slice_us is not None, "select a task slice for the requested clients")
    require(args.slice_target != "build-clients" or args.builders, "the build-client slice needs concurrent builds")
    require(not args.build_nice or args.builders, "build priority requires CI builds")
    require(not args.build_policy or (args.builders == 8 and args.cpu_groups), "build policy validation requires eight builders with observed affinity")
    require(args.build_slice_us is None or args.build_policy == "normal", "build slice readback requires the ordinary build policy")
    require(args.slice_us not in sibling_client_slice.INTERMEDIATE_SLICE_US or args.slice_target == sibling_client_slice.TARGET,
            "500 and 750 µs measure Micropod HTTP clients only")
    if args.slice_target == sibling_client_slice.TARGET:
        require(args.slice_us in sibling_client_slice.ALLOWED_SLICE_US and args.offered_rps and args.builders == 8
                and args.build_policy == "normal" and args.build_nice == 0 and args.build_slice_us is None
                and args.worker_scheduler == "hrtick" and args.worker_next_buddy and args.guest_fair in (None, "inherit"),
                "native client slice needs a planned interval, paced offers, normal-priority builders and coarse HRTICK/NEXT_BUDDY")
    require(not args.build_scratch or (args.cpu_groups and args.layouts == ["grouped"] and args.builders == 8 and args.page_kib == 16),
            "scratch qualification needs eight grouped builders on a 16 KiB worker")
    require(not args.offered_rps or (args.pairs == 32 and args.dense_ms == 1500 and not args.trace_sockets
                                     and not args.timer_counters), "fixed offers require 32 ordinary sockets and a 1.5 s window")
    require(not args.buddy_kernel or args.ipvlan_kernel, "supply the matched IPvlan parent for the buddy kernel")
    require(bool(args.mthp_kernel) == bool(args.mthp_64k) and
            (not args.mthp_kernel or (args.ipvlan_kernel and not args.buddy_kernel and args.builders == 8 and args.cpu_groups)),
            "64 KiB allocation qualification requires the matched THP and IPvlan Images with eight grouped builders")
    require(args.guest_fair != "bounded-buddy" or args.buddy_kernel, "the deadline bound requires the experimental kernel")
    require(not args.timer_counters or (args.dense_ms == 1500 and args.builders == 8 and args.pairs == 32
                                       and not args.trace_sockets), "timer counters need the full untraced CI workload")
    require(not args.trace_sockets or (args.layouts == ["same"] and args.pairs == 32 and args.builders == 8
                                      and args.dense_ms == 1500 and args.slice_us is None), "the named socket trace needs the full ordinary mixed workload")
    require(args.builder_shares is None or (args.layouts == ["same"] and args.pairs == 32 and args.builders == 8),
            "the CPU-weight comparison uses eight builders with 32 same-vCPU pairs")
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-sibling-"), dir=HERE))
    print(folder, flush=True)
    signal.signal(signal.SIGTERM, terminal.exit_on_signal)
    status = {"complete": False}
    try:
        with terminal.terminal_lock():
            study(folder, args)
        status["complete"] = True
    except BaseException as exc:
        status["error"] = str(exc) or type(exc).__name__
        raise
    finally:
        terminal.save(folder / "status.json", status)
