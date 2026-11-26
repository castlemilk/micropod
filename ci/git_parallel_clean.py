#!/usr/bin/env python3
"""Try a parallel clean-worktree check using stock Git, then fall back to stock status."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
from tempfile import TemporaryDirectory


STATUS = ("status", "--porcelain=v1", "-z", "--untracked-files=all")
TRACKED_STATUS = ("status", "--porcelain=v1", "-z", "--untracked-files=no")
OVERRIDES = ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX",
             "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS")


def git(root, env, *args):
    return subprocess.run(["git", "-C", str(root), "--no-optional-locks", *args], env=env,
                          stdin=subprocess.DEVNULL, capture_output=True, check=False)


def successful(result):
    # Keep stock diagnostics when an optimization command encounters warnings.
    return result.returncode == 0 and not result.stderr


def file_token(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def snapshot_index(source, destination=None):
    with os.fdopen(os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as index:
        before = os.fstat(index.fileno())
        if not stat.S_ISREG(before.st_mode):
            return None
        digest = hashlib.sha256()
        if destination is None:
            for chunk in iter(lambda: index.read(65536), b""):
                digest.update(chunk)
        else:
            with destination.open("xb") as copy:
                for chunk in iter(lambda: index.read(65536), b""):
                    digest.update(chunk)
                    copy.write(chunk)
            os.utime(destination, ns=(before.st_atime_ns, before.st_mtime_ns))
            if destination.stat().st_mtime_ns != before.st_mtime_ns:
                return None
        if file_token(before) != file_token(os.fstat(index.fileno())) or file_token(before) != file_token(source.lstat()):
            return None
        return file_token(before), digest.digest()


def metadata_tokens(dotgit):
    result = []
    for name in ("HEAD", "config"):
        path = dotgit / name
        if not stat.S_ISREG(path.lstat().st_mode):
            return None
        result.append(path.read_bytes())
    return result


def tracked_paths(root, env):
    listed = git(root, env, "ls-files", "--sparse", "--stage", "-z")
    if not successful(listed) or not listed.stdout.endswith(b"\0"):
        return None
    paths = []
    for entry in listed.stdout[:-1].split(b"\0"):
        header, tab, path = entry.partition(b"\t")
        fields = header.split()
        if not tab or not path or len(fields) != 3 or fields[0] not in (b"100644", b"100755", b"120000") or fields[2] != b"0":
            return None
        paths.append(path)
    return paths


def clean_checks(root, env, paths, head, workers):
    width = (len(paths) + workers - 1) // workers
    shards = [paths[i:i + width] for i in range(0, len(paths), width)]
    prefix = ("-c", "core.preloadIndex=false", "--literal-pathspecs")
    args = [(*prefix, *TRACKED_STATUS, "--", *names) for names in shards]
    args += [("diff-index", "--cached", "--quiet", head, "--"), ("ls-files", "--others", "--exclude-standard", "-z")]
    # Long tracked scans start first. The executor also caps the count while
    # the two whole-worktree checks run.
    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = pool.map(lambda cmd: git(root, env, *cmd), args)
        return all(successful(result) and not result.stdout for result in results)


def parallel_clean(root, workers, env):
    if any(key in env for key in OVERRIDES):
        return False
    dotgit = root / ".git"
    if not stat.S_ISDIR(dotgit.lstat().st_mode):
        return False
    head_args = ("rev-parse", "--show-toplevel", "--verify", "HEAD^{commit}")
    head = git(root, env, *head_args)
    tokens = metadata_tokens(dotgit)
    top = os.fsencode(root.resolve()) + b"\n"
    if not successful(head) or not head.stdout.startswith(top) or tokens is None:
        return False
    commit = head.stdout.removeprefix(top).strip()
    if not successful(shared := git(root, env, "rev-parse", "--shared-index-path")) or shared.stdout:
        return False

    with TemporaryDirectory(prefix="mp-git-index-") as scratch:
        index = Path(scratch) / "index"
        snapshot = snapshot_index(dotgit / "index", index)
        if snapshot is None:
            return False
        pinned = env | {"GIT_INDEX_FILE": str(index)}
        paths = tracked_paths(root, pinned)
        if not paths or not clean_checks(root, pinned, paths, commit, workers):
            return False
        # Raw Git writers publish a new index with rename. Compare its bytes
        # as well as the stamp so direct index edits also invalidate the fast path.
        latest_head = git(root, env, *head_args)
        return (successful(latest_head) and latest_head.stdout == head.stdout
                and metadata_tokens(dotgit) == tokens and snapshot_index(dotgit / "index") == snapshot)


def status(root, workers, env):
    try:
        if parallel_clean(root, workers, env):
            return subprocess.CompletedProcess([], 0, b"", b""), True
    except OSError:
        # Missing, changing or unsupported checkouts retain stock behavior.
        pass
    return git(root, env, *STATUS), False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workers", type=int, required=True, choices=(2, 4))
    parser.add_argument("worktree", type=Path)
    args = parser.parse_args()
    result, _ = status(args.worktree, args.workers, os.environ.copy())
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
