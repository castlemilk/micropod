#!/usr/bin/env python3
"""Compare Git status on a Mac-authored index, a guest-refreshed index and a writable guest clone."""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import sys
import tempfile
import time
from uuid import uuid4

import bench_workspace_checkout as bench

CLONE_MOUNT = Path("/git-ci")
CLONE = CLONE_MOUNT / "checkout"
PRIVATE_INDEX = Path("/tmp/git-ci-index")
MODES = ("host-index", "guest-index", "guest-clone")
SAMPLE_PATH = "main_linux.go"


def paths(mode):
    env = bench.git_env()
    if mode == "host-index":
        return bench.GUEST_SOURCE, env
    env.pop("GIT_OPTIONAL_LOCKS")
    if mode == "guest-index":
        env["GIT_INDEX_FILE"] = str(PRIVATE_INDEX)
        return bench.GUEST_SOURCE, env
    if mode == "guest-clone":
        return CLONE, env
    raise ValueError(mode)


def git(root, env, *args):
    return bench.call(["git", "-c", f"safe.directory={root}", *args], cwd=root, env=env, timeout=120).stdout


def guest_prepare(cpus, memory_mib):
    common = bench.guest_prepare(cpus, memory_mib)
    source, env = paths("guest-index")
    shutil.copyfile(source / ".git/index", PRIVATE_INDEX)
    git(source, env, "update-index", "--really-refresh")
    _, env = paths("guest-clone")
    start = time.monotonic_ns()
    git(source, env, "clone", "--quiet", "--no-local", "--template=", str(source), str(CLONE))
    clone_ns = time.monotonic_ns() - start
    info = {}
    for mode in MODES:
        root, env = paths(mode)
        sample = (root / SAMPLE_PATH).stat()
        info[mode] = {
            "head": git(root, env, "rev-parse", "HEAD").decode().strip(),
            "index_entry": git(root, env, "ls-files", "--debug", "--", SAMPLE_PATH).decode(),
            "worktree_stat": {field: getattr(sample, "st_" + field)
                              for field in ("mode", "ino", "dev", "uid", "gid", "size", "mtime_ns", "ctime_ns")},
        }
    return {"environment": common, "clone_ns": clone_ns, "modes": info,
            "probe_sha256": bench.file_sha(Path(__file__))}


def guest_status(mode, trace):
    root, env = paths(mode)
    with tempfile.TemporaryDirectory(prefix="git-ci-") as tmp:
        event_log = Path(tmp) / "events.jsonl"
        if trace:
            env["GIT_TRACE2_EVENT"] = str(event_log)
        start = time.monotonic_ns()
        status = git(root, env, "status", "--porcelain=v1", "--untracked-files=all")
        elapsed = time.monotonic_ns() - start
        result = {"status": status.decode(), "elapsed_ns": elapsed, "file_sha256": bench.file_sha(root / SAMPLE_PATH)}
        if trace:
            records = [json.loads(line) for line in event_log.read_bytes().splitlines()]
            result["trace2"] = [{k: row[k] for k in ("event", "category", "label", "key", "value", "t_rel") if k in row}
                                for row in records if row["event"] in ("data", "region_leave")]
            st = (root / SAMPLE_PATH).stat()
            result["sample_stat"] = {k: getattr(st, "st_" + k) for k in ("ino", "uid", "gid", "size", "mtime_ns", "ctime_ns")}
            result["index_entry"] = git(root, env, "ls-files", "--debug", "--", SAMPLE_PATH).decode()
        return result


