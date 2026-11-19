#!/usr/bin/env python3
"""Compare production SharedView.build and rsync on the same APFS source fixture."""
import argparse
import concurrent.futures
import hashlib
import json
import os
import random
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

SWIFT = """import Foundation
@main struct Bench {
    static func main() throws {
        let paths = CommandLine.arguments.dropFirst().map { URL(fileURLWithPath: $0) }
        guard paths.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        try SharedView.build(source: paths[0], root: paths[1])
    }
}
"""
ATTR = "com.micropod.benchmark"


def run(argv):
    return subprocess.run(argv, check=True, capture_output=True, timeout=180, text=True).stdout.strip()


def sha(path):
    with path.open("rb") as f:
        h = hashlib.sha256()
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
        return h.hexdigest()


def compile_view(root, output, main):
    src = root / "Sources/MicropodSharedFS"
    files = [src / "SharedView.swift"]
    for optional in ["SharedFSStaging.swift", "ChunkHash.swift"]:
        if (src / optional).is_file():
            files.append(src / optional)
    run(["xcrun", "swiftc", "-O", "-module-cache-path", output.parent / "swift-cache", "-o", output, *files, main])
    return {p.name: sha(p) for p in files}


def make_source(root, filtered):
    root.mkdir()
    for i in range(128):
        target = root / f"pkg-{i % 8}/item-{i}"
        target.parent.mkdir(exist_ok=True)
        target.write_bytes(hashlib.shake_256(str(i).encode()).digest(4096))
    (root / "payload").write_bytes(hashlib.shake_256(b"payload").digest(8 << 20))
    (root / "link").symlink_to("pkg-0/item-0")
    (root / "empty").touch()
    (root / "omitted").mkdir()
    (root / "omitted/sentinel").write_text("ignore this when a filter is configured")
    if filtered:
        (root / ".syncignore").write_text("omitted\n")
    marker = root / "pkg-0/item-0"
    marker.chmod(0o751)
    os.utime(marker, (1700000000, 1700000000))
    run(["/usr/bin/xattr", "-w", ATTR, "marker", marker])
    return manifest(root, filtered)


def manifest(root, filtered=False):
    out = {}
    for p in root.rglob("*"):
        name = p.relative_to(root).as_posix()
        if filtered and name.split("/")[0] == "omitted":
            continue
        out[name] = ("link:" + os.readlink(p) if p.is_symlink() else "dir" if p.is_dir() else sha(p))
    return out


def verify(view, expected):
    actual = manifest(view)
    errors = []
    if actual != expected:
        errors += ["missing:" + key for key in sorted(expected.keys() - actual.keys())]
        errors += ["extra:" + key for key in sorted(actual.keys() - expected.keys())]
        errors += ["mismatch:" + k for k in sorted(actual.keys() & expected.keys()) if actual[k] != expected[k]]
    marker = view / "pkg-0/item-0"
    if marker.is_file():
        if marker.stat().st_mode & 0o777 != 0o751:
            errors.append("mode")
        if marker.stat().st_mtime_ns != 1700000000 * 10**9:
            errors.append("mtime")
        if ATTR not in run(["/usr/bin/xattr", marker]).splitlines() or run(["/usr/bin/xattr", "-p", ATTR, marker]) != "marker":
            errors.append("xattr")
    return errors


def batch(engine, tool, work, source, filtered, expected, clients):
    with tempfile.TemporaryDirectory(dir=work) as tmp:
        views = [Path(tmp) / f"view-{i}" for i in range(clients)]
        def create(view):
            argv = (["/usr/bin/rsync", "-aE", *(["--exclude=/omitted"] if filtered else []), str(source)+"/", view]
                    if engine == "rsync" else [tool, source, view])
            run(argv)
        started = time.perf_counter()
        with concurrent.futures.ThreadPoolExecutor(clients) as pool:
            list(pool.map(create, views))
        elapsed = time.perf_counter() - started
        differences = [verify(view, expected) for view in views]
        if not any(differences):
            (views[0] / "payload").write_bytes(b"private change")
            if sha(source / "payload") != expected["payload"] or (clients > 1 and sha(views[-1] / "payload") != expected["payload"]):
                differences[0].append("view write changed source or peer")
        return dict(seconds=round(elapsed, 6), first_errors=next((d for d in differences if d), []),
                    verified=sum(not d for d in differences), clients=clients, engine=engine, filtered=filtered)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tree", type=Path, default=Path(__file__).resolve().parents[1])
    ap.add_argument("--candidate-tree", type=Path)
    ap.add_argument("--json", type=Path, required=True)
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--clients", nargs="+", type=int, default=[1, 4, 8, 16])
    args = ap.parse_args()
    machine = json.loads(run(["system_profiler", "SPHardwareDataType", "-json"]))["SPHardwareDataType"][0]
    data = dict(macos=run(["sw_vers", "-productVersion"]), hardware=machine.get("machine_model"),
                chip=machine.get("chip_type"), arch=run(["uname", "-m"]), cpu=os.cpu_count(),
                memory=machine.get("physical_memory"), rsync=run(["/usr/bin/rsync", "--version"]).splitlines()[0],
                swift=run(["swift", "--version"]).splitlines()[0], sources={}, rounds=args.rounds,
                seed=20261119, warmups=[], blocks=[], summary=[], start_utc=time.strftime("%FT%TZ", time.gmtime()))
    def save():
        staged = args.json.with_suffix(".tmp")
        staged.write_text(json.dumps(data, indent=2)+"\n")
        staged.replace(args.json)
    with tempfile.TemporaryDirectory(prefix="mp-snap-matrix-") as tmp:
        work = Path(tmp)
        main = work / "Bench.swift"
        main.write_text(SWIFT)
        bins = {"rsync": Path("/usr/bin/rsync"), "micropod": work / "current"}
        for name, root in [("micropod", args.tree), ("candidate", args.candidate_tree)]:
            if root:
                target = work / name
                data["sources"][name] = compile_view(root, target, main)
                bins[name] = target
        rng = random.Random(data["seed"])
        for filtered in [False, True]:
            source = work / ("filtered" if filtered else "whole")
            expected = make_source(source, filtered)
            active = []
            for e, tool in bins.items():
                r = batch(e, tool, work, source, filtered, expected, 1)
                data["warmups"].append(r)
                if r["verified"] == 1:
                    active.append(e)
                print("warmup", e, filtered, r["first_errors"], flush=True)
                save()
            for n in args.clients:
                for i in range(args.rounds):
                    rng.shuffle(active)
                    for e in active:
                        r = batch(e, bins[e], work, source, filtered, expected, n)
                        r["block"] = i + 1
                        data["blocks"].append(r)
                        print(e, filtered, n, r["verified"], r["seconds"], flush=True)
                        save()
                for e in active:
                    rows = [r for r in data["blocks"] if (r["engine"],r["filtered"],r["clients"]) == (e,filtered,n)]
                    if all(r["verified"] == n for r in rows):
                        samples = [r["seconds"] for r in rows]
                        data["summary"].append(dict(engine=e, filtered=filtered, clients=n, p50_s=statistics.median(samples),
                                                    min_s=min(samples), max_s=max(samples), verified_views=n*len(samples)))
                        save()
    return int(any(row["verified"] != row["clients"] for row in data["warmups"] + data["blocks"]))


if __name__ == "__main__":
    raise SystemExit(main())
