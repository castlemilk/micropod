#!/usr/bin/env python3
"""Measure Git, Go build and native engine tests on a vendored runner checkout."""
import argparse
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from uuid import uuid4

import bench_workspace_checkout as bench


TESTS = ("TestDockerInfoAdvertisesRestartCapability", "TestDockerInfoAttestsTheEffectiveWorkspace",
         "TestDockerEventMobyExecActionsAndFilters")
PACKAGE = "github.com/castlemilk/micropod/guest/runner"
MESSAGE = "expected one job request"
BUNDLE_NAME = "runner.bundle"
DRIVER_NAMES = ("driver.py", "bench_workspace_checkout.py")


def inventory(source):
    digest = hashlib.sha256()
    count = size = 0
    for file in sorted(source.rglob("*")):
        path = file.relative_to(source)
        if path.parts[0] == ".git" or not file.is_file():
            continue
        data = file.read_bytes()
        digest.update(os.fsencode(path) + b"\0" + hashlib.sha256(data).digest())
        count += 1
        size += len(data)
    return {"files": count, "bytes": size, "tree_sha256": digest.hexdigest()}


def prepare_checkout(stage, source):
    tree = stage / "source"
    shutil.copytree(source, tree, ignore=shutil.ignore_patterns(".git", "__pycache__"))
    if not (tree / "vendor/modules.txt").is_file():
        env = {**os.environ, "GOWORK": "off"}
        bench.call(["go", "mod", "vendor"], cwd=tree, env=env, timeout=180)
    env = bench.git_env() | {
        "GIT_AUTHOR_NAME": "Micropod CI", "GIT_COMMITTER_NAME": "Micropod CI",
        "GIT_AUTHOR_EMAIL": "ci@example.invalid", "GIT_COMMITTER_EMAIL": "ci@example.invalid",
        "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
    }
    bench.git(["init", "--quiet", "--template=", "--object-format=sha1", "--initial-branch=main"], tree, env)
    bench.git(["add", "-f", "."], tree, env)
    bench.git(["-c", "commit.gpgSign=false", "commit", "--quiet", "-m", "Native runner and Go dependencies"], tree, env)
    shutil.copy2(Path(__file__), stage / "driver.py")
    shutil.copy2(Path(bench.__file__), stage / "bench_workspace_checkout.py")
    return tree, bench.git(["rev-parse", "HEAD"], tree, env).decode().strip()


def prepare_bundle(stage, source):
    payload = stage / "job-payload"
    payload.mkdir()
    bundle = payload / BUNDLE_NAME
    started = time.monotonic_ns()
    bench.git(["bundle", "create", str(bundle), "refs/heads/main"], source, bench.git_env())
    pack_ns = time.monotonic_ns() - started
    for name in DRIVER_NAMES:
        shutil.copy2(stage / name, payload / name)
    return payload, {"bundle_pack_ns": pack_ns, "bundle_sha256": bench.file_sha(bundle),
                     "bundle_bytes": bundle.stat().st_size,
                     "payload_bytes": sum(path.stat().st_size for path in payload.iterdir())}


def guest_prepare(cpus, memory, *, job_local=False):
    restore = {}
    if job_local:
        bundle = bench.GUEST_ROOT / BUNDLE_NAME
        restore = {"bundle_sha256": bench.file_sha(bundle), "bundle_bytes": bundle.stat().st_size}
        started = time.monotonic_ns()
        bench.git(["clone", "--quiet", "--branch", "main", "--", bundle, bench.GUEST_SOURCE],
                  bench.GUEST_ROOT, bench.git_env())
        restore["clone_ns"] = time.monotonic_ns() - started
    result = bench.guest_prepare(cpus, memory, job_local=job_local)
    if job_local:
        paths = (bench.GUEST_SOURCE, bench.GUEST_BUILD_CACHE, bench.GUEST_MODULE_CACHE)
        device = Path("/").stat().st_dev
        bench.require(all(path.resolve(strict=True) == path and path.stat().st_dev == device for path in paths),
                      "source and Go caches are not on the container's writable root")
        restore["writable_root_paths"] = list(map(str, paths))
    return {**result, **restore, "tree": inventory(bench.GUEST_SOURCE),
            "runner_driver_sha256": bench.file_sha(Path(__file__)),
            "head": bench.git(["rev-parse", "HEAD"], bench.GUEST_SOURCE, bench.git_env()).decode().strip()}


