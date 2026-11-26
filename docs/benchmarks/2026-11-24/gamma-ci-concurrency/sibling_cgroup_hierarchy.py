"""Read the CPU cgroup hierarchy of 32 labelled CI jobs on a private native worker."""

import argparse
import json
import os
import re
import shutil
import signal
import tempfile
import time
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from unittest.mock import patch

import build_ipvlan
import private_link
import sibling_ci
import sibling_compiler_runtime as compiler_runtime
import sibling_group
import sibling_sched
from qualify import CONFIG, HERE, IMAGE, ROOT, Admission, check_baseline, ci_image_identity, cli, peer, require, terminal
from sibling_ext4_cache import reserve_in_order

ASSETS = Path(__file__).resolve().parent
COUNT = 32
BUILDERS = 8
SCHEDULER = "hrtick-250us"
BASE_NS = 250_000
LONG_NS = 2_100_000
PROBE = "/mpcheck/cgroup-hierarchy"
SOURCE = "sibling_cgroup_hierarchy_linux.go"
DRIVER = "sibling_cgroup_hierarchy.py"
HOOK = "cgroup-hierarchy-boot.sh"
STOCK = "cgroup-hierarchy-stock.sh"
BOOT_HOOK = r'''
(
    set -eu
    d="$MICROPOD_ENGINE_WORKSPACE/cgroup-hierarchy"
    tries=0
    while [ ! -f "$d/request.json" ]; do
        tries=$((tries+1))
        [ "$tries" -lt 300 ] || exit 75
        sleep 1
    done
    code=0
    "$MICROPOD_ENGINE_WORKSPACE/probe/cgroup-hierarchy" tree "$d/request.json" \
        >"$d/tree.tmp" 2>"$d/stderr" || code=$?
    mv "$d/tree.tmp" "$d/tree.json"
    printf '%s\n' "$code" >"$d/status.tmp"
    mv "$d/status.tmp" "$d/status"
) </dev/null >/dev/null 2>&1 &
'''

STOCK_CHECK = r'''
set -eu
probe=$1
resident=$2
launcher=$3
observe() { printf '%s\t' "$1"; "$probe" scheduler "$2"; }
observe shell_before "$$"
observe resident_before "$resident"
printf 'launcher_sha256\t%s\n' "$(sha256sum "$launcher" | awk '{print $1}')"
chrt=$(command -v chrt || :)
setpriv=$(command -v setpriv || :)
printf 'chrt_path\t%s\nsetpriv_path\t%s\n' "$chrt" "$setpriv"
if [ -n "$chrt" ]; then
    printf 'chrt_version\t%s\n' "$("$chrt" --version | head -n 1)"
fi
if [ -n "$setpriv" ]; then
    printf 'setpriv_version\t%s\n' "$("$setpriv" --version | head -n 1)"
fi
if [ -n "$setpriv" ]; then
    unprivileged() { "$setpriv" --no-new-privs --reuid 65534 --regid 65534 --clear-groups -- "$@"; }
    result=0
    control=$(unprivileged "$probe" scheduler self) || result=$?
    printf 'control_exit\t%s\n' "$result"
    if [ "$result" -eq 0 ]; then
        printf 'control\t%s\n' "$control"
        if [ -n "$chrt" ]; then
            applied=$(unprivileged "$chrt" -o -T 2100000 0 "$probe" scheduler self) || result=$?
            printf 'chrt_exit\t%s\n' "$result"
            if [ "$result" -eq 0 ]; then printf 'chrt\t%s\n' "$applied"; fi
        fi
        result=0
        applied=$(unprivileged "$launcher" -policy normal -build-slice-us 2100 /bin/sh -ec '
            printf "launcher\t"; "$1" scheduler "$$"
            printf "launcher_child\t"; "$1" scheduler self
            :
        ' child "$probe") || result=$?
        printf 'launcher_exit\t%s\n' "$result"
        if [ "$result" -eq 0 ]; then printf '%s\n' "$applied"; fi
    fi
fi
observe shell_after "$$"
observe resident_after "$resident"
'''


def parent_paths(path):
    p = PurePosixPath(path)
    require(p.is_absolute() and p.anchor == "/" and p.as_posix() == path and ".." not in p.parts
            and path != "/", f"invalid container cgroup path {path!r}")
    return [str(ancestor) for ancestor in p.parents]


