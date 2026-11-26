"""Check bounded-two adoption order and submission counts using real Darwin dispatch queues."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
TEMPLATE = HERE.parent / "batch07-relay/handoff.swift.in"
FRAGMENT = HERE / "handoff.swiftfrag"
STAGED = HERE / "fixture-evidence/staged.json"
REPEATS = ("stock", "batch2", "batch2", "stock")
FRESH_PER_OWNER_PER_GROUP = (1, 2, 3, 8)

# stream/verify from batch 7 already check each marker and EOF at both ends.
WORKLOAD = """
func workload(_ freshGroup: Int) {
    let targets = [Target(Owner()), Target(Owner())]
    var sequence = 0
    var expected = [[UInt8](), [UInt8]()]
    func group(_ perOwner: Int) {
        var pending = [(Int32, UInt8)]()
        for target in targets { target.owner.queue.serial.suspend() }
        for _ in 0..<(perOwner * 2) {
            let owner = sequence % 2
            let tag = UInt8(truncatingIfNeeded: sequence + 1)
            let pair = stream(tag)
            targets[owner].adopt(pair.1, accepted: UInt64(tag))
            expected[owner].append(tag)
            pending.append((pair.0, tag))
            sequence += 1
        }
        for target in targets {
            target.owner.queue.serial.resume()
            target.owner.queue.serial.sync {}
        }
        for (client, tag) in pending { verify(client, tag) }
    }
    group(1) // two identity/body preflight streams
    group(16) // 32 bulk connections
    for _ in 0..<(120 / freshGroup) { group(freshGroup) }
    for i in targets.indices { precondition(targets[i].owner.taken == expected[i]) }
    let row: [String: Any] = ["fresh_group_per_owner": freshGroup,
        "verified_handoffs": sequence, "counts": targets.map { $0.counts() }]
    print(String(decoding: try! JSONSerialization.data(withJSONObject: row), as: UTF8.self))
}
for cutoff in 0...32 { cell(2, cutoff, true) }
for g in [1, 2, 3, 8] { workload(g) }
"""
COUNTS = """
    func counts() -> [Int] {
        [admissions, submissions, completedAdmissions, completedBlocks, postWarmSubmissions]
    }
"""


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_rows(raw, policy):
    burst, groups = raw[:33], raw[33:]
    if len(raw) != 33 + len(FRESH_PER_OWNER_PER_GROUP):
        raise ValueError("incomplete serial-queue schedule")
    merged = policy == "batch2"
    for cutoff, row in enumerate(burst):
        before = [(cutoff + 1) // 2, cutoff // 2]
        expected = [x + x % 2 for x in before] if merged else before
        if (row["cutoff"], row["ahead"], row["submissions"], row["verified_handoffs"],
            row["verified_existing_replies"], row["clean_eofs"]) != (
                cutoff, expected, [8, 8] if merged else [16, 16], 32, 2, 34):
            raise ValueError(f"ready callback or delivery mismatch at cutoff {cutoff}: {row}")
    for size, row in zip(FRESH_PER_OWNER_PER_GROUP, groups):
        fresh_blocks = (120 // size) * ((size + 1) // 2) if merged else 120
        total_blocks = (9 if merged else 17) + fresh_blocks
        counts = [137, total_blocks, 137, total_blocks, fresh_blocks]
        if (row["fresh_group_per_owner"], row["verified_handoffs"], row["counts"]) != (size, 274, [counts, counts]):
            raise ValueError(f"wrong post-warm adoption counts: {row}")
    return {"callback_ahead_per_owner_by_cutoff": [row["ahead"] for row in burst],
            "burst_submissions_per_owner": burst[0]["submissions"], "workloads": groups}


def main(path):
    staged = json.loads(STAGED.read_bytes())
    if digest(FRAGMENT) != staged["fixture_inputs"]["handoff.swiftfrag"]:
        raise ValueError("bounded handoff source has changed since fixture staging")
    template = TEMPLATE.read_text()
    divider = "\nfor n in [2,4] {"
    if template.count(divider) != 1 or template.count("__ADOPT_METHOD__") != 1:
        raise ValueError("unexpected batch-seven queue fixture")
    source = template.split(divider)[0].replace("__ADOPT_METHOD__", FRAGMENT.read_text() + COUNTS) + WORKLOAD
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        swift = root / "main.swift"
        swift.write_text(source)
        cache = root / "module-cache"
        version = subprocess.check_output(["xcrun", "swiftc", "--version"], text=True).strip()
        for policy, flags in (("stock", []), ("batch2", ["-D", "BATCH_TWO"])):
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-O", "-num-threads", "1",
                            "-module-cache-path", str(cache), *flags, str(swift), "-o", str(root/policy)], check=True)
        results = {}
        raw_sha = []
        for policy in REPEATS:
            trial = subprocess.run([root/policy], capture_output=True, check=True, timeout=30)
            raw = [json.loads(line) for line in trial.stdout.splitlines()]
            values = verify_rows(raw, policy)
            if policy in results and results[policy] != values:
                raise ValueError("two passes disagreed on count or adoption order")
            results[policy] = values
            raw_sha.append(hashlib.sha256(json.dumps(raw, sort_keys=True).encode()).hexdigest())
    report = {"experiment": "230.08 bounded-two dispatch accounting", "evidence": "host-only socketpair fixture",
              "platform": platform.platform(), "compiler": version, "revision": staged["revision"],
              "fixture_sha256": {file.name: digest(file) for file in (Path(__file__), TEMPLATE, FRAGMENT)},
              "admissions": "two preflight, 32 bulk, 240 fresh; group sizes model owner readiness, without timing",
              "trial_order": REPEATS, "raw_semantic_sha256": raw_sha, "results": results,
              "fresh_latency_measured": False, "throughput_mib_s": None, "production_defaults_changed": False}
    with path.open("x") as fp:
        json.dump(report, fp, indent=2); fp.write("\n")
    print(path)


if __name__ == "__main__":
    main(Path(sys.argv[1]))