def guest_run(cpus, variant, *, job_local=False):
    env = bench.guest_env(cpus)
    root = bench.GUEST_SOURCE
    product = bench.GUEST_LOCAL / "job"
    product.unlink(missing_ok=True)
    jobs = {
        "git_status": ["git", "-c", f"safe.directory={root}", "status", "--porcelain=v1", "--untracked-files=all"],
        "go_build": ["go", "build", "-mod=vendor", "-buildvcs=false", "-o", str(product), "."],
        "go_test": ["go", "test", "-mod=vendor", "-buildvcs=false", "-json", "-count=1",
                    "-run", "^(" + "|".join(TESTS) + ")$", "."],
    }
    output, timing = {}, {}
    before = bench.cpu_accounting()
    for phase, argv in jobs.items():
        start = time.monotonic_ns()
        output[phase] = bench.call(argv, cwd=root, env=env, timeout=240).stdout
        timing[phase] = time.monotonic_ns() - start
    after = bench.cpu_accounting()
    status = output["git_status"].decode()
    bench.require(status == (" M main_linux.go\n" if variant else ""), f"unexpected runner Git status {status!r}")
    tests = [json.loads(line) for line in output["go_test"].splitlines()]
    for action in ("run", "pass"):
        names = sorted(row["Test"] for row in tests if row["Action"] == action and row.get("Test"))
        bench.require(names == sorted(TESTS), f"unexpected runner tests for {action}: {names}")
    bench.require(not any(row["Action"] in ("fail", "skip") or "(cached)" in row.get("Output", "") for row in tests)
                  and [row["Package"] for row in tests if row["Action"] == "pass" and not row.get("Test")] == [PACKAGE],
                  "runner tests failed, skipped or returned cached output")
    observed = subprocess.run([product], input=b"{} {}", cwd=root, env=env, capture_output=True, timeout=8)
    message = MESSAGE + (" " + variant if variant else "")
    bench.require(observed.returncode == 1 and json.loads(observed.stdout) == {"error": message}, "wrong runner revision")
    result = {"phase_ns": timing, "sum_ns": sum(timing.values()), "git_status": status, "tests": sorted(TESTS),
              "main_sha256": bench.file_sha(root / "main_linux.go"), "binary_sha256": bench.file_sha(product),
              "revision_message": message, "cgroup_delta": {key: after[key] - value for key, value in before.items()}}
    if job_local:
        result["git_head"] = bench.git(["rev-parse", "HEAD"], root, env).decode().strip()
    return result


def copy_to_job(arm, source, target):
    started = time.monotonic_ns()
    try:
        bench.call([*arm.docker, "cp", str(source), f"{arm.id}:{target}"], timeout=90)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"{arm.name} could not copy {source} to the job at {target}: {error}") from error
    return time.monotonic_ns() - started


def run_job_local(arm, cpus, variant, main, content, *, updated):
    started = time.monotonic_ns()
    transfer_ns = copy_to_job(arm, main, bench.GUEST_SOURCE / main.name) if updated else 0
    sample = arm.guest("build-local", cpus, variant, timeout=240)
    return {**sample, "update_transfer_ns": transfer_ns, "update_bytes": len(content) if updated else 0,
            "work_with_transfer_ns": sample["sum_ns"] + transfer_ns,
            "host_wall_ns": time.monotonic_ns() - started}