def check_topology(inventory, requests, tree, boot):
    jobs = inventory["jobs"]
    ids = [job["id"] for job in jobs]
    require(len(ids) == len(set(ids)) == 2 * COUNT and [row["id"] for row in requests] == ids
            and tree["boot"] == boot and set(tree["memberships"]) == set(ids), "incomplete cohort or wrong boot")
    observer = tree["observer"]
    mount, fs = observer["mountinfo"].split(" - ")
    require(observer["self_cgroup_namespace"] == observer["init_cgroup_namespace"]
            and re.fullmatch(r"cgroup:\[[1-9][0-9]*\]", observer["self_cgroup_namespace"])
            and mount.split()[3:5] == ["/", "/sys/fs/cgroup"] and fs.split()[0] == "cgroup2",
            "trusted observation lacks the initial cgroup namespace and root mount")
    nodes = tree["groups"]
    descendants = defaultdict(set)
    ancestors = {}
    inodes, host_pids, leaves = set(), set(), set()
    for job, request in zip(jobs, requests, strict=True):
        cid = job["id"]
        row, leaf = tree["memberships"][cid], request["leaf"]
        path, worker, local = row["path"], row["resident"], leaf["resident"]
        up = parent_paths(path)
        group = nodes[path]
        require(row["id"] == cid and leaf["boot"] == boot
                and leaf["inode"] == group["inode"] > 0 and group["inode"] not in inodes
                and path not in leaves and worker["pid"] > 0 and worker["pid"] not in host_pids
                and worker["birth_ticks"] == local["birth_ticks"] > 0
                and worker["pid_namespace"] == local["pid_namespace"]
                and re.fullmatch(r"pid:\[[1-9][0-9]*\]", worker["pid_namespace"])
                and local["pid"] == job["affinity"]["pid"]
                and worker["argv"] == local["argv"] == job["affinity"]["argv"]
                and local["cgroup"] == "0::/" and worker["cgroup"] == "0::" + path,
                f"resident process and cgroup evidence disagree for {job['name']}")
        files = group["files"]
        require(group["children"] == 0 and "populated 1" in files["cgroup.events"].splitlines()
                and files["cgroup.type"] == "domain" and "cpu" in files["cgroup.controllers"].split()
                and 1 <= int(files["cpu.weight"]) <= 10_000
                and all(files[k] == job["cgroup"][k] for k in
                        ("cpu.max", "cpuset.cpus.effective", "memory.max", "pids.max")),
                f"worker leaf control state differs for {job['name']}")
        inodes.add(group["inode"])
        host_pids.add(worker["pid"])
        leaves.add(path)
        ancestors[cid] = up
        for ancestor in up:
            descendants[ancestor].add(cid)
        require("cpu" in nodes[up[0]]["files"]["cgroup.subtree_control"].split(),
                f"CPU controller is disabled at {up[0]}")
    require(set(nodes) == leaves | set(descendants), "snapshot included out-of-scope cgroups")

    pairs = []
    for i, (server, client) in enumerate(zip(jobs[:COUNT], jobs[COUNT:], strict=True)):
        dependency, issuer = server["id"], client["id"]
        group = sibling_group.group_name(i)
        home = str(i % 4)
        require(server["cpu_group"] == client["cpu_group"] == group and server["mask"] == client["mask"] == home
                and server["placement_source"] == client["placement_source"] == "native-group",
                f"wrong automatic placement for {group}")
        common = next(p for p in ancestors[dependency] if p in ancestors[issuer]
                      and "cpu" in nodes[p]["files"]["cgroup.subtree_control"].split())
        pairs.append({"group": group, "home_cpu": home, "builder": i < BUILDERS,
                      "dependency": dependency, "client": issuer, "common_cpu_parent": common,
                      "direct_parents": [ancestors[dependency][0], ancestors[issuer][0]],
                      "parent_measured_leaves": len(descendants[common]),
                      "separate_pair_parent_in_cohort": descendants[common] == {dependency, issuer}})
    return {"boot": boot, "pairs": pairs, "measured_leaves": len(leaves),
            "common_cpu_parents": sorted({pair["common_cpu_parent"] for pair in pairs}),
            "separate_pair_parents": sum(pair["separate_pair_parent_in_cohort"] for pair in pairs)}


