#!/usr/bin/env python3
"""Compare stock Git's optional preload pass on a Mac-authored read-only index."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
from tempfile import TemporaryDirectory
import time
from uuid import uuid4


GUEST_ROOT = Path("/git-preload-check")
CONFIG = r"^(core\.|index\.|feature\.|status\.)"
STATUS = ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
MODES = ("stock", "preload-off")
SHARD_MODES = ("stock", "shards-2", "shards-4")
INDEX_FIELDS = {"read/cache_nr", "preload/sum_lstat", "refresh/sum_lstat", "refresh/sum_scan"}


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def sha_bytes(content):
    return hashlib.sha256(content).hexdigest()


def sha_file(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def git_env():
    return {key: value for key, value in os.environ.items() if not key.startswith("GIT_")} | {
        "LC_ALL": "C", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
    }


def invoke(argv, *, env=None, accepted=(0,), timeout=30):
    result = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    require(result.returncode in accepted, f"{argv[:3]} exited {result.returncode}: {result.stderr[-1800:]!r}")
    return result.stdout


def git_command(root, mode):
    cmd = ["git", "-C", str(root), "-c", f"safe.directory={root}"]
    if mode == "preload-off":
        cmd += ["-c", "core.preloadIndex=false"]
    return cmd


def trace_summary(path):
    events = [json.loads(line) for line in path.read_text().splitlines()]
    return {
        "counts": {event["key"]: int(event["value"]) for event in events
                   if event.get("key") in INDEX_FIELDS and event.get("category") == "index"},
        "regions_s": {event["label"]: event["t_rel"] for event in events
                      if event.get("event") == "region_leave" and event.get("label") in ("preload", "refresh", "untracked")},
    }


def run_status(root, mode, env, trace=None):
    argv = git_command(root, mode) + STATUS
    env = env | {"GIT_TRACE2_EVENT": str(trace)} if trace else env
    begin = time.monotonic_ns()
    output = invoke(argv, env=env)
    result = {"ns": time.monotonic_ns() - begin, "status_hex": output.hex()}
    if trace:
        result["trace2"] = trace_summary(trace)
    return result


def config_read(root, mode, env):
    args = git_command(root, mode) + ["config", "--show-scope", "--show-origin", "--get-regexp", CONFIG]
    return invoke(args, env=env, accepted=(0, 1)).decode().splitlines()


def run_shard_status(root, mode, env, trace=None):
    if mode == "stock":
        return run_status(root, mode, env, trace)
    argv = ["python3", str(GUEST_ROOT / "git_parallel_clean.py"), "--workers", mode.rsplit("-", 1)[1], str(root)]
    env = env | {"GIT_TRACE2_EVENT": str(trace)} if trace else env
    begin = time.monotonic_ns()
    output = invoke(argv, env=env)
    result = {"ns": time.monotonic_ns() - begin, "status_hex": output.hex()}
    if trace:
        result["git_processes"] = [json.loads(line) for line in trace.read_text().splitlines()
                                   if '"key"' in line]
    return result


def guest_shards(root, phase, rounds, env, mount=None):
    env = env | {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": str(root)}
    if phase == "observe-shards":
        print(json.dumps({"digest": sha_file(root / "main_linux.go"),
                          "status": {mode: run_shard_status(root, mode, env) for mode in SHARD_MODES}}))
        return
    from git_parallel_clean import status as shard_status

    report = {"git_sha256": sha_file(Path(shutil.which("git"))), "index_sha256": sha_file(root / ".git" / "index"),
              "config_sha256": sha_file(root / ".git" / "config"), "mount": mount,
              "untraced": [], "trace2": {}}
    for workers in (2, 4):
        result, fast = shard_status(root, workers, env)
        require(fast and result.returncode == 0 and not result.stdout and not result.stderr,
                f"parallel gate did not reach its clean path with {workers} workers")
    for number in range(rounds):
        order = SHARD_MODES[number % 3:] + SHARD_MODES[:number % 3]
        if number % 2:
            order = order[::-1]
        calls = {mode: run_shard_status(root, mode, env) for mode in order}
        require(not any(call["status_hex"] for call in calls.values()), "clean sharded status differs")
        report["untraced"].append({"order": order, "calls": calls})
    with TemporaryDirectory(prefix="mp-git-shards-") as scratch:
        for mode in SHARD_MODES:
            row = run_shard_status(root, mode, env, Path(scratch) / (mode + ".jsonl"))
            if mode != "stock":
                events = row.pop("git_processes")
                row["scans_by_process"] = [int(event["value"]) for event in events if event.get("key") == "refresh/sum_scan"]
                row["stats_by_process"] = [int(event["value"]) for event in events if event.get("key") == "refresh/sum_lstat"]
            report["trace2"][mode] = row
    print(json.dumps(report))


def guest_dirty(root, rounds, env, expected_hex):
    from git_parallel_clean import status as shard_status

    env = env | {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": str(root)}
    oracle, fast = shard_status(root, 4, env)
    require(fast == (not expected_hex) and not oracle.stderr and oracle.returncode == 0 and oracle.stdout.hex() == expected_hex,
            "clean and dirty checks did not take their expected paths")
    pairs = []
    modes = ("stock", "shards-4")
    for number in range(rounds):
        order = modes if number % 2 == 0 else modes[::-1]
        calls = {mode: run_shard_status(root, mode, env) for mode in order}
        require(all(call["status_hex"] == expected_hex for call in calls.values()), "dirty porcelain output differs")
        pairs.append({"order": order, "calls": calls})
    print(json.dumps({"index_sha256": sha_file(root / ".git" / "index"), "git_sha256": sha_file(Path(shutil.which("git"))),
                      "actual_digest": sha_file(root / "main_linux.go"), "used_stock_fallback": not fast, "pairs": pairs}))


def guest(phase, rounds, expected_hex=None):
    root = GUEST_ROOT / "source"
    env = git_env()
    if phase == "observe-shards":
        guest_shards(root, phase, rounds, env)
        return
    if phase == "observe":
        result = {"digest": sha_file(root / "main_linux.go"), "status": {}}
        for mode in MODES:
            result["status"][mode] = run_status(root, mode, env)
        print(json.dumps(result))
        return

    mount = [line.split() for line in Path("/proc/self/mountinfo").read_text().splitlines()
             if line.split()[4] == str(GUEST_ROOT)]
    require(len(mount) == 1 and "ro" in mount[0][5].split(","), "checkout is not on the required read-only bind")
    if phase == "shards":
        guest_shards(root, phase, rounds, env, mount[0])
        return
    if phase == "dirty":
        guest_dirty(root, rounds, env, expected_hex)
        return
    result = {
        "git": invoke(["git", "version", "--build-options"], env=env).decode(),
        "git_sha256": sha_file(Path(shutil.which("git"))),
        "index_sha256": sha_file(root / ".git" / "index"),
        "config_sha256": sha_file(root / ".git" / "config"),
        "git_environment": {key: env[key] for key in sorted(env) if key.startswith("GIT_")},
        "resolved_config": {mode: config_read(root, mode, env) for mode in MODES},
        "mount": mount[0], "untraced": [], "trace2": {},
    }
    for mode in MODES:
        require(not run_status(root, mode, env)["status_hex"], "fixture isn't clean during warmup")
    for number in range(rounds):
        order = MODES if number % 2 == 0 else MODES[::-1]
        calls = {mode: run_status(root, mode, env) for mode in order}
        require(not any(call["status_hex"] for call in calls.values()), "clean paired output differs")
        result["untraced"].append({"order": order, "calls": calls})
    with TemporaryDirectory(prefix="mp-git-preload-") as scratch:
        scratch = Path(scratch)
        for mode in MODES:
            result["trace2"][mode] = run_status(root, mode, env, scratch / (mode + ".jsonl"))
        private = scratch / "index"
        shutil.copyfile(root / ".git" / "index", private)
        private_env = env | {"GIT_INDEX_FILE": str(private)}
        begin = time.monotonic_ns()
        invoke(git_command(root, "stock") + ["update-index", "--refresh"], env=private_env | {"GIT_OPTIONAL_LOCKS": "1"})
        result["private_clean_control"] = {"refresh_ns": time.monotonic_ns() - begin, "trace2": {}}
        for mode in MODES:
            result["private_clean_control"]["trace2"][mode] = run_status(root, mode, private_env, scratch / ("private-" + mode + ".jsonl"))
    require(all(not row["status_hex"] for row in result["trace2"].values()), "traced raw status differs")
    print(json.dumps(result))


def snapshot(st):
    return {"inode": st.st_ino, "size": st.st_size, "mtime_ns": st.st_mtime_ns, "ctime_ns": st.st_ctime_ns}


def wait_visibility(docker, name, target, expected):
    until = time.monotonic() + 8
    while time.monotonic() < until:
        observed = invoke(docker + ["exec", name, "sha256sum", str(target)]).split()[0].decode()
        if observed == expected:
            return
        time.sleep(0.05)
    raise RuntimeError(f"Guest never observed {target.name}: expected {expected}, last {observed}")


def edit_controls(docker, name, root, temp, phase="observe"):
    main = root / "main_linux.go"
    absolute = GUEST_ROOT / "source" / main.name
    content = main.read_bytes()
    times = main.stat()
    binary = b"\0\xff\r\n" + content[4:]
    changes = {}
    for scenario in ("same_inode_exact_mtime", "replaced_inode_exact_mtime", "restored"):
        if scenario == "same_inode_exact_mtime":
            # Match seconds as well as the exact mtime; a raw Mac index must
            # still force Git to recheck data.
            while time.time_ns() % 1_000_000_000 > 400_000_000:
                time.sleep(0.01)
            os.utime(main, ns=(times.st_atime_ns, times.st_mtime_ns))
            before = main.stat()
            with main.open("r+b") as file:
                file.write(binary)
                file.flush()
            os.utime(main, ns=(times.st_atime_ns, times.st_mtime_ns))
            after = main.stat()
            require(before.st_ino == after.st_ino and before.st_ctime_ns // 10**9 == after.st_ctime_ns // 10**9,
                    "the exact-time binary control crossed a ctime second")
            expected = binary
        else:
            before = main.stat()
            expected = content if scenario == "restored" else b"\x01\xff\0\t" + content[4:]
            new = temp / "replace-file"
            new.write_bytes(expected)
            new.chmod(times.st_mode & 0o777)
            os.utime(new, ns=(times.st_atime_ns, times.st_mtime_ns))
            new.replace(main)
            after = main.stat()
            require(before.st_ino != after.st_ino, "replacement didn't get another inode")
        require(before.st_size == after.st_size and before.st_mtime_ns == after.st_mtime_ns,
                "source edit changed size or mtime")
        expected_hash = sha_bytes(expected)
        wait_visibility(docker, name, absolute, expected_hash)
        output = json.loads(invoke(docker + ["exec", name, "python3", str(GUEST_ROOT / "git-preload.py"), "guest", phase, "0"]))
        wanted = b"" if scenario == "restored" else b" M main_linux.go\x00"
        require(output["digest"] == expected_hash and all(row["status_hex"] == wanted.hex() for row in output["status"].values()),
                f"different raw status at {scenario}: {output}")
        changes[scenario] = {"before": snapshot(before), "after": snapshot(after), **output}
    return changes


def dirty_controls(docker, name, root, rounds, index_hash):
    target = root / "main_linux.go"
    original = target.read_bytes()
    stamp = target.stat()
    relative = target.name
    untracked = root / "git-preload-untracked.bin"
    results = {}
    for case, offset in (("clean", None), ("tracked_start", 0), ("tracked_end", len(original) - 4), ("untracked", None)):
        changed = original if offset is None else original[:offset] + b"\0\xff\x01\t" + original[offset + 4:]
        before = target.stat()
        if case != "clean":
            with target.open("r+b") as dest:
                dest.write(changed)
            os.utime(target, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        after = target.stat()
        require(before.st_ino == after.st_ino and before.st_size == after.st_size == stamp.st_size
                and before.st_mtime_ns == after.st_mtime_ns == stamp.st_mtime_ns, "dirty control changed inode, size or mtime")
        if case == "untracked":
            untracked.write_bytes(b"untracked\0\xff\n")
            wait_visibility(docker, name, GUEST_ROOT / "source" / untracked.name, sha_file(untracked))
            expected = b"?? " + os.fsencode(untracked.name) + b"\0"
        elif offset is not None:
            expected = b" M " + os.fsencode(relative) + b"\0"
        else:
            expected = b""
        expected_hash = sha_bytes(changed)
        wait_visibility(docker, name, GUEST_ROOT / "source" / relative, expected_hash)
        probe = json.loads(invoke(docker + ["exec", name, "python3", str(GUEST_ROOT / "git-preload.py"),
                                          "guest", "dirty", str(rounds), expected.hex()]))
        require(probe["index_sha256"] == index_hash and probe["actual_digest"] == expected_hash,
                "dirty sampled state did not match host publication")
        probes = probe["pairs"]
        probe["median_ms"] = {mode: statistics.median(call["calls"][mode]["ns"] for call in probes) / 1e6
                              for mode in ("stock", "shards-4")}
        probe["paired_penalty_ms"] = statistics.median(call["calls"]["shards-4"]["ns"] - call["calls"]["stock"]["ns"]
                                                     for call in probes) / 1e6
        results[case] = {"offset": offset, "before": snapshot(before), "after": snapshot(after), **probe}
    untracked.unlink()
    require(sha_file(target) == sha_bytes(original), "source restore failed")
    return results


def host(args):
    sys.path.insert(0, str(args.helpers))
    import bench_workspace_runner as bench

    require(not args.out.exists(), "choose a fresh receipt")
    require(not args.dirty_parallel or args.parallel_helper, "dirty controls require the parallel helper")
    require(all(endpoint.startswith("unix://") and Path(endpoint[7:]).is_socket()
                for endpoint in (args.hvf_host, args.orb_host)), "use explicit active Unix sockets")
    report = {"passed": False, "engines": {}}
    with TemporaryDirectory(prefix="mp-git-field-", dir=args.workspace) as tempdir:
        temp = Path(tempdir)
        stage_ns = time.monotonic_ns()
        root, commit = bench.prepare_checkout(temp, args.source)
        report.update(source=bench.inventory(root), commit=commit, preparation_ns=time.monotonic_ns() - stage_ns,
                      host_index_sha256=sha_file(root / ".git" / "index"), host_config_sha256=sha_file(root / ".git" / "config"))
        require(report["source"]["files"] == 1058, "expected the archived 1,058-file runner checkout")
        shutil.copyfile(Path(__file__), temp / "git-preload.py")
        if args.parallel_helper:
            shutil.copyfile(args.parallel_helper, temp / "git_parallel_clean.py")
        try:
            for engine, endpoint in (("hvf", args.hvf_host), ("orbstack", args.orb_host)):
                docker = ["docker", "--host", endpoint]
                name = "mp-git-preload-" + uuid4().hex
                side = report["engines"][engine] = {"name": name, "remaining_ids": []}
                label = f"io.micropod.qa.git-preload={name}"
                invoke(docker + ["run", "-d", "--rm", "--name", name, "--pull=never", "--network=none", "--cpus=2", "--memory=1536m",
                                 "--label", label, "--mount", f"type=bind,source={temp},target={GUEST_ROOT},readonly",
                                 "--entrypoint", "/bin/sh", args.image, "-ec", "exec sleep 90"])
                try:
                    if args.dirty_parallel:
                        side["dirty"] = dirty_controls(docker, name, root, args.rounds, report["host_index_sha256"])
                        continue
                    phase = "shards" if args.parallel_helper else "pair"
                    modes = SHARD_MODES if args.parallel_helper else MODES
                    worker = json.loads(invoke(docker + ["exec", name, "python3", str(GUEST_ROOT / "git-preload.py"), "guest", phase, str(args.rounds)]))
                    side.update(worker)
                    require(side["index_sha256"] == report["host_index_sha256"] and side["config_sha256"] == report["host_config_sha256"],
                            "guest didn't read the exact host index/config")
                    stock = worker["trace2"]["stock"]["trace2"]["counts"]
                    require(stock.get("preload/sum_lstat") == stock.get("refresh/sum_lstat") == stock.get("refresh/sum_scan") == 1058,
                            f"unexpected stock tracked work on {engine}: {stock}")
                    if args.parallel_helper:
                        for mode in SHARD_MODES[1:]:
                            require(sum(worker["trace2"][mode]["scans_by_process"]) == 1058,
                                    f"{mode} didn't verify every tracked file")
                    else:
                        off = worker["trace2"]["preload-off"]["trace2"]["counts"]
                        require("preload/sum_lstat" not in off and off.get("refresh/sum_lstat") == off.get("refresh/sum_scan") == 1058,
                                f"unexpected preload-disabled tracked work on {engine}: {off}")
                    side["median_ms"] = {mode: statistics.median(pair["calls"][mode]["ns"] for pair in worker["untraced"]) / 1e6
                                         for mode in modes}
                    side["edits"] = edit_controls(docker, name, root, temp, "observe-shards" if args.parallel_helper else "observe")
                    require(sha_file(root / ".git" / "index") == report["host_index_sha256"], "test rewrote the Mac index")
                finally:
                    invoke(docker + ["rm", "--force", name])
                    side["remaining_ids"] = invoke(docker + ["ps", "-aq", "--filter", f"label={label}"]).decode().splitlines()
                    require(not side["remaining_ids"], "scoped probe left a container")
            git_hashes = ({row["git_sha256"] for side in report["engines"].values() for row in side["dirty"].values()}
                          if args.dirty_parallel else {side["git_sha256"] for side in report["engines"].values()})
            require(len(git_hashes) == 1, "guest Git binaries differ")
            report["passed"] = True
        except Exception as error:
            report["error"] = str(error)
            raise
        finally:
            with args.out.open("x") as file:
                json.dump(report, file, indent=2)
                file.write("\n")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "guest":
        guest(sys.argv[2], int(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else None)
        sys.exit(0)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hvf-host", required=True)
    parser.add_argument("--orb-host", required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--helpers", type=Path, required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--parallel-helper", type=Path, help="measure inclusive stock status versus a bounded sharded candidate")
    parser.add_argument("--dirty-parallel", action="store_true", help="measure paired stock and four-worker dirty fallback")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=6, choices=range(2, 13))
    host(parser.parse_args())
