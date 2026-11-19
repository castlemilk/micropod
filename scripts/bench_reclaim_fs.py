#!/usr/bin/env python3
"""What a bundle removal costs on APFS with and without a staged second name.

container-apiserver's containerDelete ends in FileManager.removeItem(bundle)
under its containers lock; volumeDelete does the same for a volume directory.
This reproduces that removal without a runtime: it clonefiles a source image
(an image snapshot, or any large ext4 file) into a fake bundle, dirties
--extents random 4 KiB blocks in it the way a CI job dirties its rootfs,
fsyncs, then times

  inline  removeItem(bundle)                       (today, all under the lock)
  staged  link(rootfs, reclaim) + removeItem(bundle) (under the lock)
          + unlink(reclaim link)                     (PayloadReclaimer, off it)

Rounds alternate inline/staged. Writes only under --work (same APFS volume as
the source). Stdlib only:

  python3 scripts/bench_reclaim_fs.py --source \\
    ~/Library/Application\\ Support/com.apple.container/snapshots/<digest>/snapshot \\
    --work /tmp/reclaim-fs --extents 16000 --rounds 3
"""

import argparse
import ctypes
import ctypes.util
import json
import os
import random
import shutil
import statistics
import time

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libc.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]


def clonefile(src, dst):
    if libc.clonefile(src.encode(), dst.encode(), 0) != 0:
        errno = ctypes.get_errno()
        raise OSError(errno, os.strerror(errno), dst)


def make_bundle(source, work, extents, span):
    bundle = os.path.join(work, f"bundle-{time.time_ns()}")
    os.makedirs(bundle)
    rootfs = os.path.join(bundle, "rootfs.ext4")
    clonefile(source, rootfs)
    for name in ("config.json", "options.json", "runtime-configuration.json", "stdio.log", "vminitd.log"):
        with open(os.path.join(bundle, name), "wb") as handle:
            handle.write(os.urandom(4096))
    block = os.urandom(4096)
    rng = random.Random(time.time_ns())
    fd = os.open(rootfs, os.O_WRONLY)
    try:
        for _ in range(extents):
            os.pwrite(fd, block, rng.randrange(0, span // 4096) * 4096)
        os.fsync(fd)
    finally:
        os.close(fd)
    return bundle, rootfs


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", required=True, help="a large file to clone (same APFS volume as --work)")
    parser.add_argument("--work", required=True)
    parser.add_argument("--extents", type=int, default=16000, help="random 4 KiB blocks dirtied per bundle")
    parser.add_argument("--span-gib", type=float, default=2.5, help="dirty blocks land in the first N GiB")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--pause", type=float, default=5)
    args = parser.parse_args()
    os.makedirs(args.work, exist_ok=True)
    reclaim = os.path.join(args.work, "reclaim")
    os.makedirs(reclaim, exist_ok=True)
    span = int(args.span_gib * (1 << 30))
    results = {"inline": [], "staged_lock": [], "staged_background": []}
    for round_ in range(args.rounds):
        for mode in ("inline", "staged"):
            bundle, rootfs = make_bundle(args.source, args.work, args.extents, span)
            row = {"round": round_, "mode": mode, "extents": args.extents}
            if mode == "inline":
                started = time.monotonic()
                shutil.rmtree(bundle)
                row["lock_s"] = round(time.monotonic() - started, 4)
                results["inline"].append(row["lock_s"])
            else:
                link = os.path.join(reclaim, f"{time.time_ns()}-rootfs.ext4")
                started = time.monotonic()
                os.link(rootfs, link)
                shutil.rmtree(bundle)
                row["lock_s"] = round(time.monotonic() - started, 4)
                started = time.monotonic()
                os.unlink(link)
                row["background_s"] = round(time.monotonic() - started, 4)
                results["staged_lock"].append(row["lock_s"])
                results["staged_background"].append(row["background_s"])
            print(json.dumps(row), flush=True)
            time.sleep(args.pause)
    for key, values in results.items():
        if values:
            print(f"{key:<18} p50 {statistics.median(values):7.3f}s  max {max(values):7.3f}s  (n={len(values)})")


if __name__ == "__main__":
    main()