def check_stock(raw, job, leaf, expected_sha):
    items = [line.split("\t", 1) for line in raw.splitlines()]
    fields = dict(items)
    require(len(fields) == len(items) and fields["launcher_sha256"] == expected_sha, "unexpected stock proof or launcher binary")
    boot, ino = leaf["boot"], leaf["inode"]

    def observation(key):
        value = json.loads(fields[key])
        require(value["boot"] == boot and value["inode"] == ino and value["cpu.max"] == job["cgroup"]["cpu.max"]
                and value["policy"] == value["nice"] == value["priority"] == 0
                and value["process"]["cgroup"] == "0::/" and value["status"]["Cpus_allowed_list"] == job["mask"],
                f"stock chrt readback changed container resources for {key}")
        return value

    for name in ("shell", "resident"):
        before, after = (observation(f"{name}_{phase}") for phase in ("before", "after"))
        require(before == after and before["slice_ns"] == BASE_NS, f"{name} changed after the child exited")
        if name == "resident":
            require(before["process"] == leaf["resident"], "stock chrt read the wrong workload process")
    tools = {name: {"path": fields[f"{name}_path"], "version": fields.get(f"{name}_version")}
             for name in ("chrt", "setpriv")}
    require(all(not v["path"] or v["path"].startswith("/") and v["version"] for v in tools.values()),
            "stock tool identity is incomplete")
    result = {"tools": tools, "stock": {"status": "missing-tool"},
              "launcher": {"status": "setpriv-missing", "sha256": expected_sha}}

    def ordinary(value):
        state = value["status"]
        require(state["Uid"] == "65534 65534 65534 65534" and state["NoNewPrivs"] == "1"
                and all(int(state[key], 16) == 0 for key in ("CapEff", "CapPrm", "CapAmb")),
                "stock tool command retained privileges")

    if tools["setpriv"]["path"]:
        result["control_exit"] = int(fields["control_exit"])
        result["launcher"]["status"] = "setpriv-rejected"
        if tools["chrt"]["path"]:
            result["stock"]["status"] = "setpriv-rejected"
        if result["control_exit"] == 0:
            control = observation("control")
            ordinary(control)
            require(control["slice_ns"] == BASE_NS, "ordinary control lacks the stock slice")
            for tool, key in (("chrt", "stock"), ("launcher", "launcher")):
                if tool == "chrt" and not tools[tool]["path"]:
                    continue
                proof = result[key]
                proof["exit"] = int(fields[f"{tool}_exit"])
                proof["status"] = "rejected"
                if proof["exit"]:
                    continue
                applied = observation(tool)
                ordinary(applied)
                proof["slice_ns"] = applied["slice_ns"]
                proof["status"] = "verified" if applied["slice_ns"] == LONG_NS else "slice-not-applied"
                if tool == "launcher":
                    child = observation("launcher_child")
                    ordinary(child)
                    require(int(child["status"]["PPid"]) == applied["process"]["pid"]
                            and child["process"]["pid"] != applied["process"]["pid"]
                            and child["slice_ns"] == applied["slice_ns"], "launcher child did not inherit its shell slice")
                    proof["child_slice_ns"] = child["slice_ns"]
    return result


def observe(folder, cohort, inventory, boot, runner):
    directory = cohort.work / "cgroup-hierarchy"
    jobs = inventory["jobs"]
    def one(job):
        return {"id": job["id"], "leaf": json.loads(cohort.cmd("exec", job["id"], PROBE, "leaf",
                                                               job["affinity"]["pid"], timeout=15))}
    requests = sibling_ci.parallel(8, one, jobs)
    terminal.save(folder / "cgroup-hierarchy-containers.json", requests)
    terminal.save(directory / "request.json", requests)
    deadline = time.monotonic() + 25
    while not (directory / "status").exists() and time.monotonic() < deadline:
        runner.guard()
        time.sleep(.25)
    for name in ("tree.json", "stderr", "status"):
        if (directory / name).is_file():
            shutil.copyfile(directory / name, folder / f"cgroup-hierarchy-{name}")
    require((directory / "status").is_file() and (directory / "status").read_text().strip() == "0",
            "guest hierarchy readback failed or timed out")
    rows = json.loads(cohort.cmd("inspect", *(job["id"] for job in jobs), timeout=20))
    starts = [{"id": row["Id"], "running": row["State"]["Running"], "started": row["State"]["StartedAt"]} for row in rows]
    require(starts == [{"id": job["id"], "running": True, "started": job["docker_inspect"]["State"]["StartedAt"]}
                       for job in jobs], "cohort changed while reading its cgroups")
    terminal.save(folder / "cgroup-hierarchy-starts.json", starts)
    return check_topology(inventory, requests, json.loads((directory / "tree.json").read_bytes()), boot), requests


