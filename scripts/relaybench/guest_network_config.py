"""Report build prerequisites for the guest link and TCP forwarding experiments.

Use --gamma-stock to replay the archived Linux 7.3.5 worker or --config to
inspect an effective arm64 worker .config. Build settings cannot establish
loaded modules, socket ownership, attachment to a device or successful traffic.
"""
import argparse
import hashlib
import json
from pathlib import Path

from gamma_contrasts import ROOT, read_receipt
from kernel_candidate import config_options


# The names and relationships here are from the pinned Linux 7.3.5 source.
PREREQUISITES = {
    "private macvlan with workload veth": ("VETH", "MACVLAN"),
    "ipvlan L2 or L3": ("IPVLAN",),
    "netkit peer redirect": ("NETKIT", "BPF_SYSCALL"),
    "netkit AF_XDP": ("NETKIT", "XDP_SOCKETS"),
    "netkit io_uring zero-copy RX": ("NETKIT", "IO_URING_ZCRX"),
    "IPv4 TCP pipe splice": ("NET", "INET"),
    "SOCKMAP and SOCKHASH": ("NET", "INET", "BPF_SYSCALL"),
    "BPF socket stream parser": ("BPF_STREAM_PARSER", "STREAM_PARSER", "NET_SOCK_MSG"),
}


def assess(config):
    options = config_options(config)
    if options.get("CONFIG_ARM64") != "y":
        raise ValueError("expected an effective arm64 worker config")
    results = {}
    for capability, keys in PREREQUISITES.items():
        settings = {"CONFIG_" + key: options.get("CONFIG_" + key) for key in keys}
        values = set(settings.values())
        if values - {"y", "m", "n", None}:
            raise ValueError(f"invalid tristate setting for {capability}")
        if "n" in values:
            state = "disabled prerequisite"
        elif None in values:
            state = "unrecorded prerequisite"
        elif "m" in values:
            state = "module required"
        else:
            state = "built-in prerequisites"
        results[capability] = {"state": state, "settings": settings}
    return {"config_sha256": hashlib.sha256(config).hexdigest(), "build_prerequisites": results}


def gamma_stock():
    archive = ROOT / "docs/benchmarks/2026-11-21/gamma-direct-macvlan.json.gz"
    receipt = read_receipt(archive, "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976")
    stock = receipt["kernels"]["full"]
    result = assess(stock["config"].encode())
    if result["config_sha256"] != stock["config_sha256"]:
        raise ValueError("embedded stock config differs from its recorded digest")
    result.update(recorded_release=stock["release"], recorded_image_sha256=stock["image_sha256"])
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--gamma-stock", action="store_true")
    source.add_argument("--config", type=Path)
    args = parser.parse_args()
    try:
        report = gamma_stock() if args.gamma_stock else assess(args.config.read_bytes())
    except (ValueError, OSError) as error:
        parser.exit(2, f"Cannot assess network build prerequisites: {error}\n")
    print(json.dumps(report, indent=2))
