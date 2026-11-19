#!/usr/bin/env python3
"""Measure pnpm store reuse across real, offline installs on a single local filesystem."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import tarfile
import tempfile
import time


def benchmark(root, counts):
    exe = shutil.which("pnpm")
    if not exe:
        raise ValueError("Install pnpm before running this benchmark")
    version = subprocess.check_output([exe, "--version"], text=True).strip()
    env = {**os.environ, "CI": "true", "XDG_CONFIG_HOME": str(root / "config"),
           "XDG_DATA_HOME": str(root / "data"), "XDG_CACHE_HOME": str(root / "cache"),
           "PNPM_HOME": str(root / "pnpm-home")}
    package = "micropod-storage-fixture"
    archive = root / "fixture.tgz"
    expected = {}
    chunk = 256 * 1024
    rng = random.Random(210)
    with tarfile.open(archive, "w:gz", compresslevel=1) as tar:
        def add(name, data):
            info = tarfile.TarInfo("package/" + name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        add("package.json", json.dumps({"name": package, "version": "1.0.0"}).encode())
        for i in range(32):
            name, data = f"payload-{i}.bin", rng.getrandbits(8 * chunk).to_bytes(chunk, "little")
            add(name, data)
            expected[name] = hashlib.sha256(data).digest()
    methods = ["copy", "hardlink"]
    samples = {method: [] for method in methods}
    ids = {method: set() for method in methods}
    stores = {}
    rows = []
    for method in methods:
        store = root / ("store-" + method)
        store.mkdir()
        stores[method] = store

    def install(method, name):
        project = root / name
        project.mkdir()
        (project / "package.json").write_text(json.dumps({"name": "worker", "private": True, "version": "1.0.0",
                                                          "dependencies": {package: "file:../fixture.tgz"}}))
        (project / "pnpm-workspace.yaml").write_text("enableGlobalVirtualStore: false\n")
        argv = [exe, "install", "--offline", "--ignore-scripts", "--no-frozen-lockfile",
                "--package-import-method", method, "--store-dir", str(stores[method]), "--reporter=silent"]
        started = time.perf_counter()
        p = subprocess.run(argv, cwd=project, env=env, capture_output=True, text=True, timeout=60)
        elapsed = time.perf_counter() - started
        if p.returncode:
            raise RuntimeError(f"pnpm install failed with {p.returncode}: {p.stderr[-400:]} {p.stdout[-400:]}")
        files = set()
        for path, digest in expected.items():
            file = project / "node_modules" / package / path
            if hashlib.sha256(file.read_bytes()).digest() != digest:
                raise ValueError(f"Incorrect installed payload in {file}")
            st = file.stat()
            files.add((st.st_dev, st.st_ino))
        return elapsed, files

    for method in methods:
        install(method, "prewarm-" + method)
    store_ids = {}
    for method, store in stores.items():
        digests = set(expected.values())
        matches = {}
        for file in store.rglob("*"):
            if file.is_file() and file.stat().st_size == chunk:
                digest = hashlib.sha256(file.read_bytes()).digest()
                if digest in digests:
                    st = file.stat()
                    matches[digest] = (st.st_dev, st.st_ino)
        if set(matches) != digests:
            raise ValueError(f"Could not verify the 32 warmed store payloads for {method}")
        store_ids[method] = set(matches.values())
    for n in range(1, max(counts) + 1):
        for method in (methods if n % 2 else list(reversed(methods))):
            elapsed, inodes = install(method, f"{method}-{n}")
            ids[method].update(inodes)
            samples[method].append(round(elapsed, 6))
            if n in counts:
                observed = len(ids[method] | store_ids[method])
                required = 32 if method == "hardlink" else 32 * (n + 1)
                if observed != required:
                    raise ValueError(f"{method} at {n} projects: {observed} distinct payload inodes, expected {required}")
                rows.append(dict(method=method, workspaces=n, files_per_project=32, store_and_project_payload_inodes=observed,
                                 unique_inode_payload_mib=observed * chunk / (1024 * 1024),
                                 median_install_seconds=round(statistics.median(samples[method]), 6)))
    return dict(pnpm=version, system=platform.system(), arch=platform.machine(), fixture_mib=8, rows=rows,
                warm_install_seconds=samples, passed=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--scratch", type=Path, help="Parent directory on the filesystem to measure")
    p.add_argument("--json", type=Path)
    args = p.parse_args()
    with tempfile.TemporaryDirectory(prefix="micropod-pnpm-", dir=args.scratch) as tmp:
        result = benchmark(Path(tmp).resolve(), (1, 4, 8, 16))
    data = json.dumps(result, indent=2)
    if args.json:
        args.json.write_text(data + "\n")
    print(data)