def load_go(folder, runner, engine, archive):
    if archive is None:
        archive = runner.root / "go.tar"
        cli(peer.DOCKER, "image", "save", "-o", archive, IMAGE, timeout=240)
    expected = ci_image_identity(archive)
    runner.waited([*engine, "load", "-i", archive], "go-image", 360)
    row, = json.loads(cli(engine, "image", "inspect", IMAGE))
    require(row["Id"] == "sha256:" + CONFIG and row["Architecture"] == "arm64" and row["Os"] == "linux",
            "unexpected native Go image")
    terminal.save(folder / "go-image.json", {"expected": expected, "inspected": {"A": row}})


def stage_launcher(folder, work, receipt):
    manifest = json.loads(receipt.read_bytes())
    proof = (HERE / manifest["measured_archive"]).resolve()
    require(proof.parent == HERE, "compiler runtime archive lies outside the benchmark directory")
    plan = json.loads((proof / "plan.json").read_bytes())
    status = json.loads((proof / "status.json").read_bytes())
    require(plan["compiler_runtime"] == "long" and status["complete"] is True,
            "ordinary-user fallback needs a completed compiler runtime treatment")
    source = proof / compiler_runtime.SOURCE
    archived = folder / source.name
    expected_source = plan["compiler_runtime_source_sha256"]
    expected_binary = plan["compiler_runtime_probe_sha256"]
    require((ROOT / manifest["source"]).resolve() == source and
            terminal.digest(source) == manifest["source_sha256"] == expected_source
            and manifest["command_arguments"][:4] == ["-policy", "normal", "-build-slice-us", "2100"],
            "archived compiler runtime source or arguments changed")
    shutil.copy2(source, archived)
    binary = work / "probe" / Path(compiler_runtime.PROBE).name
    shutil.copy2(Path(manifest["binary"]), binary)
    require(terminal.digest(binary) == manifest["sha256"] == expected_binary,
            "compiler runtime binary differs from the measured treatment")
    shutil.copyfile(receipt, folder / "compiler-runtime-launcher.json")
    return {"proof": str(proof), "source_sha256": expected_source, "binary_sha256": expected_binary}


