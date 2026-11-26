#!/usr/bin/env python3
"""Bounded published-loopback pilot for already-serving, owner-reserved Gamma fixtures."""

import argparse
import contextlib
import ctypes
import http.client
import importlib
import ipaddress
import json
import os
import platform
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from bench_docker_launch import cpu_idle
from gamma_path_study import (
    CLIENT,
    IMAGE,
    RELAY_REV,
    RUNTIME_REVS,
    STOCK_WINDOW_VERSION,
    disk_expiry,
    require,
    sha,
    stamp,
    stock_window,
    stock_worker,
    verify_stock_guest_inventory,
)
from kernel_path.verify_quota import verify as verify_quota

HERE = Path(__file__).resolve().parent / "kernel_path"
KERNEL = "7e3713940eec7466d1b47f959244534051b46ea70c50796e292a651112e8a0bd"
CONFIG = "a0da9a6ab98e69e253f2e8a27664bdb23f08ab4cef1dd66178c38c26d0035c9c"
STOCK = {"release": "7.3.5-micropod", "image_sha256": KERNEL, "config_sha256": CONFIG}
HOST = "Gamma-128GB.local"
GUEST = "Gamma-128GB Linux CI (isolated VM)"
POLICY = {"Congctl": "reno", "RtoMin": 20, "RtoMinLock": True, "QuickACK": 0, "MTU": 0}
FILES = {
    "gamma_pilot.py": "224ea2d4e2c1db4e8b4592c76a20dd6599c0e97324d55f82c195bbc2206dd0c3",
    "gamma_contrasts.py": "594c01b05cc9c57a0634cc03842045c69d4171f8053b1b0937ab19115e5f336e",
}


@contextlib.contextmanager
def helpers(checkout):
    # Isolate the two pinned pilot modules and the small path readback extension.
    with tempfile.TemporaryDirectory() as td:
        directory = Path(td) / "scripts/relaybench"
        directory.mkdir(parents=True)
        for name, expected in FILES.items():
            data = subprocess.check_output(
                ["git", "-C", checkout, "show", f"{RELAY_REV}:scripts/relaybench/{name}"]
            )
            require(sha(data) == expected, f"unexpected source for {name}")
            (directory / name).write_bytes(data)
        subprocess.run(["patch", "-s", "-p1", "-i", str(HERE / "inspect-path.patch")], cwd=td, check=True)
        sys.path.insert(0, str(directory))
        try:
            yield importlib.import_module("gamma_pilot")
        finally:
            sys.path.pop(0)
            for name in ("gamma_pilot", "gamma_contrasts"):
                sys.modules.pop(name, None)


def schedule(p, mode, baseline, seed):
    paths = {"A": baseline} if mode == "baseline" else {"A": "bridge", "B": "macvlan"}
    if mode in ("kernel", "policy"):
        paths = {"A": "macvlan", "B": "macvlan"}
    phases = {"warmup": ["A"], "scored": ["A"]} if mode == "baseline" else p.plan(seed)
    return {
        "mode": mode,
        **({"stock_window_version": STOCK_WINDOW_VERSION} if mode == "baseline" else {}),
        "paths": paths,
        "seed": seed,
        "order": phases,
        "offered_seconds": 6 * sum(len(order) for pairs in phases.values() for order in pairs),
        "vcpus": 4,
        "memory_mib": 4096,
        "image": IMAGE,
        "client_sha256": CLIENT,
        "source": RELAY_REV,
        "pilot_sha256": sha(Path(__file__).read_bytes()),
        "path_extension_sha256": sha((HERE / "inspect-path.patch").read_bytes()),
        "tools_sha256": p.HASHES,
    }


