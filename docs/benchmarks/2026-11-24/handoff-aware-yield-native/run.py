"""Build both native relay arms in a temporary tree and run only the bounded socketpair check."""
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
REVISION = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
RELAY_C = Path("Sources/CPublishedTCP/PublishedTCP.c")
HEADER = Path("Sources/CPublishedTCP/include/PublishedTCP.h")
RELAY_SWIFT = Path("Sources/MicropodRuntime/NativeLoopbackRelay.swift")
MAIN = HERE.parent / "batch12-handoff/relay-main.swift"
UPSTREAM = HERE.parent / "handoff-aware-yield"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(tree, shim, bridge, c_source, swift_sources, name):
    module = tree / name
    module.mkdir()
    (module / "module.modulemap").write_text(f'module CPublishedTCP {{ header "{bridge}" export * }}\n')
    shutil.copy2(tree / HEADER, module / HEADER.name)
    if shim:
        shutil.copy2(HERE / shim, module / shim)
    obj = module / "relay.o"
    subprocess.run(["xcrun", "clang", "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
                    "-DMICROPOD_BENCH_FIXED_RELAY_BUDGET=1", "-I", module, "-I", tree / RELAY_C.parent,
                    "-c", c_source, "-o", obj], check=True)
    binary = module / "relay"
    subprocess.run(["xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library",
                    "-module-cache-path", tree / "modules", "-I", module, *swift_sources,
                    obj, "-o", binary], check=True)
    return binary


def check_ordering(tree):
    # Apply the earlier workload changes only. The C transport in this tree is
    # already the native candidate and is compiled unchanged into this fixture.
    fixture = Path("scripts/relaybench/callback_handoff_work.c")
    for name in (fixture, fixture.with_name("filter_work.c")):
        path = tree / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(subprocess.check_output(["git", "show", f"{REVISION}:{name}"], cwd=ROOT))
    header = f"--- a/{fixture}\n".encode()
    _, separator, changes = (UPSTREAM / "experiment.patch").read_bytes().partition(header)
    if not separator:
        raise ValueError("missing upstream workload patch")
    subprocess.run(["patch", "-s", "-F", "0", "-p1"], input=separator + changes, cwd=tree, check=True)
    subprocess.run(["patch", "-s", "-F", "0", "-p1", "-i", HERE / "ordering-adapter.patch"], cwd=tree, check=True)
    binary = tree / "ordering"
    subprocess.run(["xcrun", "clang", "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-fblocks",
                    "-DMICROPOD_BENCH_FIXED_RELAY_BUDGET=1", "-I", tree / HEADER.parent,
                    tree / fixture, "-o", binary], check=True)
    reference = json.loads((UPSTREAM / "result.json").read_text())
    order = ["control", "candidate", "candidate", "control"]
    if reference["arm_order"] != order or len(reference["raw_passes"]) != len(order):
        raise ValueError("unexpected upstream sweep order")
    passes = []
    for arm, expected in zip(order, reference["raw_passes"]):
        rows = [json.loads(line) for line in subprocess.check_output([binary, arm], text=True, timeout=25).splitlines()]
        # The demonstration counted an internal early-return branch. The native
        # candidate has no such instrumentation; compare all observable outcomes.
        observations = [{k: v for k, v in row.items() if k != "handoff_yields"} for row in expected]
        if rows != observations:
            raise ValueError(f"{arm} ordering differs from upstream: {rows}")
        passes.append(rows)
    return dict(upstream_sha256=sha(UPSTREAM / "result.json"), order=order, raw_passes=passes)


def run():
    with tempfile.TemporaryDirectory(prefix="mp-native-handoff-") as tmp:
        tree = Path(tmp)
        for name in (RELAY_C, HEADER, RELAY_SWIFT):
            path = tree / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(subprocess.check_output(["git", "show", f"{REVISION}:{name}"], cwd=ROOT))
        before = {str(p): sha(tree / p) for p in (RELAY_C, HEADER, RELAY_SWIFT)}
        build(tree, None, HEADER.name, tree / RELAY_C, [tree / RELAY_SWIFT, MAIN], "stock")
        subprocess.run(["patch", "-s", "-F", "0", "-p1", "-i", HERE / "candidate.patch"], cwd=tree, check=True)
        after = {str(p): sha(tree / p) for p in (RELAY_C, HEADER, RELAY_SWIFT)}
        build(tree, None, HEADER.name, tree / RELAY_C, [tree / RELAY_SWIFT, MAIN], "candidate")
        # Swift private nested types can be exercised by a same-file extension.
        # The separate baseline and candidate builds above have no test extension.
        checked = tree / "CheckedRelay.swift"
        checked.write_bytes((tree / RELAY_SWIFT).read_bytes() + b"\n" + (HERE / "NativeCheck.swift").read_bytes())
        binary = build(tree, "Fixture.h", "Fixture.h", HERE / "Fixture.c", [checked], "check")
        runs = [json.loads(subprocess.check_output([binary], text=True, timeout=20)) for _ in range(2)]
        ordering = check_ordering(tree)
    return dict(tier="Darwin native Swift dispatch and C, bounded AF_UNIX fixed work",
                source_revision=REVISION, source_sha256=before, candidate_source_sha256=after,
                benchmark_files={p: sha(HERE / p) for p in
                                 ("candidate.patch", "Fixture.h", "Fixture.c", "NativeCheck.swift",
                                  "ordering-adapter.patch", "run.py")},
                relay_main=str(MAIN.relative_to(ROOT)), relay_main_sha256=sha(MAIN),
                host=[platform.machine(), platform.mac_ver()[0]],
                swift=subprocess.check_output(["xcrun", "swiftc", "--version"], text=True).splitlines()[0],
                clang=subprocess.check_output(["xcrun", "clang", "--version"], text=True).splitlines()[0],
                compiled_arms=["stock", "candidate"], fixed_budget_define=1, native_runs=runs, ordering=ordering)


if __name__ == "__main__":
    print(json.dumps(run(), indent=2))