def measure(args, stage):
    import bench_workspace_runner as runner

    source, head = runner.prepare_checkout(stage, args.source)
    shutil.copy2(__file__, stage / "driver.py")
    original = (source / SAMPLE_PATH).read_bytes()
    bench.require(original.count(runner.MESSAGE.encode()) == 1, "checkout revision marker changed")
    arms = {name: bench.Arm(name, sock, args.image) for name, sock in
            (("hvf", args.hvf_socket), ("orbstack", args.orbstack_socket))}
    image = bench.image_identity(args.image_manifest, [arm.image_id for arm in arms.values()])
    scope = "mp-git-" + uuid4().hex
    receipt = {"source": runner.inventory(source), "head": head, "image": image, "preparation": {}, "prime": {},
               "diagnostics": {}, "pairs": [], "failures": []}
    clones = {}
    with ExitStack() as cleanup:
        for name, arm in arms.items():
            volume = stage / name
            volume.mkdir()
            clones[name] = volume / CLONE.name
            arm.start(cleanup, scope + "-" + name, stage, args, set(image.values()),
                      extra_mounts=[bench.bind_mount(volume, CLONE_MOUNT, read_only=False)])
            result = arm.guest("prepare", args.cpus, args.memory_mib)
            receipt["preparation"][name] = result
            bench.require({m["head"] for m in result["modes"].values()} == {head}
                          and result["probe_sha256"] == bench.file_sha(Path(__file__))
                          and runner.inventory(clones[name]) == receipt["source"], "clone or driver identity mismatch")
        left, right = [rec["environment"] for rec in receipt["preparation"].values()]
        bench.require(left["boot_id"] != right["boot_id"]
                      and all(left[k] == right[k] for k in ("limits", "versions", "tools_sha256")), "guests differ")
        for name, arm in arms.items():
            receipt["diagnostics"][name] = {}
            receipt["prime"][name] = {}
            for mode in MODES:
                prime = arm.guest("status", mode)
                bench.require(prime["status"] == "" and prime["file_sha256"] == bench.sha(original),
                              "initial Git status differs from the source checkout")
                receipt["prime"][name][mode] = prime
                diagnose = name == "hvf" and mode == args.trace_mode
                if diagnose:
                    token = secrets.token_hex(8)
                    def observer(action):
                        return json.loads(bench.call([sys.executable, "-B", args.trace_helper, action,
                            "--workspace", args.workspace, "--token", token], timeout=45).stdout)
                    observer("start")
                try:
                    diag = arm.guest("trace", mode)
                finally:
                    if diagnose:
                        observer("finish")
                if diagnose:
                    diag["ftrace"] = observer("report")
                bench.require(diag["status"] == "" and diag["file_sha256"] == bench.sha(original), "dirty diagnostic tree")
                receipt["diagnostics"][name][mode] = diag
        names = tuple(arms)
        for pair in range(args.pairs):
            rows = []
            for edit in (False, True):
                replacement = runner.MESSAGE.upper().encode()
                content = original.replace(runner.MESSAGE.encode(), replacement) if edit else original
                replaced_at = {}
                for root in (source, *clones.values()):
                    target = root / SAMPLE_PATH
                    if target.read_bytes() != content:
                        temporary = root.parent / "replacement"
                        temporary.write_bytes(content)
                        temporary.chmod(target.stat().st_mode & 0o777)
                        temporary.replace(target)
                        replaced_at[root] = time.monotonic_ns()
                modes = MODES[pair % len(MODES):] + MODES[:pair % len(MODES)]
                for index, mode in enumerate(modes):
                    order = names if (pair + index + edit) % 2 == 0 else names[::-1]
                    row = {"mode": mode, "edited": edit, "order": order}
                    for name in order:
                        replaced = replaced_at.get(clones[name] if mode == "guest-clone" else source)
                        submitted = time.monotonic_ns()
                        result = arms[name].guest("status", mode)
                        result["host_ns_since_edit_at_submission"] = submitted - replaced if replaced is not None else None
                        expected = f" M {SAMPLE_PATH}\n" if edit else ""
                        result["correct"] = result["status"] == expected and result["file_sha256"] == bench.sha(content)
                        if not result["correct"]:
                            failure = {"pair": pair + 1, "engine": name, "mode": mode, "edited": edit,
                                       "expected": expected, "expected_sha256": bench.sha(content), "first": result}
                            time.sleep(0.25)
                            failure["recheck"] = arms[name].guest("trace", mode)
                            receipt["failures"].append(failure)
                        row[name] = result
                    rows.append(row)
            receipt["pairs"].append(rows)
        for arm in arms.values():
            arm.check_generation()
    receipt["complete"] = not receipt["failures"]
    return receipt


def main():
    if sys.argv[1:2] == ["--guest"]:
        action, *rest = sys.argv[2:]
        if action == "prepare":
            print(json.dumps(guest_prepare(*map(int, rest))))
        elif action in ("status", "trace"):
            print(json.dumps(guest_status(rest[0], action == "trace")))
        else:
            raise ValueError(action)
        return
    from bench_workspace_edits import interrupted

    parser = argparse.ArgumentParser(description=__doc__)
    for key in ("hvf-socket", "orbstack-socket", "workspace", "source", "image-manifest", "out"):
        parser.add_argument("--" + key, type=Path, required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--pairs", type=int, choices=range(2, 17, 2), default=6)
    parser.add_argument("--trace-helper", type=Path, help="Stock guest ftrace observer controller")
    parser.add_argument("--trace-mode", choices=MODES)
    args = parser.parse_args()
    args.cpus, args.memory_mib = 2, 1536
    if bool(args.trace_mode) != bool(args.trace_helper) or args.out.exists():
        parser.error("supply trace mode and helper together and choose a fresh output")
    for sock in (args.hvf_socket, args.orbstack_socket):
        if not sock.is_absolute() or not sock.is_socket():
            parser.error("expected absolute paths to two live engine sockets")
    if args.hvf_socket.samefile(args.orbstack_socket):
        parser.error("expected two distinct engines")
    for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH", "DOCKER_API_VERSION"):
        os.environ.pop(key, None)
    signal.signal(signal.SIGTERM, interrupted)
    with tempfile.TemporaryDirectory(prefix="git-ci-", dir=args.workspace.resolve(strict=True)) as tmp:
        result = measure(args, Path(tmp))
    with args.out.open("x") as out:
        json.dump(result, out, indent=2)
        out.write("\n")
    return int(not result["complete"])


if __name__ == "__main__":
    raise SystemExit(main())