def admit(fleet, release, scopes, now, mode):
    # The fleet export is independently refreshed by the operator; a release alone cannot open the gate.
    require(0 <= now - stamp(fleet["generatedAt"]) <= 90, "stale fleet receipt")
    lanes = {}
    for name in (HOST, GUEST):
        found = [r for r in fleet["runners"] if r["runner"]["displayName"] == name]
        require(len(found) == 1, f"missing or ambiguous runner: {name}")
        raw = found[0]
        r = raw["runner"]
        require(
            raw["connection"] == "online" and r["active"] and r["activeLeases"] == 0,
            f"{name} offline or has active leases ({r['activeLeases']}/{r['capacity']})",
        )
        require(0 <= now - stamp(r["lastSeenAt"]) <= 90, f"stale {name} heartbeat")
        lanes[name] = {
            "lastSeenAt": r["lastSeenAt"],
            "activeLeases": r["activeLeases"],
            "capacity": r["capacity"],
        }
    scope_paths = [str(x.resolve()) for x in scopes]
    require(
        release["owner"].strip()
        and release["reservation"].strip()
        and release["host"] == HOST
        and release["exclusive"] is True
        and isinstance(release["modes"], list) and mode in release["modes"]
        and stamp(release["starts_at"]) <= now < stamp(release["expires_at"])
        and isinstance(release["scopes"], list) and set(scope_paths) <= set(release["scopes"]),
        "no matching live owner handoff",
    )
    require(lanes[GUEST]["capacity"] == 1, "isolated lane identity changed")
    observation = dict(fleet_time=fleet["generatedAt"], runners=lanes, reservation=release["reservation"])
    if mode == "baseline":
        disk_expiry(release.get("effective_disk_gate"), now)
        observation.update(owner=release["owner"], mode=mode, scopes=scope_paths,
                           starts_at=release["starts_at"], expires_at=release["expires_at"],
                           observed_at_epoch=now, effective_disk_gate=release["effective_disk_gate"])
    return observation


def read_json(path):
    return json.loads(path.read_text())


def live_attestation(p, fixture, build, kernel):
    pid = fixture["pids"]["relay"]
    buf = ctypes.create_string_buffer(4096)
    require(
        ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidpath(pid, buf, len(buf)) > 0, "cannot resolve supervisor"
    )
    with Path(os.fsdecode(buf.value)).open("rb") as file:
        st = os.fstat(file.fileno())
        mapped = p.command("lsof", "-nP", "-a", "-p", str(pid), "-d", "txt", "-FfDi")
        records = [
            dict((s[0], s[1:]) for s in v.splitlines() if s) for v in re.split(r"(?m)^f[^\n]*\n", mapped)[1:]
        ]
        require(
            any(
                "D" in v and "i" in v and (int(v["D"], 0), int(v["i"])) == (st.st_dev, st.st_ino)
                for v in records
            ),
            "live supervisor vnode differs",
        )
        worker_digest = sha(file.read())
        require(
            build["source_revision"] in RUNTIME_REVS
            and build["worker_executable_sha256"] == fixture["cli_sha256"] == worker_digest,
            "unverified revised relay",
        )
    kernel_digest = p.digest(Path(fixture["kernel"]))
    require(kernel_digest == kernel["image_sha256"], "different kernel image")
    return {
        "source_revision": build["source_revision"],
        "worker_executable_sha256": worker_digest,
        "mapped_device": st.st_dev,
        "mapped_inode": st.st_ino,
        "kernel_image_sha256": kernel_digest,
    }


def stock_session(root):
    session = read_json(root / "session.json")
    require(session["started"] and session["nativeOCI"], "stock session stopped")
    return {
        "worker": session["readySocket"]["worker"],
        "instance": session["instance"],
        "relay_pid": session["owner"]["pid"],
        "workers": session["publishedRelayWorkers"],
    }