def study(folder, args):
    opts = terminal.parse_options(["--mode", "host-role", "--socket-evidence", "route", "--run"])
    files = terminal.fixture_files(opts)
    product = private_link.select(files, args.product)
    pages = build_ipvlan.select(args.ipvlan_kernel, args.page_kernel_pair, files, folder)
    terminal.check_archives(files)
    terminal.verify_cache()
    admission = Admission(folder)
    runner = terminal.Run(opts, folder, admission)
    admission.owner = runner.root.name
    try:
        work, oci, _ = terminal.stage(runner.root, files)
        (work / "gate").mkdir(mode=0o777)
        (work / "gate").chmod(0o777)
        (work / "cgroup-hierarchy").mkdir(mode=0o700)
        (work / "probe").chmod(0o755)
        shutil.copy2(files["role_probe"], work / "probe/netbench")
        env = {**os.environ, "CGO_ENABLED": "0", "GOOS": "linux", "GOARCH": "arm64", "GOPROXY": "off"}
        targets = {SOURCE: "cgroup-hierarchy", "sibling_group_affinity_linux.go": "group-affinity",
                   "sibling_link_linux.go": "guest-link"}
        digests = {}
        for source, target in targets.items():
            archived, binary = folder / source, work / "probe" / target
            shutil.copy2(ASSETS / source, archived)
            terminal.invoke("go", "-C", ROOT / "guest/runner", "build", "-trimpath", "-buildvcs=false",
                            "-o", binary, archived, timeout=90, env=env)
            digests[source] = terminal.digest(archived)
            digests[target] = terminal.digest(binary)
        (folder / HOOK).write_text(BOOT_HOOK)
        (folder / STOCK).write_text(STOCK_CHECK)
        shutil.copy2(Path(__file__), folder / DRIVER)
        with (oci / "runner/fixture-facts.sh").open("a") as hook:
            hook.write(BOOT_HOOK)
        sibling_sched.stage(oci, folder, "inherit")
        launcher = stage_launcher(folder, work, args.launcher_receipt)
        for name in (HOOK, STOCK, DRIVER):
            digests[name] = terminal.digest(folder / name)
        terminal.save(folder / "worker-build.json", product)
        terminal.save(folder / "plan.json", {"scope": str(runner.root), "pairs": COUNT, "builders": BUILDERS,
                                             "pages": pages, "scheduler": SCHEDULER, "next_buddy": True,
                                             "network_topology": "per-job", "build_scratch": "tmpfs",
                                             "digests": digests, "launcher": launcher, "baseline_files": check_baseline()})
        scope, facts = runner.arm("a", 4, files, work, oci, process_type="Standard", publication_mtu=9000,
                                  product_mtu=True, relay_mode="kqueue-throughput", published_rps=True,
                                  ci_scheduler=SCHEDULER, ci_next_buddy=True)
        guest = facts.read_text().splitlines()
        boot, = [line.removeprefix("boot=") for line in guest if line.startswith("boot=")]
        require("config_sha256=" + pages["kernel_config_sha256"] in guest and "CONFIG_FAIR_GROUP_SCHED=y" in guest,
                "unexpected worker kernel or group scheduler")
        sibling_sched.verify(work, folder, "inherit", SCHEDULER, True)
        worker, engine = private_link.service_preflight.identity(scope, product, 9000)
        terminal.save(folder / "worker-identity.json", worker)
        load_go(folder, runner, engine, args.image_archive)
        cli(engine, "rm", "-f", worker["container"])
        runner.arms[0]["cid"] = None
        require(not cli(engine, "ps", "-aq"), "private worker already has a workload")
        cohort = sibling_ci.Siblings(engine, "A", runner.root.name, work, admission, "grouped", COUNT, None,
                                     BUILDERS, 0, None, False, "all", network_driver="ipvlan",
                                     network_topology="per-job", build_scratch="tmpfs")
        parallel = sibling_ci.parallel
        try:
            with patch.object(sibling_ci, "parallel", lambda *a: reserve_in_order(parallel, *a)):
                inventory = cohort.create()
            terminal.save(folder / "grouped-inventory.json", {"A": inventory})
            summary, requests = observe(folder, cohort, inventory, boot, runner)
            terminal.save(folder / "cgroup-hierarchy.json", summary)
            job = cohort.jobs[COUNT]
            argv = ("exec", job["id"], "/bin/sh", "-ec", STOCK_CHECK, "stock-check", PROBE,
                    job["affinity"]["pid"], compiler_runtime.PROBE)
            execution = terminal.invoke(*engine, *argv, check=False, timeout=25)
            stock = {"id": job["id"], "argv": argv, "code": execution.returncode, "stdout": execution.stdout,
                     "stderr": execution.stderr}
            terminal.save(folder / "cgroup-hierarchy-stock.json", stock)
            require(execution.returncode == 0, "stock tool readback could not observe the default processes")
            stock.update(check_stock(execution.stdout, job, requests[COUNT]["leaf"], launcher["binary_sha256"]))
            terminal.save(folder / "cgroup-hierarchy-stock.json", stock)
        finally:
            cohort.clean()
    finally:
        runner.tearing_down = True
        runner.cleanup()
        terminal.save(folder / "verification.json", {"baseline_files": check_baseline(), "extra_cleanup_errors": runner.errors})
        require(not runner.root.exists() and not runner.errors, "private worker cleanup incomplete")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("product", "ipvlan-kernel", "page-kernel-pair", "launcher-receipt"):
        parser.add_argument("--" + name, required=True, type=lambda p: Path(p).resolve())
    parser.add_argument("--image-archive", type=lambda p: Path(p).resolve())
    args = parser.parse_args()
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-sibling-cgroup-"), dir=HERE))
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


if __name__ == "__main__":
    main()
