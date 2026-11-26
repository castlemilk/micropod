"""Verify read-only bql_capture.sh boundary receipts on a specific boot and device."""
import argparse
import hashlib
import json
import re
from pathlib import Path, PurePosixPath
from uuid import UUID

POLICY = ("limit_max", "limit_min", "limit", "inflight")
COUNTERS = ("tx_bytes", "tx_packets", "tx_errors", "tx_dropped")


def uptime(line):
    # /proc/uptime exports uptime and accumulated idle time to two decimal places.
    match = re.fullmatch(r"(\d+)\.(\d{2}) \d+\.\d{2}", line)
    if not match:
        raise ValueError("invalid /proc/uptime readback")
    return 100 * int(match[1]) + int(match[2])


def decode(data):
    lines = data.decode("ascii").splitlines()
    if len(lines) != 27 or lines[0] != "bql-capture-v1":
        raise ValueError("truncated or unexpected queue capture")
    keys = ("boot", "kernel", "netns", "interface", "ifindex", "address", "device", "driver")
    identity = dict(zip(keys, lines[2:10], strict=True))
    if lines[2:10] != lines[18:26]:
        raise ValueError("device changed during the queue capture")
    identity["boot"] = str(UUID(identity["boot"]))
    if not (identity["kernel"] and re.fullmatch(r"net:\[\d+\]", identity["netns"])
            and re.fullmatch(r"[1-9]\d*", identity["ifindex"])
            and re.fullmatch(r"[a-zA-Z0-9_.-]+", identity["interface"])
            and re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", identity["address"])
            and re.fullmatch(r"virtio\d+", PurePosixPath(identity["device"]).name)
            and PurePosixPath(identity["driver"]).name == "virtio_net"):
        raise ValueError("invalid virtio-net identity")
    values = {}
    for key, line in zip(POLICY + COUNTERS, lines[10:18], strict=True):
        match = re.fullmatch(key + r" (0|[1-9]\d*)", line)
        if not match:
            raise ValueError(f"missing or non-numeric {key} readback")
        values[key] = int(match[1])
    start = uptime(lines[1])
    end = uptime(lines[-1])
    if end < start:
        raise ValueError("reversed guest uptime")
    return dict(identity=identity, tx_queue=0, uptime_cs=[start, end], values=values,
                capture_sha256=hashlib.sha256(data).hexdigest())


def boundaries(before, after, boot, interface, ceiling):
    a, b = [decode(data) for data in (before, after)]
    if (a["identity"] != b["identity"] or a["identity"]["boot"] != str(UUID(boot))
            or a["identity"]["interface"] != interface):
        raise ValueError("unexpected or changed boot/interface")
    if a["uptime_cs"][1] >= b["uptime_cs"][0]:
        raise ValueError("boundaries overlap or are out of order at the clock resolution")
    if any(sample["values"]["limit_max"] != ceiling for sample in (a, b)):
        raise ValueError("effective ceiling differs from the requested value")
    delta = {name: b["values"][name] - a["values"][name] for name in COUNTERS}
    if min(delta.values()) < 0:
        raise ValueError("interface counter fell across the two boundaries")
    return dict(before=a, after=b, interface_delta=delta,
                scope="Boundary readings from tx-0; instantaneous inflight can exceed the dynamic limit. "
                      "Interface counters cover all TX queues and traffic. Matching boundaries do not "
                      "prove the ceiling stayed constant at every instant of the intervening workload.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--boot", required=True)
    parser.add_argument("--interface", required=True)
    parser.add_argument("--ceiling", required=True, type=int, help="expected limit_max in bytes")
    args = parser.parse_args()
    try:
        result = boundaries(args.before.read_bytes(), args.after.read_bytes(), args.boot, args.interface, args.ceiling)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"Invalid BQL evidence: {exc}\n")
    print(json.dumps(result, indent=2))