def verify_stock_kernel(live, facts):
    # Older OCI services omit sched_ext. The stock config from the same boot
    # independently establishes that this kernel cannot load a sched_ext policy.
    verify_stock_guest_inventory(facts, {"boot": live.get("boot"), "release": STOCK["release"],
                                         "guest_config_sha256": STOCK["config_sha256"]})
    disabled = "# CONFIG_SCHED_CLASS_EXT is not set"
    flags = [line for line in facts.splitlines() if line == disabled or line.startswith("CONFIG_SCHED_CLASS_EXT=")]
    scheduler = live.get("sched_ext")
    require(flags == [disabled], "stock guest configuration must disable CONFIG_SCHED_CLASS_EXT")
    require(
        scheduler is None or isinstance(scheduler, dict) and scheduler.get("state") == "disabled",
        "live scheduler readback conflicts with the stock guest configuration",
    )


def kernel_facts(p, root, facts, kernel=STOCK, required_policy=None):
    live = json.loads(
        p.command(
            "curl",
            "--noproxy",
            "*",
            "-fsS",
            "--max-time",
            "3",
            "--unix-socket",
            str(root / "oci.sock"),
            "http://localhost/oci/v1/kernel",
        )
    )
    require(re.search(r"(?m)^virtio_nic=\S+$", facts), "missing guest virtio NIC")
    if kernel == STOCK:
        require(not required_policy, "stock kernel cannot qualify a sched_ext policy")
        verify_stock_kernel(live, facts)
    else:
        require(
            live.get("boot") and "boot=" + live["boot"] in facts.splitlines()
            and "release=" + kernel["release"] in facts.splitlines()
            and "machine=aarch64" in facts.splitlines()
            and "config_sha256=" + kernel["config_sha256"] in facts.splitlines(),
            "guest config/NIC receipt belongs to a different or unobserved boot",
        )
        need_flags = {
            "CONFIG_SCHED_CLASS_EXT=y",
            "CONFIG_CFS_BANDWIDTH=y",
            "CONFIG_EXT_GROUP_SCHED=y",
            "CONFIG_DEBUG_INFO_BTF=y",
        }
        scheduler = live.get("sched_ext")
        require(
            need_flags <= set(facts.splitlines()) and isinstance(scheduler, dict) and scheduler.get("state"),
            "candidate scheduler/cgroup config missing",
        )
        if required_policy:
            require(
                live["boot"] == required_policy[0] and scheduler == required_policy[1],
                "kernel boot or scheduler differs from measured quota qualification",
            )
        else:
            require(scheduler["state"] == "disabled", "candidate kernel needs its default fair policy")
    devices = re.split(r"(?m)^virtio_nic=(\S+)$", facts)
    for nic, detail in zip(devices[1::2], devices[2::2]):
        require(
            re.search(rf"(?m)^/sys/class/net/{re.escape(nic)}/queues/rx-[0-9]+$", detail)
            and re.search(rf"(?m)^/sys/class/net/{re.escape(nic)}/queues/tx-[0-9]+$", detail)
            and re.search(r"(?m)^tcp-segmentation-offload: (on|off)", detail)
            and re.search(r"(?m)^generic-receive-offload: (on|off)", detail),
            f"incomplete queue or offload readback for {nic}",
        )
    return live


def single_service(p, docker, cid):
    running = p.command(*docker, "ps", "--no-trunc", "-q").splitlines()
    require(running == [cid], "unexpected active service")
    return running[0]


def parse_service_ss(raw):
    """Read the one service-side TCP record selected by ss -Htin state established."""
    rows = [line for line in raw.splitlines() if line.strip()]
    require(len(rows) == 2 and rows[1][0].isspace(), "ss needs one socket row and its TCP_INFO detail")
    columns = rows[0].split()
    if columns[:1] in (["tcp"], ["tcp6"]):
        columns = columns[1:]
    if columns[:1] == ["ESTAB"]:
        columns = columns[1:]
    require(len(columns) == 4 and all(q.isdecimal() for q in columns[:2]), "invalid established ss socket row")

    def endpoint(field):
        address, sep, port = field.rpartition(":")
        require(sep and port.isdecimal() and 0 < int(port) <= 65535, "invalid ss endpoint port")
        if address.startswith("[") and address.endswith("]"):
            address = address[1:-1]
        ip = ipaddress.ip_address(address)
        return str(getattr(ip, "ipv4_mapped", None) or ip), int(port)

    local, peer = map(endpoint, columns[2:])
    require(local[1] == 8080, "ss socket does not belong to the accepted service port 8080")
    # iproute2 prints these negotiated options before the congestion-control name.
    flags = {"ts", "usec_ts", "sack", "ecn", "ecnseen", "fastopen"}
    controller = next((part for part in rows[1].split() if part not in flags), "")
    require(re.fullmatch(r"[a-zA-Z0-9_-]{1,15}", controller), "ss TCP_INFO has no congestion-controller name")
    return {"local": local, "peer": peer, "controller": controller}


