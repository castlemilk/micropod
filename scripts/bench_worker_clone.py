"""Time the Mac worker's clonefile primitive and verify private writes to sibling clones."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import platform
from statistics import median
import tempfile
from time import perf_counter_ns


def measure(directory):
    clone = ctypes.CDLL(None, use_errno=True).clonefile
    clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    clone.restype = ctypes.c_int
    size = 512 << 20
    chunk = b"A" * (1 << 20)
    base = directory / "base.raw"
    with base.open("wb") as output:
        output.truncate(size)
        for offset in range(0, size, 16 << 20):
            output.seek(offset)
            output.write(chunk)
        output.flush()
        os.fsync(output.fileno())
    samples = []
    for n in range(16):
        target = directory / f"clone-{n}.raw"
        start = perf_counter_ns()
        if clone(os.fsencode(base), os.fsencode(target), 0):
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        cloned = perf_counter_ns()
        with target.open("r+b", buffering=0) as output:
            output.write(bytes([n]) * 4096)
            os.fsync(output.fileno())
        samples.append({"clone_us": (cloned - start) / 1000,
                        "private_write_fsync_us": (perf_counter_ns() - cloned) / 1000})
    images = [(base, b"A")]
    images.extend((directory / f"clone-{n}.raw", bytes([n])) for n in range(len(samples)))
    for path, marker in images:
        with path.open("rb") as disk:
            if disk.read(4096) != marker * 4096 or disk.read(4096) != chunk[:4096] or path.stat().st_size != size:
                raise ValueError(f"unexpected data or size in {path.name}")
    return {"primitive": "clonefile", "host_os": platform.mac_ver()[0], "base_bytes": size,
            "base_payload_bytes": size // 16, "private_write_bytes": 4096, "rounds": samples,
            "median_clone_us": median(s["clone_us"] for s in samples),
            "median_private_write_fsync_us": median(s["private_write_fsync_us"] for s in samples),
            "base_and_sibling_markers_verified": True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="an existing directory on the target APFS volume")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(dir=args.directory) as scratch:
        print(json.dumps(measure(Path(scratch)), indent=2))
