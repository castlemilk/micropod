"""Compare the same 4 KiB edits on an APFS clone and an independently written file.

Each arm uses one disposable 1 MiB file, with eight edits and a second rewrite
of the same eight offsets. Each edit is followed by fsync. The local run uses
Darwin background thread QoS. No VM, disk image, or package cache is opened.
"""
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import random
from statistics import median
import tempfile
from time import perf_counter_ns

from bench_pnpm_storage import APFSAllocation


BLOCK = 4096
FILE_BYTES = 1024 * 1024
EDITS = 8
CASES = ("clone-adjacent", "private-adjacent", "clone-spaced", "private-spaced")


def schedule(rounds, seed):
    if type(rounds) is not int or rounds not in (4, 8):
        raise ValueError("use four or eight balanced rounds")
    rng = random.Random(seed)
    cases = list(CASES)
    orders = []
    for _ in range(rounds // 4):
        rng.shuffle(cases)
        rotations = [cases[i:] + cases[:i] for i in range(4)]
        rng.shuffle(rotations)
        orders.extend(rotations)
    return orders


def write_synced(path, data):
    with path.open("xb") as fd:
        fd.write(data)
        fd.flush()
        os.fsync(fd.fileno())


def run_case(root, baseline, case, number, clone, allocation):
    source, target = root / "base", root / "trial"
    family_before = allocation.read(source)[1]
    kind, layout = case.split("-")
    if kind == "clone":
        if clone(os.fsencode(source), os.fsencode(target), 0) != 0:
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code))
    else:
        write_synced(target, baseline)
    try:
        private_before, family = allocation.read(target)
        if target.stat().st_ino == source.stat().st_ino or ((family == family_before) != (kind == "clone")):
            raise ValueError("clone-family or inode identity does not match the assigned arm")
        if (kind == "clone" and private_before != 0) or (kind == "private" and private_before < FILE_BYTES):
            raise ValueError("trial did not start with the intended private/shared allocation")
        start_block = (number - 1) * 4
        offsets = [BLOCK * (start_block + i * (1 if layout == "adjacent" else 16)) for i in range(EDITS)]
        expected = bytearray(baseline)
        start_blocks = target.stat().st_blocks
        passes = []
        with target.open("r+b", buffering=0) as file:
            for pass_number in (1, 2):
                writes, fsyncs, allocation_after = [], [], []
                for index, offset in enumerate(offsets):
                    # Both layouts and both backing types receive identical bytes and sync calls.
                    data = hashlib.shake_256(f"{number}/{pass_number}/{index}".encode()).digest(BLOCK)
                    start = perf_counter_ns()
                    written = os.pwrite(file.fileno(), data, offset)
                    end_write = perf_counter_ns()
                    if written != BLOCK:
                        raise OSError("short pwrite")
                    os.fsync(file.fileno())
                    end_fsync = perf_counter_ns()
                    writes.append(end_write - start)
                    fsyncs.append(end_fsync - end_write)
                    expected[offset:offset + BLOCK] = data
                    allocation_after.append(allocation.read(target)[0])
                actual = target.read_bytes()
                if actual != expected or source.read_bytes() != baseline:
                    raise ValueError("original bytes, edited bytes or untouched region diverged")
                passes.append({"pass": pass_number, "pwrite_ns": writes, "fsync_ns": fsyncs,
                               "private_bytes_after_each_fsync": allocation_after,
                               "target_sha256": hashlib.sha256(actual).hexdigest(),
                               "target_st_blocks_512b": target.stat().st_blocks})
        return {"round": number, "case": case, "offsets": offsets, "initial_private_bytes": private_before,
                "initial_st_blocks_512b": start_blocks, "passes": passes}
    finally:
        target.unlink()


def summarize(rows):
    result = {}
    for case in CASES:
        metrics = {"first_private_growth_bytes": [], "rewrite_private_growth_bytes": [],
                   "first_eight_pwrite_fsync_ms": [], "rewrite_eight_pwrite_fsync_ms": []}
        for row in rows:
            if row["case"] != case:
                continue
            before = row["initial_private_bytes"]
            for label, phase in zip(("first", "rewrite"), row["passes"]):
                after = phase["private_bytes_after_each_fsync"][-1]
                metrics[f"{label}_private_growth_bytes"].append(after - before)
                metrics[f"{label}_eight_pwrite_fsync_ms"].append((sum(phase["pwrite_ns"]) + sum(phase["fsync_ns"])) / 1e6)
                before = after
        result[case] = {key: median(values) for key, values in metrics.items()}
    return result


def measure(parent=None, rounds=4, seed=23802):
    orders = schedule(rounds, seed)
    if platform.system() != "Darwin":
        raise ValueError("requires macOS and an APFS scratch filesystem with clone-family/private-size reporting")
    libc = ctypes.CDLL(None, use_errno=True)
    # QOS_CLASS_BACKGROUND from the macOS sys/qos.h header.
    old_qos, old_relative = ctypes.c_uint(), ctypes.c_int()
    libc.pthread_self.restype = ctypes.c_void_p
    libc.pthread_get_qos_class_np.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_int)]
    if libc.pthread_get_qos_class_np(libc.pthread_self(), ctypes.byref(old_qos), ctypes.byref(old_relative)) != 0:
        raise RuntimeError("could not read Darwin thread QoS")
    if libc.pthread_set_qos_class_self_np(9, 0) != 0 or libc.qos_class_self() != 9:
        raise RuntimeError("could not enter Darwin background thread QoS")
    try:
        clone = libc.clonefile
        clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
        clone.restype = ctypes.c_int
        allocation = APFSAllocation()
        baseline = hashlib.shake_256(b"micropod-dense-apfs-v1").digest(FILE_BYTES)
        start = datetime.now(timezone.utc).isoformat()
        with tempfile.TemporaryDirectory(prefix="micropod-cow-", dir=parent) as owned:
            root = Path(owned)
            write_synced(root / "base", baseline)
            block_unit = os.statvfs(root).f_frsize
            rows = [run_case(root, baseline, case, i, clone, allocation)
                    for i, order in enumerate(orders, 1) for case in order]
        return {"experiment": "APFS first-touch and rewrite on a dense regular file", "started_utc": start,
                "finished_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                "arch": platform.machine(), "python": platform.python_version(), "qos_class": libc.qos_class_self(),
                "seed": seed, "orders": orders, "file_bytes": FILE_BYTES, "edit_bytes": BLOCK,
                "filesystem_fragment_bytes": block_unit, "source_sha256": hashlib.sha256(baseline).hexdigest(),
                "program_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "scope": "Local APFS scratch, same-boot reread after each pass, 8 separately fsynced edits per pass. Timings exclude allocation sampling, hashing and file preparation. No guest, directory sync, full device flush or restart.",
                "median_over_rounds": summarize(rows), "rows": rows}
    finally:
        libc.pthread_set_qos_class_self_np(old_qos.value, old_relative.value)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch", type=Path, help="existing APFS parent, default system temporary directory")
    parser.add_argument("--rounds", type=int, choices=(4, 8), default=4)
    parser.add_argument("--seed", type=int, default=23802)
    args = parser.parse_args()
    try:
        print(json.dumps(measure(args.scratch, args.rounds, args.seed), indent=2))
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(1, f"APFS first-write measurement failed: {error}\n")