def measure(args, stage):
    job_local = getattr(args, "job_local", False)
    host_started = time.monotonic_ns()
    source, head = prepare_checkout(stage, args.source)
    expected = inventory(source)
    checkout_ns = time.monotonic_ns() - host_started
    if job_local:
        payload, pack = prepare_bundle(stage, source)
        host_preparation = {"checkout_and_inventory_ns": checkout_ns, **pack,
                            "total_ns": time.monotonic_ns() - host_started}
    main = source / "main_linux.go"
    original = main.read_bytes()
    bench.require(original.count(MESSAGE.encode()) == 1, "runner validation string changed")
    names = ("orbstack", "hvf")
    arms = {name: bench.Arm(name, sock, args.image)
            for name, sock in zip(names, (args.orbstack_socket, args.hvf_socket))}
    identity = bench.image_identity(args.image_manifest, [arm.image_id for arm in arms.values()])
    receipt = {"image": identity, "image_reference": args.image, "source": expected, "git_commit": head,
               "cpus": args.cpus, "memory_mib": args.memory_mib, "pairs": [], "preparation": {}}
    if job_local:
        receipt.update(workspace_mode="job-local", host_preparation=host_preparation,
                       preparation_order=names)
    base_hash = set()
    revisions = set()
    scope = "mp-runner-checkout-" + uuid4().hex
    containers = {name: scope + "-" + name for name in names}
    with ExitStack() as cleanup:
        for name, arm in arms.items():
            arm.start(cleanup, containers[name], None if job_local else stage, args, set(identity.values()))
            if job_local:
                bench.require(not arm.container.get("Mounts") and not arm.container["HostConfig"].get("ReadonlyRootfs"),
                              f"{name} job-local container did not start on its writable root")
                started = time.monotonic_ns()
                transfer_ns = copy_to_job(arm, f"{payload}/.", bench.GUEST_ROOT)
                prep = arm.guest("prepare-local", args.cpus, args.memory_mib)
                prep.update(initial_transfer_ns=transfer_ns, checkout_ready_wall_ns=time.monotonic_ns() - started)
                bench.require(all(prep[key] == pack[key] for key in ("bundle_sha256", "bundle_bytes")),
                              f"{name} received a different Git bundle")
            else:
                prep = arm.guest("prepare", args.cpus, args.memory_mib)
            bench.require(prep["tree"] == expected and prep["head"] == head and not any(prep["cache_initial_entries"].values()),
                          f"{name} runner source or cache did not match")
            bench.require(prep["driver_sha256"] == bench.file_sha(stage / "bench_workspace_checkout.py")
                          and prep["runner_driver_sha256"] == bench.file_sha(stage / "driver.py"), "runner driver mismatch")
            receipt["preparation"][name] = prep
            prime = arm.guest("build-local" if job_local else "build", args.cpus, "", timeout=550)
            if job_local:
                bench.require(prime["git_head"] == head and prime["main_sha256"] == bench.sha(original),
                              f"{name} primed a different job-local revision")
            base_hash.add(prime["binary_sha256"])
            receipt.setdefault("prime", {})[name] = prime
        left, right = (receipt["preparation"][name] for name in names)
        bench.require(len(base_hash) == 1 and left["boot_id"] != right["boot_id"]
                      and all(left[k] == right[k] for k in ("limits", "versions", "tools_sha256", "go_env")),
                      "the two primes differ in product or configuration")
        for pair in range(args.pairs):
            order = names if pair % 2 == 0 else names[::-1]
            block = {"pair": pair + 1, "order": {"warm": order, "incremental": order[::-1]}}
            for phase, sequence in block["order"].items():
                variant = str(pair+1).zfill(4) if phase == "incremental" else ""
                content = original.replace(MESSAGE.encode(), f"{MESSAGE} {variant}".encode()) if variant else original
                updated = main.read_bytes() != content
                edit_started = time.monotonic_ns() if job_local and updated else None
                if updated:
                    pending = stage / "edited-main.go"
                    pending.write_bytes(content)
                    pending.replace(main)
                if job_local:
                    block.setdefault("host_edit_ns", {})[phase] = time.monotonic_ns() - edit_started if edit_started else 0
                    block[phase] = {name: run_job_local(arms[name], args.cpus, variant, main, content, updated=updated)
                                    for name in sequence}
                    bench.require(all(sample["git_head"] == head for sample in block[phase].values()),
                                  "the measured job-local checkouts have a different Git commit")
                else:
                    block[phase] = {name: arms[name].guest("build", args.cpus, variant, timeout=240) for name in sequence}
                hashes = {sample["binary_sha256"] for sample in block[phase].values()}
                bench.require(len(hashes) == 1 and all(sample["main_sha256"] == bench.sha(content)
                             for sample in block[phase].values()), "the measured runner revisions differ")
                if variant:
                    bench.require(hashes.isdisjoint(revisions | base_hash), "incremental build reused a previous binary")
                    revisions.update(hashes)
                else:
                    bench.require(hashes == base_hash, "warm build differs from its prime")
            receipt["pairs"].append(block)
        for arm in arms.values():
            arm.check_generation()
    receipt["median_ms"] = {phase: {name: statistics.median(row[phase][name]["sum_ns"] for row in receipt["pairs"])/1e6
                                    for name in names} for phase in ("warm", "incremental")}
    if job_local:
        receipt["job_local_median_ms"] = {
            phase: {name: {field.removesuffix("_ns"): statistics.median(
                row[phase][name][field] for row in receipt["pairs"]) / 1e6
                for field in ("update_transfer_ns", "work_with_transfer_ns", "host_wall_ns")} for name in names}
            for phase in ("warm", "incremental")
        }
        receipt["cleanup"] = {"removed_containers": containers}
        receipt["timing_scope"] = {
            "median_ms": "guest Git status, Go build and uncached Go test subprocess durations",
            "work_with_transfer_ns": "guest work plus the host Docker CLI time to deliver the edit or reset",
            "host_wall_ns": "elapsed host time for any copy plus the Docker exec and guest validation",
            "initial_transfer_ns": "one host Docker CLI copy of the bundle and driver files to each container",
            "clone_ns": "guest Git bundle clone and checkout",
            "checkout_ready_wall_ns": "initial transfer, guest clone and checkout validation on the host clock",
        }
    return receipt


