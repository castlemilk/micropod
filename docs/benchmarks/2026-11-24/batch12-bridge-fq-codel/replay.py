"""Replay the bridge/veth fq_codel by receive-steering crossover from Gamma."""
import gzip
import hashlib
import itertools
import json
import math
from pathlib import Path
from statistics import median

HERE = Path(__file__).resolve().parent
ARCHIVE = HERE.parents[1] / "2026-11-21" / "gamma-vnic.json.gz"
ARCHIVE_SHA = "2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f"
ARMS = ("base", "rfs", "fq", "all")
MIB = 1024 ** 2


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_settings(settings, arm):
    lines = settings.splitlines()
    discipline = "fq_codel" if arm in ("fq", "all") else "noqueue"
    steering = ["f", "32768"] if arm in ("rfs", "all") else ["0", "0"]
    require(lines[0] == "mpci0 veth7c7f59d2", "wrong bridge/veth")
    require(lines[1].split()[1] == discipline, "wrong peer qdisc")
    require(lines[-2:] == steering, "wrong steering state")


def read_mixed(mixed):
    per_stream = mixed["overlap_bytes_per_stream"]
    byte_count = mixed["overlap_bytes"]
    duration = mixed["overlap_s"]
    fresh = mixed["fresh"]
    require(mixed["streams"] == len(per_stream) == 32, "missing stream")
    require(all(n > 0 for n in per_stream), "stalled stream")
    require(sum(per_stream) == byte_count, "receiver byte mismatch")
    require(duration > 0 and mixed["reopened_connections"] == 0, "bad client window")
    require(fresh["iterations"] == 150 and fresh["incomplete_phase_samples"] == 0,
            "incomplete fresh probes")
    rate = byte_count / MIB / duration
    require(math.isclose(rate, mixed["overlap_mib_s"], rel_tol=1e-9), "rate mismatch")
    return {
        "mixed_bytes": byte_count, "mixed_seconds": duration, "mixed_mib_s": rate,
        "fresh_iterations": fresh["iterations"], "reopens": mixed["reopened_connections"],
        "fresh_p95_ms": fresh["complete_ns"]["p95"] / 1e6,
        "fresh_p99_ms": fresh["complete_ns"]["p99"] / 1e6,
    }


def read_attempt(raw, block, arm):
    prefix = f"qdisc/{block}-{arm}."
    read_settings(raw[prefix + "settings"], arm)
    for status in ("mixed-status", "burst-status"):
        require(raw[prefix + status] == 0, f"failed {prefix}{status}")
    row = read_mixed(raw[prefix + "mixed"])
    burst = raw[prefix + "burst"]
    require(burst["bytes"] == 256 * MIB and burst["elapsed_us"] > 0, "bad burst")
    require(burst["streams"] == len(burst["stream_phases"]) == 32 and
            burst["transfers_per_stream"] == 1 and burst["first_response_barrier"] and
            not burst["warm"], "unexpected burst shape")
    require(burst["unexpected_reconnects"] == burst["initial_connection_mismatches"] == 0,
            "wrong burst sockets")
    rate = burst["bytes"] / MIB / (burst["elapsed_us"] / 1e6)
    require(math.isclose(rate, burst["mib_s"], rel_tol=1e-9), "burst rate mismatch")
    row.update(burst_bytes=burst["bytes"], burst_elapsed_us=burst["elapsed_us"],
               burst_mib_s=rate)
    return row


def paired(ratios):
    # Six blocks yield 6**6 equally likely whole-block resamples.
    estimates = sorted(median(sample) for sample in itertools.product(ratios, repeat=6))
    return {
        "median_ratio": median(ratios),
        "percentile_95_interval": [estimates[math.ceil(p * len(estimates)) - 1]
                                   for p in (0.025, 0.975)],
        "wins": sum(x > 1 for x in ratios),
        "block_ratios": ratios,
    }


def check_rejections(raw):
    prefix = "qdisc/0-base."
    sample = raw[prefix + "mixed"]
    bad_streams = list(sample["overlap_bytes_per_stream"])
    bad_streams[0] += 1
    for check, args, label in [
        (read_settings, (raw[prefix + "settings"], "fq"), "wrong peer qdisc"),
        (read_settings, (raw[prefix + "settings"], "rfs"), "wrong steering state"),
        (read_mixed, (dict(sample, overlap_bytes_per_stream=bad_streams),), "receiver byte mismatch"),
        (read_mixed, (dict(sample, overlap_s=2 * sample["overlap_s"]),), "rate mismatch"),
    ]:
        try:
            check(*args)
        except ValueError as exc:
            require(str(exc) == label, f"unexpected reason: {exc}")
        else:
            raise ValueError(f"accepted negative control: {label}")


def main():
    compressed = ARCHIVE.read_bytes()
    require(hashlib.sha256(compressed).hexdigest() == ARCHIVE_SHA, "archive SHA mismatch")
    archive = json.loads(gzip.decompress(compressed))
    raw = archive["raw"]
    require(raw["qdisc/id"] == raw["links.name"], "service marker differs")
    read_settings(raw["qdisc/restored"], "base")
    check_rejections(raw)
    blocks = []
    for index in range(6):
        order = ARMS[index % 4:] + ARMS[:index % 4]
        blocks.append({"block": index, "order": order,
                       "arms": {arm: read_attempt(raw, index, arm) for arm in order}})
    results = {}
    for metric in ("mixed_mib_s", "burst_mib_s"):
        def ratios(candidate, control):
            return [row["arms"][candidate][metric] / row["arms"][control][metric]
                    for row in blocks]
        off, on = ratios("fq", "base"), ratios("all", "rfs")
        results[metric] = {"steering_off": paired(off), "steering_on": paired(on),
                           "on_to_off_effect_ratio": paired([y / x for x, y in zip(off, on)])}

    medians = {arm: {metric: median(row["arms"][arm][metric] for row in blocks)
                     for metric in ("mixed_mib_s", "burst_mib_s", "fresh_p95_ms",
                                    "fresh_p99_ms", "mixed_seconds")} for arm in ARMS}
    output = {"evidence": "archived VM, 6 complete 4-arm blocks", "issue": "231.08",
              "archive": ARCHIVE.name, "archive_sha256": ARCHIVE_SHA, "run": archive["run"],
              "archive_commit": "4f887ba5d28f47fa37d4bd0a2d89cd0914d74754",
              "recording_base": archive["parent_commit"], "service_image": archive["image"],
              "boot": raw["links.boot"]["boot"], "service_id": raw["links.id"],
              "arm_medians": medians, "paired": results, "blocks": blocks}
    print(json.dumps(output, sort_keys=True, indent=2))


if __name__ == "__main__":
    main()