def socket_proof(p, docker, fixture, ss, *, evidence_path=None):
    conn = http.client.HTTPConnection(fixture["address"], timeout=3)
    try:
        conn.request("GET", "/id")
        response = conn.getresponse()
        require(
            response.status == 200 and response.read() == fixture["name"].encode() and conn.sock is not None,
            "keepalive or identity proof failed",
        )
        raw = p.command(
            *docker, "exec", fixture["id"], ss, "-Htin", "state", "established", "( sport = :8080 )"
        )
        if evidence_path is not None:
            evidence_path.write_text(raw)
        controller = parse_service_ss(raw)["controller"]
        require(controller == "reno", f"accepted service socket uses {controller}, expected reno")
        return raw
    finally:
        conn.close()


def state(p, docker, cid):
    return json.loads(p.command(*docker, "exec", cid, "/mpcheck/check", "state"))["interfaces"]


def change(before, after, path):
    dev = "eth0" if path == "bridge" else "mppub0"
    delta = {
        name: {k: int(after[name][k]) - int(v[k]) for k in ("tx_bytes", "rx_bytes", "rx_dropped", "tx_dropped")}
        for name, v in before.items()
    }
    require(all(min(v.values()) >= 0 for v in delta.values()), "service counters reset")
    require(
        delta[dev]["tx_bytes"] > 0 and (path == "bridge" or delta[dev]["tx_bytes"] > delta["eth0"]["tx_bytes"]),
        "measured egress did not use declared path",
    )
    return delta


def comparable(a, b, mode):
    for k in ("boot", "engine", "instance", "worker", "address", "name", "id"):
        require(a[k] != b[k], f"arms share {k}")
    require(set(a["pids"].values()).isdisjoint(b["pids"].values()), "shared supervisor or VMM")
    for k in (
        "image_config",
        "cli_sha256",
        "engine_version",
        "cpuset",
        "route",
        "service_env_sha256",
        "docker_client_version",
    ):
        require(a[k] == b[k], f"arms differ in {k}")
    if mode == "kernel":
        require(a["kernel_sha256"] != b["kernel_sha256"], "kernel comparison reused one image")
    else:
        for key in ("release", "kernel_sha256", "guest_config_sha256"):
            require(a[key] == b[key], f"arms differ in {key}")