def main():
    if sys.argv[1:2] == ["--guest"]:
        _, _, action, cpus, extra = sys.argv
        if action in ("prepare", "prepare-local"):
            result = guest_prepare(int(cpus), int(extra), job_local=action == "prepare-local")
        elif action in ("build", "build-local"):
            result = guest_run(int(cpus), extra, job_local=action == "build-local")
        else:
            raise ValueError(f"unknown runner action {action}")
        print(json.dumps(result))
        return
    from bench_workspace_edits import interrupted

    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("hvf-socket", "orbstack-socket", "workspace", "out", "image-manifest"):
        parser.add_argument("--" + flag, type=Path, required=True)
    parser.add_argument("--source", type=Path, default=bench.ROOT / "guest/runner")
    parser.add_argument("--image", required=True, help="preloaded ARM64 image with Go, Git and Python")
    parser.add_argument("--pairs", type=int, default=4)
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--memory-mib", type=int, default=1536)
    parser.add_argument("--job-local", action="store_true",
                        help="clone a copied Git bundle in each job and transfer every later source edit with docker cp")
    args = parser.parse_args()
    if not 2 <= args.pairs <= 16 or args.pairs % 2 or not 1 <= args.cpus <= 4 or not 512 <= args.memory_mib <= 4096:
        parser.error("use an even 2–16 pairs, 1–4 CPUs and 512–4096 MiB")
    for endpoint in (args.hvf_socket, args.orbstack_socket):
        if not endpoint.is_absolute() or not endpoint.is_socket():
            parser.error("supply absolute paths to two engine sockets")
    if args.out.exists() or args.hvf_socket.samefile(args.orbstack_socket):
        parser.error("choose a fresh output and two distinct engine sockets")
    for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_API_VERSION"):
        os.environ.pop(key, None)
    with tempfile.TemporaryDirectory(prefix="runner-ci-", dir=args.workspace.resolve(strict=True)) as temp:
        receipt = measure(args, Path(temp))
    with args.out.open("x") as out:
        json.dump(receipt, out, indent=2)
        out.write("\n")


if __name__ == "__main__":
    main()
