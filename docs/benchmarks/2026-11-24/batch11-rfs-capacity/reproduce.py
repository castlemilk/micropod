"""Compare Linux's global receive-flow table lookup using paired, reproducible input hashes."""
import argparse
from hashlib import sha256
import gzip
import json
import math
from pathlib import Path
import random
import statistics
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REVISION = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
SOURCE = "docs/benchmarks/2026-11-24/batch07-sched/rfs_flow.inc"
SOURCE_HASH = "2fe96717d91d02259049dfced5c1e246cffb8a6023f7634fb3c36e41e60c2e7a"
ARCHIVE = "docs/benchmarks/2026-11-21/gamma-vnic.json.gz"
ARCHIVE_HASH = "2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f"
BULK = 32
FRESH = 240
SEEDS = 1024


def git_bytes(path):
    return subprocess.check_output(["git", "show", f"{REVISION}:{path}"], cwd=HERE)


def generate_hashes(seed):
    prng = random.Random(seed)
    hashes = []
    # Real flows can share a 32-bit hash. This population conditions on distinct, nonzero hashes.
    while len(hashes) < BULK + FRESH:
        value = prng.getrandbits(32)
        if value and value not in hashes:
            hashes.append(value)
    return hashes


def oracle(hashes, size):
    last = {h % size: i for i, h in enumerate(hashes)}
    missing = [i for i in range(BULK) if last[hashes[i] % size] != i]
    fallback_elsewhere = [i for i in missing if (hashes[i] >> 30) != i % 4]
    return [sum(1 << i for i in indices) for indices in [missing, fallback_elsewhere]]


def replay(output):
    source_blob = git_bytes(SOURCE)
    assert sha256(source_blob).hexdigest() == SOURCE_HASH
    original = source_blob.decode()
    archive_blob = git_bytes(ARCHIVE)
    assert sha256(archive_blob).hexdigest() == ARCHIVE_HASH
    archive = json.loads(gzip.decompress(archive_blob))
    setup = archive["experiment_drivers"]["vnic-action.sh"]
    assert "echo 32768 > /proc/sys/net/core/rps_sock_flow_entries" in setup
    assert "echo 32768 > /sys/class/net/eth0/queues/rx-0/rps_flow_cnt" in setup
    readbacks = [archive["raw"][f"qdisc/{i}-rfs.settings"].splitlines()[-2:] for i in range(6)]
    assert readbacks == [["f", "32768"]] * 6
    workload = json.loads(git_bytes("docs/benchmarks/2026-11-24/tso-driver-work.json"))
    assert workload["workload"].startswith("32 bulk streams, 240 fixed arrivals")
    with tempfile.TemporaryDirectory() as scratch:
        tmp = Path(scratch)
        begin = original.index("flow_id = hash & rps_tag_to_mask(global_tag_ptr);")
        end = original.index("next_cpu = ident & net_hotdata.rps_cpu_mask;", begin)
        end = original.index(";", end) + 1
        (tmp / "global-lookup.inc").write_text(original[begin:end] + "\n")
        # Use the upstream CPU selection for a global miss. Instrument which exit was taken.
        fallback = original[original.index("try_rps:"):original.index("return cpu;")]
        (tmp / "fallback.inc").write_text(fallback + "return (struct lookup){(u32)cpu, 0};\n")
        binary = tmp / "select_reader"
        subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I", str(tmp), str(HERE / "socket_lookup.c"), "-o", str(binary)], check=True)
        inputs = [generate_hashes(seed) for seed in range(SEEDS)]
        stdin = "".join(" ".join(map(str, vec)) + "\n" for vec in inputs)
        output_lines = subprocess.check_output([str(binary)], input=stdin, text=True).splitlines()
    assert len(output_lines) == SEEDS
    rows = []
    deltas = []
    total = [0] * 4
    for seed, (line, hashes) in enumerate(zip(output_lines, inputs, strict=True)):
        masks = [int(tok, 16) for tok in line.split()]
        assert masks == oracle(hashes, 32768) + oracle(hashes, 65536)
        assert masks[2] & ~masks[0] == masks[3] & ~masks[1] == 0
        counts = [m.bit_count() for m in masks]
        total = [a + b for a, b in zip(total, counts, strict=True)]
        deltas.append((counts[0] - counts[2]) / BULK)
        rows.append([seed, *[f"{m:08x}" for m in masks]])
    mean = statistics.mean(deltas)
    halfwidth = 1.96 * statistics.stdev(deltas) / math.sqrt(SEEDS)
    record = {"direction": "237.05", "micropod_revision": REVISION, "linux_version": "7.3.5",
              "linux_net_core_dev_sha256": "8b3c43e8becfd552ead597c2e009edf16b126924a7cbe4c5c961e74563b76274",
              "extracted_source_sha256": SOURCE_HASH, "old_steering_archive_sha256": ARCHIVE_HASH,
              "old_steering_archive_parent": archive["parent_commit"], "old_rfs_readbacks": readbacks,
              "workload_reference_revision": workload["source"],
              "units": "lookup decisions on modeled hashes, no traffic",
              "settings": {"global_slots": [32768, 65536], "bulk": BULK, "fresh": FRESH, "seeds": SEEDS,
                           "hash_input_lines_sha256": sha256(stdin.encode()).hexdigest()},
              "counts_order": ["control_misses", "control_other_cpu", "candidate_misses", "candidate_other_cpu"],
              "lookups_per_arm": SEEDS * BULK, "counts": total, "mean_miss_share_reduction": mean,
              "approx_95_interval_across_hash_populations_only": [mean - halfwidth, mean + halfwidth],
              "rows_format": "seed, control miss mask, control fallback-other-CPU mask, candidate miss mask, candidate fallback-other-CPU mask; hex bit i = bulk flow i",
              "rows": rows}
    with output.open("x") as f:
        json.dump(record, f, separators=(",", ":"))
        f.write("\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    replay(parser.parse_args().output)