def checked_client(p, tools, fixture, birth, guard, row, *, stock=False):
    row["before"] = p.snapshot(tools, fixture)
    require(p.identities(row["before"]) == birth, "host process changed")
    if stock:
        current = guard()
        expires = min(disk_expiry(row["admission"]["effective_disk_gate"], time.time()),
                      disk_expiry(current["effective_disk_gate"], time.time()),
                      stamp(row["admission"]["expires_at"]))
        require(time.time() < expires, "stock reservation expired before client")
        client_start = time.time_ns()
    start = time.monotonic()
    with subprocess.Popen(
        [tools / "fixed", "http://" + fixture["address"], fixture["name"]],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    ) as child:
        try:
            while True:
                try:
                    wait = 1
                    if stock:
                        remaining = expires - time.time()
                        require(remaining > 0, "stock reservation or disk clearance expired during client")
                        wait = min(remaining, wait)
                    out, err = child.communicate(timeout=wait)
                    if stock:
                        require(time.time() < expires, "stock reservation or disk clearance expired during client")
                    break
                except subprocess.TimeoutExpired:
                    if stock:
                        require(time.time() < expires, "stock reservation or disk clearance expired during client")
                    current = guard()
                    if stock:
                        expires = min(expires, disk_expiry(current["effective_disk_gate"], time.time()))
                    require(time.monotonic() - start < 75, "fixed client timeout")
        finally:
            if child.poll() is None:
                child.kill()
            out, err = child.communicate()
            row.update(
                stdout=out, stderr=err, exit_code=child.returncode, client_wall_s=time.monotonic() - start
            )
            if stock:
                row["client_epoch_ns"] = [client_start, time.time_ns()]
    row["after"] = p.snapshot(tools, fixture)
    require(p.identities(row["after"]) == birth, "process changed during sample")
    c = json.loads(out)
    row["client"] = c
    errors = c.get("errors") or []
    if (
        len(c.get("per_stream_bytes", [])) == 32
        and min(c["per_stream_bytes"]) > 0
        and "errors" in c
        and all('/id"' in e for e in errors)
    ):
        row["fresh_failed"] = len(errors)
    if c.get("bytes", 0) > 0:
        row["host"] = {}
        for role, pid in fixture["pids"].items():
            d = p.process_delta(row["before"], row["after"], pid)
            row["host"][role] = {
                **d,
                **p.host_units(d, c["bytes"]),
                "cpu_ns_per_byte": d["cpu_s"] * 1e9 / c["bytes"],
            }
    require(child.returncode == 0 and p.clean_client(c), "fixed-client assertions failed")


