"""Check service-netns link counters around one fixed offered-load client interval."""
import argparse
import hashlib
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


def unique_keys(pairs):
    fields = {}
    for key, value in pairs:
        if key in fields:
            raise ValueError(f"duplicate JSON key {key!r}")
        fields[key] = value
    return fields


def netavark_provenance(raw, network, device, identity, observed):
    # Saved setup stdout is keyed by network. Interface names belong to the container netns.
    status = json.loads(raw, object_pairs_hook=unique_keys)
    if not isinstance(status, dict) or not isinstance(status.get(network), dict):
        raise ValueError("named network missing from saved Netavark status")
    interfaces = status[network].get("interfaces")
    if not isinstance(interfaces, dict) or not isinstance(interfaces.get(device), dict):
        raise ValueError("observed device missing from named Netavark network")
    mac = interfaces[device].get("mac_address")
    if not isinstance(mac, str) or mac.lower() != identity[1]:
        raise ValueError("saved Netavark MAC differs from observed device")
    for name, block in status.items():
        if not isinstance(block, dict):
            raise ValueError("invalid Netavark network status block")
        links = block.get("interfaces")
        if links is not None and not isinstance(links, dict):
            raise ValueError("invalid Netavark interfaces map")
        if name != network and links and device in links:
            raise ValueError("multiple Netavark networks claim the observed device name")
    return {"status_sha256": hashlib.sha256(raw).hexdigest(), "network": network,
            "saved_interface": device, "saved_mac_address": mac.lower(),
            "observed_boot_id": observed["boot_id"], "observed_netns": observed["netns"],
            "observed_ifindex": identity[0]}


def check(capture, device, kind, direction, mode=None, *, netavark_status=None, network=None):
    if (netavark_status is None) != (network is None) or network == "":
        raise ValueError("supply both a saved Netavark status and its network name")
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
    result = {"device": device, "kind": kind, "mode": identity[3], "direction": direction,
              "client_payload_bytes": payload, "link_byte_deltas": deltas,
              "other_interfaces_with_traffic": competing,
              "other_interfaces_covering_payload": sorted(name for name, count in competing.items() if count >= payload)}
    if netavark_status is not None:
        result["netavark_status"] = netavark_provenance(netavark_status, network, device, identity, first)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--device", required=True)
    parser.add_argument("--kind", required=True, choices=("veth", "macvlan", "ipvlan", "netkit"))
    parser.add_argument("--mode")
    parser.add_argument("--direction", required=True, choices=("rx", "tx"))
    parser.add_argument("--netavark-status", type=Path, help="saved Netavark setup JSON from this service")
    parser.add_argument("--network", help="exact network name in the saved Netavark status")
    args = parser.parse_args()
    if (args.netavark_status is None) != (args.network is None):
        parser.error("--netavark-status and --network must be used together")
    try:
        saved = args.netavark_status.read_bytes() if args.netavark_status else None
        capture = json.loads(args.capture.read_text(), object_pairs_hook=unique_keys if saved is not None else None)
        print(json.dumps(check(capture, args.device, args.kind, args.direction, args.mode,
                               netavark_status=saved, network=args.network), indent=2))
    except (KeyError, TypeError, OSError, ValueError) as exc:
        parser.exit(1, f"Guest link coverage unverified: {exc}\n")
