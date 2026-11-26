"""Measure a file replacement on a scratch volume. Reopening verifies visibility within the same boot."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
from statistics import median
import tempfile
from time import perf_counter_ns


BLOCK_BYTES = 4096
BLOCKS = 64
MAX_ROUNDS = 64


def measure(directory=None, rounds=8):
    """Create and remove only a private child of directory, or of the system temp directory."""
    if type(rounds) is not int or not 1 <= rounds <= MAX_ROUNDS:
        raise ValueError(f"rounds must be between 1 and {MAX_ROUNDS}")
    samples = []
    with tempfile.TemporaryDirectory(dir=directory, prefix="micropod-volume-") as owned:
        root = Path(owned)
        directory_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            volume_device = os.fstat(directory_fd).st_dev
            published = root / "published"
            staged = root / "staged"
            # Start with an acknowledged directory entry, so each sample measures a replacement.
            with published.open("xb") as initial:
                initial.write(b"initial")
                initial.flush()
                os.fsync(initial.fileno())
            os.fsync(directory_fd)
            for index in range(rounds):
                seed = f"micropod-volume-v1-{index}".encode()
                payload = hashlib.shake_256(seed).digest(BLOCKS * BLOCK_BYTES)
                expected = hashlib.sha256(payload).hexdigest()
                blocks = memoryview(payload)
                start = perf_counter_ns()
                with staged.open("xb", buffering=0) as output:
                    for offset in range(0, len(blocks), BLOCK_BYTES):
                        if output.write(blocks[offset:offset + BLOCK_BYTES]) != BLOCK_BYTES:
                            raise OSError("short staging file write")
                    written = perf_counter_ns()
                    os.fsync(output.fileno())
                    synced = perf_counter_ns()
                os.replace(staged, published)
                renamed = perf_counter_ns()
                os.fsync(directory_fd)
                acknowledged = perf_counter_ns()
                actual = hashlib.sha256(published.read_bytes()).hexdigest()
                if expected != actual:
                    raise ValueError(f"reopened file digest mismatch at replacement {index + 1}")
                samples.append({
                    "round": index + 1, "sha256": actual, "write_ns": written - start,
                    "file_fsync_ns": synced - written, "close_and_replace_ns": renamed - synced,
                    "directory_fsync_ns": acknowledged - renamed, "acknowledged_ns": acknowledged - start,
                })
        finally:
            os.close(directory_fd)
    return {
        "workload": "micropod-volume-v1", "system": platform.system(), "release": platform.release(),
        "volume_device": volume_device, "block_bytes": BLOCK_BYTES, "blocks_per_replacement": BLOCKS,
        "rounds": rounds, "logical_bytes_written_in_samples": rounds * BLOCK_BYTES * BLOCKS,
        "median_acknowledged_ns": median(row["acknowledged_ns"] for row in samples),
        "same_boot_readback_verified": True, "crash_survival_tested": False, "samples": samples,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, nargs="?", help="existing parent directory on the target volume")
    parser.add_argument("--rounds", type=int, default=8, help=f"number of replacements (1–{MAX_ROUNDS})")
    args = parser.parse_args()
    try:
        print(json.dumps(measure(args.directory, args.rounds), indent=2))
    except (OSError, ValueError) as error:
        parser.exit(1, f"Volume measurement failed: {error}\n")
