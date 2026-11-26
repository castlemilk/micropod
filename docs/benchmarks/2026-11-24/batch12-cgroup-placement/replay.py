"""Replay the Linux 7.3.5 fair-group weight calculation on four vCPUs."""
from fractions import Fraction
import gzip
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
PRIOR = HERE.parent / "batch06-trace"
ARCHIVE = HERE.parent.parent / "2026-11-21/gamma-direct-macvlan.json.gz"
FAIR = "d23f85896da9c68cae4f6969c55d8915db51f77b15a3521a4eb8c26c60ce1460"
PRELUDE = "d49335218693e85a8af463b5d1ef967c2cb6eb3faf90b0d8dc11fe94b65ac9a2"
WEIGHTS = "f1dc9a97f4e456c91766fd30fb346b5c43f37972b61aae9e7902e62003fd6c87"
BUDGET = "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976"

# Runnable nice-0 tasks on vCPUs 0 through 3. Both groups share the same
# allowed cpuset; zeros specify runqueue placement inside that set.
CASES = [
    ("spread service, sparse sibling", [1, 1, 1, 1], [1, 0, 0, 0]),
    ("packed service, sparse sibling", [4, 0, 0, 0], [1, 0, 0, 0]),
    ("sparse service, spread sibling", [1, 0, 0, 0], [1, 1, 1, 1]),
    ("sparse service, packed sibling", [1, 0, 0, 0], [4, 0, 0, 0]),
    ("equal sparse groups", [1, 0, 0, 0], [1, 0, 0, 0]),
    ("equally runnable, different placement", [1, 1, 1, 1], [4, 0, 0, 0]),
    ("disjoint runnable placement", [0, 1, 0, 0], [0, 0, 0, 1]),
    ("symmetric spread", [1, 1, 1, 1], [1, 1, 1, 1]),
]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verify(data, expected):
    if digest(data) != expected:
        raise ValueError("source digest mismatch")
    return data


def kernel_header():
    fair = verify(gzip.decompress((HERE / "fair.c.gz").read_bytes()), FAIR).decode()
    start = "static long __calc_smp_shares("
    update = "void __sched_cgroup_mode_update("
    body = fair[fair.index(start):fair.index("\n}", fair.index(update)) + 2]
    header = verify((PRIOR / "group_weight.inc").read_bytes(), PRELUDE).decode().split(start)[0]
    table = struct.unpack("<40i", verify((HERE / "nice-weights.le32").read_bytes(), WEIGHTS))
    return header + "static const int sched_prio_to_weight[] = {" + ",".join(map(str, table)) + "};\n" + body


def archive_budget():
    study = json.loads(gzip.decompress(verify(ARCHIVE.read_bytes(), BUDGET)))["records"]["workers"]["trial"]
    control = {"cpu.max": "400000 100000", "cpuset.cpus.effective": "0-3"}
    if any(study[side][k] != v for side in ("state", "after") for k, v in control.items()):
        raise ValueError("historical publication service CPU budget changed")
    return control


def measure(exe, requests):
    inputs = "".join(" ".join(map(str, r)) + "\n" for r in requests)
    result = subprocess.run([exe], input=inputs, text=True, capture_output=True, timeout=5, check=True)
    weights = list(map(int, result.stdout.splitlines()))
    if len(weights) != len(requests) or min(weights) <= 0:
        raise ValueError("incomplete or invalid group weights")
    return dict(zip(requests, weights, strict=True))


def run():
    requests = {(mode, 4, 1024, sum(group), local) for _, service, sibling in CASES
                for group in (service, sibling) for local in group if local for mode in (2, 3)}
    checks = [(3, 4, 32768, 1, 1), (2, 4, 32768, 1, 1), (2, 1, 1024, 1, 1), (3, 1, 1024, 1, 1)]
    order = sorted(requests | set(checks))
    header = kernel_header()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "kernel.inc").write_text(header)
        exe = root / "probe"
        subprocess.run(["clang", "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-I", root,
                        str(HERE / "probe.c"), "-o", exe], check=True)
        weights = measure(exe, order)
        if measure(exe, list(reversed(order))) != weights:
            raise ValueError("weights depend on mode evaluation order")
    observed = [weights[c] for c in checks]
    if observed != [88761 << 10, 32768 << 10, 1024 << 10, 1024 << 10]:
        raise ValueError(f"unexpected max-mode ceiling or one-CPU control: {observed}")
    rows = []
    for case, service, sibling in CASES:
        local = []
        for cpu, (ns, nb) in enumerate(zip(service, sibling)):
            if not (ns and nb):
                continue
            entry = {"vcpu": cpu}
            for mode, name in [(2, "concur"), (3, "max")]:
                sw = weights[(mode, 4, 1024, sum(service), ns)]
                bw = weights[(mode, 4, 1024, sum(sibling), nb)]
                entry[name] = {"service": sw, "sibling": bw, "ratio": str(Fraction(sw, bw))}
            local.append(entry)
        rows.append({"case": case, "service_runnable": service, "sibling_runnable": sibling, "contested": local})
    # One expected ratio pair per contended vCPU, including the empty case.
    expected = [
        [("1", "1/4")], [("4", "1")], [("1", "4")], [("1/4", "1")],
        [("1", "1")], [("1/4", "1/4")], [], [("1", "1")] * 4,
    ]
    for row, ratios in zip(rows, expected, strict=True):
        results = [(r["concur"]["ratio"], r["max"]["ratio"]) for r in row["contested"]]
        if results != ratios:
            raise ValueError(f"failed contested-CPU check for {row['case']}")

    boundaries = []
    for (mode, width, base, total, local), weight in zip(checks, observed, strict=True):
        boundaries.append({"mode": mode, "cpuset_width": width, "base_unscaled": base,
                           "total_tasks": total, "local_tasks": local, "observed_weight": weight})
    return {
        "issue": "231.10",
        "tier": "Linux 7.3.5 scheduler source, synthetic steady-state runqueues",
        "fair_c_sha256": FAIR,
        "kernel_excerpt_sha256": digest(header.encode()),
        "nice_weights_sha256": WEIGHTS,
        "scale_definitions_source_sha256": PRELUDE,
        "budget_archive_sha256": BUDGET,
        "historical_budget": archive_budget(),
        "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
        "driver_sha256": digest(Path(__file__).read_bytes()),
        "probe_sha256": digest((HERE / "probe.c").read_bytes()),
        "cases": rows,
        "boundary_checks": boundaries,
    }


if __name__ == "__main__":
    print(json.dumps(run(), indent=2))
