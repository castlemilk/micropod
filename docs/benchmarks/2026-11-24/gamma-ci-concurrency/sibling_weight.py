"""Verify Docker CPU shares on a single busy guest vCPU with 64 resident containers."""
import json
import ipaddress
import shutil
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from qualify import HERE, require, terminal


def stage(folder, probe, product, env):
    source = HERE / "sibling_weight_linux.go"
    terminal.invoke("go", "build", "-trimpath", "-o", probe / "cpu-weight", source, env=env)
    runner = product.resolve().parent / "src/guest/runner"
    terminal.invoke("go", "-C", runner, "test", "-c", "-trimpath", "-o", probe / "runner.test", ".",
                    timeout=240, env={**env, "GOPROXY": "off"})
    shutil.copy2(source, folder / source.name)
    shutil.copy2(__file__, folder / "weight-driver.py")
    return {"weight_source_sha256": terminal.digest(source), "weight_probe_sha256": terminal.digest(probe / "cpu-weight"),
            "weight_driver_sha256": terminal.digest(Path(__file__)), "runner_test_sha256": terminal.digest(probe / "runner.test")}


def wave(cohort, name, clients):
    gate = cohort.work / "gate"
    def run(i):
        return json.loads(cohort.cmd("exec", clients[i]["id"], "/mpcheck/cpu-weight",
                                     "-ready", f"/gate/{name}.{i}", "-start", f"/gate/{name}"))
    with ThreadPoolExecutor(max_workers=len(clients)) as pool:
        tasks = [pool.submit(run, i) for i in range(len(clients))]
        paths = [gate / f"{name}.{i}" for i in range(len(clients))]
        until = time.monotonic() + 9
        while not all(p.exists() and p.stat().st_size for p in paths):
            require(time.monotonic() < until and not any(f.done() for f in tasks), "CPU probes did not reach gate")
            time.sleep(.01)
        deadline = max(int(p.read_text()) for p in paths) + 200_000_000
        tmp = gate / (name + ".tmp")
        tmp.write_text(str(deadline))
        tmp.replace(gate / name)
        return [f.result() for f in tasks]


def check(rows, clients):
    require(len(rows) == len(clients) and len({r["scheduled_ns"] for r in rows}) == 1, "wrong CPU probe count or gate")
    for r, c in zip(rows, clients):
        require(r["weight"] == c["weight"] and r["rounds"] > 0 and r["cpu_ns"] > 0
                and 0 <= r["started_ns"] - r["scheduled_ns"] < 100_000_000
                and r["finished_ns"] - r["scheduled_ns"] >= 1_200_000_000, "unverified CPU probe interval")
    elapsed = max(r["finished_ns"] for r in rows) - min(r["started_ns"] for r in rows)
    used = sum(r["cpu_ns"] for r in rows)
    delivered = rows[0]["cpu_ns"] / used
    expected = clients[0]["weight"] / sum(c["weight"] for c in clients)
    require(.80 < used / elapsed < 1.03 and abs(delivered - expected) < .095,
            f"CPU allocation differs from the requested weights: {delivered:.3f} vs {expected:.3f}, use {used / elapsed:.3f}")
    return {"cpu_utilization": used / elapsed, "first_cpu_fraction": delivered, "expected_fraction": expected}


def qualify(cohort, folder):
    first, peer = cohort.jobs[cohort.count], cohort.jobs[cohort.count + 8]
    require(first["mask"] == peer["mask"] == "0" and cohort.cmd("info", "--format", "{{.CPUShares}}") == "true",
            "Docker CPU shares or single-vCPU placement unavailable")
    if cohort.arm == "A":
        log = cohort.cmd("exec", first["id"], "/mpcheck/runner.test", "-test.v",
                         "-test.run", "^TestDockerCPU(Shares|SetWithinAllocation|QuotaPreservesDefaultsAndExplicitLimits)$")
        require(log.endswith("PASS") and "--- PASS: TestDockerCPUShares" in log, "Linux runner tests failed")
        (folder / "linux-weight-tests.txt").write_text(log + "\n")
    cohort.cmd("stop", "-t", "1", first["id"])
    cohort.cmd("start", first["id"])
    conf, = json.loads(cohort.cmd("inspect", first["id"]))
    live = json.loads(cohort.cmd("exec", first["id"], "/mpcheck/cpu-weight"))
    link = conf["NetworkSettings"]["Networks"][cohort.network]
    require(conf["Id"] == first["id"] and conf["State"]["Running"]
            and (conf["HostConfig"].get("CpuShares") or 0) == cohort.builder_shares
            and link["NetworkID"] == cohort.net_id and ipaddress.IPv4Address(link["IPAddress"]).is_private
            and live["weight"] == first["weight"], "weight or service identity changed on restart")
    first["ip"] = link["IPAddress"]
    require(len({j["ip"] for j in cohort.jobs}) == len(cohort.jobs), "duplicate IP after restart")
    # A restart may replace the backing cgroup. Begin the later CPU counters at this incarnation.
    first["cgroup"] = json.loads(cohort.cmd("exec", first["id"], "/mpcheck/netbench", "-cgroup-info"))
    cases = []
    for label, clients in (("solo", [first]), ("paired", [first, peer]), ("reversed", [peer, first])):
        raw = wave(cohort, f"weight-{cohort.arm}-{label}", clients)
        case = {"case": label, "ids": [j["id"] for j in clients], "raw": raw}
        cases.append(case)
        terminal.save(folder / ("cpu-weight-" + cohort.arm + ".json"), cases)
        case["summary"] = check(raw, clients)
    terminal.save(folder / ("cpu-weight-" + cohort.arm + ".json"), cases)