def run(args, p, plan):
    args.out.mkdir()
    p.save(args.out / "plan.json", plan)
    scopes = {"A": args.a.resolve()}
    if args.mode != "baseline":
        scopes["B"] = args.b.resolve()

    initial = None
    def guard():
        current = admit(read_json(args.fleet), read_json(args.release), scopes.values(), time.time(), args.mode)
        if args.mode == "baseline" and initial is not None:
            require(all(current[k] == initial[k] for k in ("owner", "reservation", "mode", "scopes", "starts_at", "expires_at")),
                    "stock handoff changed")
        return current

    initial = guard()
    p.save(args.out / "admission.json", initial)
    require(platform.system() == "Darwin" and platform.node().split(".")[0] == "Gamma-128GB", "wrong host")
    for name, expected in p.HASHES.items():
        require(p.digest(args.tools / name) == expected, f"wrong {name} executable")
    kernels = {arm: STOCK for arm in scopes}
    policies = {arm: None for arm in scopes}
    if args.mode in ("kernel", "policy"):
        candidate = read_json(args.candidate)
        require(
            candidate["release"] == "7.3.5-micropod-scx"
            and candidate["image_sha256"] != KERNEL
            and candidate["config_sha256"] != CONFIG
            and all(re.fullmatch(r"[0-9a-f]{64}", candidate[k]) for k in ("image_sha256", "config_sha256")),
            "missing trusted full-scx Image/config identity",
        )
        kernels["B"] = candidate
        if args.mode == "policy":
            kernels["A"] = candidate
            q = verify_quota(args.quota_dir, current=True)
            for arm in scopes:
                key = "current-" + arm.lower()
                policies[arm] = (q["boots"][key], q["states"][key])
            p.save(args.out / "measured-quota.json", q)
    p.save(args.out / "kernel-builds.json", kernels)
    fixtures = {}
    dockers = {}
    roots = {}
    facts = {}
    births = {}
    stock = args.mode == "baseline"
    stock_build = read_json(args.build) if stock else None
    for arm, scope in scopes.items():
        guard()
        require(scope.is_dir() and not (scope / "removed").exists(), "scope retired")
        base = p.value(scope, "base")
        require(Path(base).name == base and base not in ("", ".", "..", "orb"), "unexpected worker scope")
        root = scope.parent.parent / base
        docker = ["docker", "--host", "unix://" + str(root / "docker.sock")]
        single_service(p, docker, p.value(scope, "id"))
        f = p.inspect(scope, 4, False, plan["paths"][arm], kernels[arm]["release"])
        require(f["cpuset"] == "0-3" and f["route"] == POLICY, "wrong quota, CPU set or route settings")
        mapped = live_attestation(p, f, stock_build if stock else read_json(args.build), kernels[arm])
        fp = args.facts_a if arm == "A" else args.facts_b
        inventory = fp.read_bytes()
        (args.out / f"guest-{arm}.txt").write_bytes(inventory)
        facts[arm] = "\n".join(inventory.decode("utf-8").splitlines())
        live = kernel_facts(p, root, facts[arm], kernels[arm], policies[arm])
        f.update(
            boot=live["boot"],
            kernel_sha256=kernels[arm]["image_sha256"],
            guest_config_sha256=re.search(r"(?m)^config_sha256=(\w+)$", facts[arm]).group(1),
            docker_client_version=p.command(*docker, "version", "--format", "{{.Client.Version}}"),
        )
        if stock:
            verify_stock_guest_inventory(facts[arm], f)
            f["guest_inventory_sha256"] = sha(inventory)
        raw = socket_proof(p, docker, f, args.ss, evidence_path=args.out / f"accepted-{arm}.ss.txt")
        p.save(args.out / f"accepted-{arm}.json", {"ss": raw, "route": f["route"]})
        births[arm] = p.identities(p.snapshot(args.tools, f))
        if stock:
            f["mapped_relay_build"] = mapped
            f["scope"] = str(scope)
            f["birth_ticks"] = {role: births[arm][pid] for role, pid in f["pids"].items()}
        fixtures[arm] = f
        dockers[arm] = docker
        roots[arm] = root
    if args.mode != "baseline":
        comparable(fixtures["A"], fixtures["B"], args.mode)
    p.save(args.out / "fixtures.json", fixtures)
    scored = {}
    idles = {}
    rows = []
    completion = {}
    for phase, groups in plan["order"].items():
        for n, order in enumerate(groups, 1):
            for arm in order:
                row = dict(phase=phase, block=n, arm=arm, started=False, clean=False, fresh_failed=None)
                f = fixtures[arm]
                try:
                    row["admission"] = guard()
                    for a, scope in scopes.items():
                        require(not (scope / "removed").exists(), "retired scope")
                        observed = single_service(p, dockers[a], fixtures[a]["id"])
                        if stock:
                            row["service_before"] = observed
                    row["kernel_before"] = kernel_facts(p, roots[arm], facts[arm], kernels[arm], policies[arm])
                    row["link_before"] = state(p, dockers[arm], f["id"])
                    if stock:
                        row["relay_before"] = stock_session(roots[arm])
                        require(
                            row["relay_before"] == stock_worker(f)
                            and row["kernel_before"]["boot"] == f["boot"],
                            "stock session or boot changed before client",
                        )
                    row["idle_pct"] = cpu_idle()
                    require(row["idle_pct"] >= 90, "unexpected host activity")
                    if (phase, n) in idles:
                        require(abs(row["idle_pct"] - idles[phase, n]) <= 5, "unmatched paired host idle")
                    idles[phase, n] = row["idle_pct"]
                    guard()
                    row["started"] = True
                    checked_client(p, args.tools, f, births[arm], guard, row, stock=stock)
                    closing = guard()
                    if stock:
                        row["admission_after"] = closing
                        disk_expiry(row["admission"]["effective_disk_gate"], closing["observed_at_epoch"])
                    observed = single_service(p, dockers[arm], f["id"])
                    if stock:
                        row["service_after"] = observed
                    row["kernel_after"] = kernel_facts(p, roots[arm], facts[arm], kernels[arm], policies[arm])
                    row["link_after"] = state(p, dockers[arm], f["id"])
                    if stock:
                        row["relay_after"] = stock_session(roots[arm])
                    row["link_delta"] = change(row["link_before"], row["link_after"], plan["paths"][arm])
                    require(
                        all(d["rx_dropped"] == d["tx_dropped"] == 0 for d in row["link_delta"].values()),
                        "link drops",
                    )
                    row["clean"] = True
                    if stock:
                        proof = stock_window(plan, f, row, rows[0] if phase == "scored" else None, initial)
                        if phase == "scored":
                            completion["stock_window"] = proof
                    if phase == "scored":
                        scored[n, arm] = row["client"]["mib_s"]
                except Exception as error:
                    row["clean"] = False
                    row["error"] = str(error)
                    raise
                finally:
                    p.save(args.out / f"{phase}-{n}-{arm}.json", row)
                    rows.append(row)
    for a, scope in scopes.items():
        guard()
        recheck = p.inspect(scope, 4, False, plan["paths"][a], kernels[a]["release"])
        require(all(recheck[k] == fixtures[a][k] for k in recheck), "service identity changed")
        mapped = live_attestation(p, recheck, stock_build if stock else read_json(args.build), kernels[a])
        if stock:
            require(mapped == fixtures[a]["mapped_relay_build"], "stock mapped relay changed before completion")
    ratios = (
        [scored[n, "B"] / scored[n, "A"] for n in range(1, len(plan["order"]["scored"]) + 1)]
        if args.mode != "baseline"
        else []
    )
    p.save(
        args.out / "complete.json",
        dict(
            attempts=len(rows),
            clean=sum(r["clean"] for r in rows),
            ratio_direction={
                "path": "direct / bridge",
                "kernel": "candidate fair / stock fair",
                "policy": "bpfland / candidate fair",
                "baseline": None,
            }[args.mode],
            paired_ratios=ratios,
            median_ratio=statistics.median(ratios) if ratios else None,
            **completion,
        ),
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=["baseline", "path", "kernel", "policy"])
    ap.add_argument("--relay-checkout", type=Path, required=True)
    ap.add_argument("--baseline-path", choices=["bridge", "macvlan"], default="macvlan")
    ap.add_argument("--seed", type=int, default=34199)
    ap.add_argument("--run", action="store_true")
    for flag in ("a", "b", "facts-a", "facts-b", "fleet", "release", "build", "tools", "out"):
        ap.add_argument("--" + flag, type=Path)
    ap.add_argument("--candidate", type=Path, help="trusted full-scx build manifest")
    ap.add_argument("--quota-dir", type=Path, help="verified bpfland fallback and current-arm quota receipts")
    ap.add_argument("--ss", default="ss", help="existing iproute2 ss executable inside the disposable service")
    args = ap.parse_args()
    with helpers(args.relay_checkout) as pilot:
        plan = schedule(pilot, args.mode, args.baseline_path, args.seed)
        if not args.run:
            print(json.dumps(plan, indent=2))
            return
        if not all([args.a, args.facts_a, args.fleet, args.release, args.build, args.tools, args.out]) or (
            args.mode != "baseline" and not (args.b and args.facts_b)
        ):
            ap.error(
                "run requires scope, guest facts, fleet export, owner release, source build receipt, tools and new output"
            )
        if (
            args.mode in ("kernel", "policy")
            and not args.candidate
            or args.mode == "policy"
            and not args.quota_dir
        ):
            ap.error("kernel comparison needs the trusted candidate manifest; policy also needs quota receipts")
        try:
            run(args, pilot, plan)
        except Exception as error:
            if (
                args.out.is_dir()
                and (args.out / "plan.json").is_file()
                and not isinstance(error, FileExistsError)
            ):
                pilot.save(args.out / "stop.json", {"error": str(error), "complete": False})
            ap.exit(1, f"Stopped: {error}\n")


if __name__ == "__main__":
    main()
