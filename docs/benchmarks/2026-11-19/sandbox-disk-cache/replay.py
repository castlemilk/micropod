"""Rerun the physical Mac disk-stage comparison in a disposable APFS directory."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import tempfile
import time

from build_workers import build

HERE = Path(__file__).resolve().parent
RECORDED = json.loads((HERE / "gamma.json").read_text())
IMAGE = "docker.io/library/alpine:3.19"
INIT = "ghcr.io/apple/containerization/vminit:0.47.0"


def stage_input(source, work):
    fixture = work / "oci"
    blobs = fixture / "content/blobs/sha256"
    blobs.mkdir(parents=True)
    (fixture / "content/ingest").mkdir()
    refs = json.loads((source / "state.json").read_text())

    def copy_blob(digest):
        algorithm, name = digest.split(":")
        assert algorithm == "sha256" and len(name) == 64
        target = blobs / name
        if not target.exists():
            subprocess.run(["cp", "-c", str(source / "content/blobs/sha256" / name), str(target)], check=True)
            checksum = hashlib.sha256()
            with target.open("rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    checksum.update(chunk)
            if checksum.hexdigest() != name:
                raise ValueError("wrong OCI blob hash for " + name)
        return target

    for ref in (IMAGE, INIT):
        pinned = RECORDED["inputs"][ref]
        if refs.get(ref, {}).get("digest") != pinned["index"]:
            raise ValueError(f"{ref} must be present at {pinned['index']}")
        copy_blob(pinned["index"])
        manifest = json.loads(copy_blob(pinned["manifest"]).read_text())
        copy_blob(manifest["config"]["digest"])
        for layer in manifest["layers"]:
            copy_blob(layer["digest"])
    (fixture / "state.json").write_text(json.dumps({ref: refs[ref] for ref in (IMAGE, INIT)}))
    return fixture


def cpu_time():
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return usage.ru_utime + usage.ru_stime


def verify_private_writes(cache, successful):
    bases = list((cache / "images").glob("*.ext4"))
    assert len(bases) == 1 and successful
    clones = [cache / f"clone-{i}.ext4" for i in successful]

    def prefix(path):
        with path.open("rb") as f:
            return f.read(16)

    original = prefix(bases[0])
    marker = b"isolated write!!"
    assert original != marker and all(prefix(c) == original for c in clones)
    with clones[0].open("r+b") as f:
        f.write(marker)
    assert prefix(clones[0]) == marker and prefix(bases[0]) == original
    assert all(prefix(c) == original for c in clones[1:])
    for clone in cache.glob("clone-*.ext4"):
        clone.unlink()


def batch(work, cache, fixture, variant, clients, phase, full_agent=False):
    workers = []
    load = os.getloadavg()[0]
    cpu_start = cpu_time()
    with tempfile.TemporaryDirectory(dir=work) as directory:
        barrier = Path(directory)
        try:
            for i in range(clients):
                workers.append(subprocess.Popen(
                    [str(work / variant), str(cache), str(i), IMAGE, str(fixture), str(barrier)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                    env=dict(os.environ, MICROPOD_BENCH_FULL_AGENT=str(int(full_agent))),
                ))
            deadline = time.monotonic() + 60
            while len(list(barrier.glob("ready-*"))) != clients:
                if time.monotonic() > deadline or any(p.poll() is not None for p in workers):
                    raise RuntimeError("a worker failed to reach the start barrier")
                time.sleep(.001)
            start = time.perf_counter()
            (barrier / "go").touch()
            outputs = [p.communicate(timeout=90) for p in workers]
            elapsed = time.perf_counter() - start
            cpu = cpu_time() - cpu_start
        finally:
            for worker in workers:
                if worker.poll() is None:
                    worker.kill()
                    worker.wait()

    image = RECORDED["inputs"][IMAGE]["members"]
    init = RECORDED["inputs"][INIT]["members"]["sbin/vminitd"]
    expected = " ".join(["verified", image["version"], image["bin/busybox"]["sha256"],
                         init["sha256" if full_agent else "first_4096_sha256"]])
    failures, successful, lines = [], [], []
    for i, (worker, (stdout, stderr)) in enumerate(zip(workers, outputs)):
        lines.extend(stdout.splitlines())
        if worker.returncode or stdout.splitlines().count(expected) != 1:
            failures.append(dict(worker=i, exit=worker.returncode, error=stderr.strip() or "file digest mismatch"))
        else:
            successful.append(i)
    verify_private_writes(cache, successful)
    counts = [sum(line.startswith(prefix) for line in lines) for prefix in ("unpacking ", "preparing initfs ")]
    if phase == "warm" or variant == "after":
        expected_count = 0 if phase == "warm" else 1
        if failures or counts != [expected_count, expected_count]:
            raise RuntimeError((phase, variant, counts, failures))
    return dict(variant=variant, phase=phase, clients=clients, seconds=round(elapsed, 6),
                cpu_seconds=round(cpu, 6), load_1m=load, rootfs_unpacks=counts[0],
                initfs_unpacks=counts[1], verified=len(successful), failures=failures)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=HERE.parents[3])
    parser.add_argument("--store", type=Path, default=Path.home() / "Library/Application Support/com.apple.container")
    parser.add_argument("--baseline", default=RECORDED["base_commit"])
    parser.add_argument("--candidate", default="HEAD")
    parser.add_argument("--rounds", type=int, default=8)
    parser.add_argument("--clients", nargs="+", type=int, default=[1, 4, 8, 16])
    parser.add_argument("--out", type=Path, required=True)
    opt = parser.parse_args()
    if opt.rounds < 1 or min(opt.clients) < 1 or len(set(opt.clients)) != len(opt.clients):
        parser.error("rounds and clients must be positive and client levels distinct")
    rows = []
    with tempfile.TemporaryDirectory(prefix="micropod-disk-bench-") as temp:
        work = Path(temp)
        fixture = stage_input(opt.store, work)
        build(opt.repo.resolve(), work, opt.baseline, opt.candidate)
        for variant in ("before", "after"):
            with tempfile.TemporaryDirectory(dir=work) as cache:
                batch(work, Path(cache), fixture, variant, 1, "cold", full_agent=True)
        for block in range(opt.rounds):
            offset = block % len(opt.clients)
            for clients in opt.clients[offset:] + opt.clients[:offset]:
                variants = ("before", "after")
                if (block + opt.clients.index(clients)) % 2:
                    variants = tuple(reversed(variants))
                for variant in variants:
                    with tempfile.TemporaryDirectory(dir=work) as cache:
                        for phase in ("cold", "warm"):
                            result = batch(work, Path(cache), fixture, variant, clients, phase)
                            rows.append(dict(round=block + 1, **result))
                            print(json.dumps(rows[-1]), flush=True)
                            opt.out.write_text(json.dumps(rows, indent=2) + "\n")


if __name__ == "__main__":
    main()
