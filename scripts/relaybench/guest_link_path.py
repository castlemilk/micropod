"""Check service-netns link counters around one fixed offered-load client interval."""
import argparse
import json
import re
from pathlib import Path
from uuid import UUID

from gamma_contrasts import clean_client


def counters(before, after):
    result = {}
    for name in ("rx_bytes", "tx_bytes"):
        first, last = before[name], after[name]
        if type(first) is not int or type(last) is not int or not 0 <= first <= last:
            raise ValueError(f"invalid or decreasing {name}")
        result[name] = last - first
    return result


def snapshot(raw):
    rows = {}
    indices = set()
    for link in raw["links"]:
        name, index, address = link["ifname"], link["ifindex"], link["address"]
        if (not name or name in rows or type(index) is not int or index < 1 or index in indices
                or not isinstance(address, str) or not re.fullmatch(r"(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}", address)):
            raise ValueError("invalid or duplicate link identity")
        info = link.get("linkinfo", {})
        identity = (index, address.lower(), info.get("info_kind"), info.get("info_data", {}).get("mode"),
                    link.get("link_index"), link.get("link_netnsid"))
        stats = link["stats64"]
        rows[name] = (identity, {"rx_bytes": stats["rx"]["bytes"], "tx_bytes": stats["tx"]["bytes"]})
        indices.add(index)
    return rows


def check(capture, device, kind, direction, mode=None):
    first, last = capture["before"], capture["after"]
    if (UUID(first["boot_id"]) != UUID(last["boot_id"]) or first["netns"] != last["netns"]
            or not re.fullmatch(r"net:\[\d+\]", first["netns"])):
        raise ValueError("guest boot or service network namespace changed")
    if not (type(first["monotonic_ns"]) is type(last["monotonic_ns"]) is int
            and 0 <= first["monotonic_ns"] < last["monotonic_ns"]):
        raise ValueError("invalid guest sample interval")
    if direction not in ("rx", "tx") or not clean_client(capture["client"]):
        raise ValueError("need a valid transfer direction and a complete offered-load client")
    if (last["monotonic_ns"] - first["monotonic_ns"]) / 1e9 < capture["client"]["window_s"]:
        raise ValueError("sample interval is shorter than the client transfer")
    payload = capture["client"]["bytes"]
    if type(payload) is not int or payload <= 0:
        raise ValueError("invalid client byte count")
    before, after = snapshot(first), snapshot(last)
    if device not in before or before.keys() != after.keys():
        raise ValueError("claimed link missing or service interface inventory changed")
    identity = before[device][0]
    if not kind or identity[2] != kind or (mode is not None and identity[3] != mode):
        raise ValueError("claimed interface has a different link kind or mode")
    deltas = {}
    for name, (old, stats) in before.items():
        new, final = after[name]
        if old != new:
            raise ValueError(f"link identity changed for {name}")
        deltas[name] = counters(stats, final)
    column = direction + "_bytes"
    if deltas[device][column] < payload:
        raise ValueError(f"{device} {direction} does not cover the completed bulk payload")
    competing = {name: values[column] for name, values in deltas.items() if name != device and values[column]}
    return {"device": device, "kind": kind, "mode": identity[3], "direction": direction,
            "client_payload_bytes": payload, "link_byte_deltas": deltas,
            "other_interfaces_with_traffic": competing,
            "other_interfaces_covering_payload": sorted(name for name, count in competing.items() if count >= payload)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--device", required=True)
    parser.add_argument("--kind", required=True, choices=("veth", "macvlan", "ipvlan", "netkit"))
    parser.add_argument("--mode")
    parser.add_argument("--direction", required=True, choices=("rx", "tx"))
    args = parser.parse_args()
    try:
        print(json.dumps(check(json.loads(args.capture.read_text()), args.device, args.kind,
                               args.direction, args.mode), indent=2))
    except (KeyError, TypeError, OSError, ValueError) as exc:
        parser.exit(1, f"Guest link coverage unverified: {exc}\n")
