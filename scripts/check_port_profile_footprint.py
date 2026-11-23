"""Read actual macOS footprint counters for one private child, then remove the sampler."""
import hashlib
import json
import platform
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile


SOURCE = Path(__file__).with_name("port_profile_rusage.c")
CHILD = """
import mmap, sys
print("idle", flush=True)
for op in sys.stdin:
    if op.strip() == "touch":
        mapping = mmap.mmap(-1, 8 * 1024**2, flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS)
        for offset in range(0, len(mapping), mmap.PAGESIZE):
            mapping[offset] = 1
    elif op.strip() == "release":
        mapping.close()
    else:
        raise SystemExit(2)
    print(op.strip(), flush=True)
"""


def main():
    with tempfile.TemporaryDirectory(prefix="mp-footprint-") as tmp:
        sampler = Path(tmp) / "read-usage"
        subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-O2", SOURCE, "-o", sampler],
                       check=True, timeout=30)
        child = subprocess.Popen([sys.executable, "-B", "-c", CHILD], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 text=True)
        samples = {}
        try:
            with selectors.DefaultSelector() as ready:
                ready.register(child.stdout, selectors.EVENT_READ)
                args = [sampler, str(child.pid)]
                for phase in ("idle", "touch", "release"):
                    if phase != "idle":
                        child.stdin.write(phase + "\n")
                        child.stdin.flush()
                    if not ready.select(5) or child.stdout.readline().strip() != phase:
                        raise RuntimeError(f"child failed to reach {phase}")
                    samples[phase] = json.loads(subprocess.check_output(args, timeout=3))
                    if phase == "idle":
                        args.append(str(samples["idle"]["start_ticks"]))
                stale = subprocess.run([sampler, str(child.pid), str(samples["idle"]["start_ticks"] + 1)],
                                       capture_output=True, timeout=3)
                if stale.returncode != 1 or stale.stdout:
                    raise ValueError("sampler accepted a stale process identity")
        finally:
            child.stdin.close()
            if child.poll() is None:
                child.kill()
            child.wait(timeout=3)
            child.stdout.close()

    idle, touch, release = samples.values()
    if not (all(row["pid"] == child.pid and row["start_ticks"] == idle["start_ticks"] for row in samples.values())
            and idle["start_ticks"] < idle["sample_ticks"] < touch["sample_ticks"] < release["sample_ticks"]
            and idle["phys_footprint_bytes"] < touch["phys_footprint_bytes"] > release["phys_footprint_bytes"]
            and all(row["phys_footprint_bytes"] <= row["lifetime_max_phys_footprint_bytes"] for row in samples.values())
            and idle["lifetime_max_phys_footprint_bytes"] <= touch["lifetime_max_phys_footprint_bytes"]
            <= release["lifetime_max_phys_footprint_bytes"]):
        raise ValueError(f"inconsistent process readback: {samples}")
    print(json.dumps({"scope": "private same-boot process; anonymous private mapping", "mapped_bytes": 8 * 1024**2,
                      "macos": platform.mac_ver()[0], "architecture": platform.machine(),
                      "sampler_source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
                      "stale_start_rejected": True, "samples": samples}, indent=2))


if __name__ == "__main__":
    main()
