"""Disposable first-write and metadata probe for an explicitly selected existing filesystem."""

import argparse
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import platform
import subprocess
import tempfile
import time
from pathlib import Path


def timed(action):
    start = time.monotonic_ns()
    result = action()
    return result, time.monotonic_ns() - start


def lower_file(rewrite):
    from ci_edit_loop import mount_at

    root = Path(subprocess.check_output(["go", "env", "GOROOT"], text=True).strip())
    file = root / "src/net/http/server.go"
    mount = mount_at(file)
    if os.environ.get("MP_PRIVATE_COPYUP") != "1" or mount["fs"] != "overlay":
        raise ValueError("Copy-up probe requires a disposable job on overlay")
    data = file.read_bytes()
    if len(data) < 4096:
        raise ValueError("Lower file too small")
    row = dict(file=str(file), bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), mount=mount)

    def action():
        with file.open("r+b" if rewrite else "rb", buffering=0) as handle:
            if rewrite:
                if os.pwrite(handle.fileno(), data[:4096], 0) != 4096:
                    raise OSError("short pwrite")
                os.fsync(handle.fileno())
            else:
                if handle.read(4096) != data[:4096]:
                    raise ValueError("read mismatch")

    _, row["open_io_close_ns"] = timed(action)
    if file.read_bytes() != data:
        raise ValueError("copy-up changed original contents")
    return row


def probe(parent, rounds, method):
    def seed(path):
        with path.open("xb") as f:
            f.truncate(512 * 2**20)
            chunk = bytes([49]) * 2**20
            for _ in range(32):
                f.write(chunk)
            f.flush()
            os.fsync(f.fileno())

    def clone(src, dest):
        if platform.system() == "Darwin":
            lib = ctypes.CDLL(None, use_errno=True)
            if lib.clonefile(os.fsencode(src), os.fsencode(dest), 0):
                n = ctypes.get_errno()
                raise OSError(n, os.strerror(n))
        else:
            with src.open("rb") as inp, dest.open("xb") as out:
                fcntl.ioctl(out.fileno(), 0x40049409, inp.fileno())  # Linux FICLONE

    with tempfile.TemporaryDirectory(dir=parent, prefix="mp-storage-") as tmp:
        root = Path(tmp)
        base = root / "base"
        seed(base)
        rows = []
        for i in range(rounds):
            target = root / f"private-{i}"
            try:
                _, prep = timed(lambda: clone(base, target) if method == "clone" else seed(target))
            except OSError as e:
                if method == "clone" and e.errno in (
                    errno.EOPNOTSUPP,
                    errno.ENOTTY,
                    errno.EXDEV,
                    errno.ENOSYS,
                    errno.EINVAL,
                ):
                    return dict(method=method, available=False, errno=e.errno, rows=rows)
                raise
            data = {}
            with target.open("r+b", buffering=0) as f:
                for stage, byte in (("first", 65), ("repeat", 66)):
                    length, write = timed(lambda: os.pwrite(f.fileno(), bytes([byte]) * 4096, 0))
                    if length != 4096:
                        raise OSError("short pwrite")
                    _, sync = timed(lambda: os.fsync(f.fileno()))
                    data[stage] = dict(pwrite_ns=write, fsync_ns=sync)
                n, read = timed(lambda: len(f.read(32 * 2**20)))
                if n != 32 * 2**20:
                    raise OSError("short sequential read")
                chunk = b"S" * 2**20

                def stream_write():
                    for _ in range(8):
                        if f.write(chunk) != len(chunk):
                            raise OSError("short sequential write")

                _, streaming = timed(stream_write)
                _, stream_sync = timed(lambda: os.fsync(f.fileno()))
            with base.open("rb") as a, target.open("rb") as b:
                if a.read(4096) != b"1" * 4096 or b.read(4096) != b"B" * 4096:
                    raise ValueError("base or private data changed unexpectedly")

            def metadata():
                for j in range(128):
                    path = root / f"m-{j}"
                    path.touch(exist_ok=False)
                    path.stat()
                    path.rename(root / "renamed")
                    (root / "renamed").unlink()

            _, meta = timed(metadata)
            rows.append(
                dict(
                    prepare_ns=prep,
                    **data,
                    warm_read_bytes=n,
                    warm_read_ns=read,
                    sequential_write_bytes=8 * 2**20,
                    sequential_write_ns=streaming,
                    sequential_write_fsync_ns=stream_sync,
                    metadata_create_stat_rename_unlink_128_ns=meta,
                    allocated_logical_view=target.stat().st_blocks * 512,
                )
            )
            target.unlink()
        return dict(
            method=method,
            available=True,
            device=root.stat().st_dev,
            logical_bytes=base.stat().st_size,
            populated_bytes=32 * 2**20,
            private_write_bytes=4096,
            rows=rows,
        )


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("directory", type=Path)
    p.add_argument("--rounds", type=int, default=4)
    p.add_argument("--method", choices=("clone", "private", "lower-read", "lower-rewrite"), required=True)
    p.add_argument("--expect-fs")
    a = p.parse_args()
    if a.rounds < 1 or not a.directory.is_dir():
        p.error("need an existing directory and positive rounds")
    if a.method.startswith("lower-"):
        print(json.dumps(lower_file(a.method == "lower-rewrite")))
    else:
        from ci_edit_loop import mount_at

        mount = mount_at(a.directory)
        if a.expect_fs and (not mount or mount["fs"] != a.expect_fs):
            p.error("unexpected effective probe mount")
        print(json.dumps(dict(mount=mount, **probe(a.directory, a.rounds, a.method))))
