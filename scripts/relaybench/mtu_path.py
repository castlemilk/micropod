"""Check an offline IPv4 MTU capture for a native direct-macvlan worker.

Usage: python3 scripts/relaybench/mtu_path.py CAPTURE.json --mtu 9000

One JSON object contains raw observations from a single owner-identified fixture:
  worker_ipv4, gateway_ipv4: Micropod's dedicated publication addresses
  mac_route: macOS 'route -n get WORKER' output
  mac_bridge: 'ifconfig BRIDGE' for the interface in mac_route
  worker_links: Linux 'ip -j -d address show' in the worker namespace
  service_links: same command in the service namespace
  service_route: service 'ip -j -4 route get GATEWAY'
  ping: {argv, returncode, stdout} for the Darwin ping command in check_probe()

The worker handles ICMP. Its macvlan child only admits leased TCP connections.
The DF echo checks host-to-worker reachability. The service checks establish
link configuration, and neither observation measures published TCP performance.
"""
import argparse
import ipaddress
import json
import re
from pathlib import Path


def one(values, what):
    matches = list(values)
    if len(matches) != 1:
        raise ValueError(f"expected exactly one {what}")
    return matches[0]


def host_link(route, bridge, gateway, worker):
    target = one(re.findall(r"(?m)^\s*route to:\s*(\S+)\s*$", route), "host route destination")
    iface = one(re.findall(r"(?m)^\s*interface:\s*(\S+)\s*$", route), "routed Mac interface")
    if target != str(worker) or not re.fullmatch(r"bridge\d+", iface):
        raise ValueError("host route does not select a bridge for the worker")
    device, flags, mtu = one(re.findall(r"(?m)^(\w+): flags=[^<\n]+<([^>]+)> mtu (\d+)\b", bridge),
                             "Mac interface")
    if (device != iface or "UP" not in flags.split(",")
            or not re.search(r"(?m)^\s*member: vmenet\d+ flags=[^\n]*\bVIRTIO\b", bridge)):
        raise ValueError("routed Mac bridge lacks an active publication configuration")
    if not re.search(rf"(?m)^\s*inet {re.escape(str(gateway))}\s", bridge):
        raise ValueError("routed Mac bridge does not own the gateway address")
    lines = route.splitlines()
    index = one((i for i, line in enumerate(lines) if "mtu" in line.split()), "route metrics header")
    if index + 1 >= len(lines):
        raise ValueError("missing Mac route metrics")
    keys, values = lines[index].split(), lines[index + 1].split()
    if len(keys) != len(values):
        raise ValueError("incomplete Mac route metrics")
    return iface, int(mtu), int(values[keys.index("mtu")])


def check_probe(probe, iface, gateway, worker, mtu):
    # -D sets IPv4 DF on Darwin. -s excludes the IPv4 (20) and echo (8) headers.
    size = mtu - 28
    expected = ["ping", "-n", "-D", "-b", iface, "-S", str(gateway), "-c", "3", "-s", str(size), str(worker)]
    args = probe["argv"]
    if (not isinstance(args, list) or not args or args[0] not in ("ping", "/sbin/ping")
            or args[1:] != expected[1:] or type(probe["returncode"]) is not int or probe["returncode"] != 0):
        raise ValueError("need a successful gateway-bound, full-size Darwin DF echo probe")
    replies = re.findall(r"(?m)^(\d+) bytes from ([\d.]+): icmp_seq=(\d+)\b.*$", probe["stdout"])
    wanted = [(size + 8, str(worker), i) for i in range(3)]
    if sorted((int(n), addr, int(seq)) for n, addr, seq in replies) != wanted:
        raise ValueError("missing, duplicated, short or misdirected DF echo replies")
    if not re.search(r"(?m)^3 packets transmitted, 3 packets received, 0(?:\.0+)?% packet loss\s*$", probe["stdout"]):
        raise ValueError("missing complete DF echo summary")


def qualify(capture, mtu):
    if type(mtu) is not int or not 68 <= mtu <= 65535:
        raise ValueError("invalid IPv4 MTU")
    gateway, worker = (ipaddress.IPv4Address(capture[k]) for k in ("gateway_ipv4", "worker_ipv4"))
    if worker == gateway:
        raise ValueError("publication worker and gateway addresses coincide")
    iface, bridge_mtu, route_mtu = host_link(capture["mac_route"], capture["mac_bridge"], gateway, worker)
    parent = one((x for x in capture["worker_links"] if x["ifname"] == "eth1"), "worker eth1")
    addrs = [a for a in parent["addr_info"] if a["family"] == "inet" and a["local"] == str(worker)]
    prefix = one(addrs, "dedicated worker IPv4 address")["prefixlen"]
    if gateway not in ipaddress.IPv4Network((worker, prefix), strict=False):
        raise ValueError("gateway and worker are on different publication subnets")
    service = capture["service_links"]
    child = one((x for x in service if x["ifname"] == "mppub0"), "service mppub0")
    origin = one((x for x in service if x["ifname"] == "eth0"), "service eth0")
    info = child["linkinfo"]
    if (type(parent["ifindex"]) is not int or parent["ifindex"] <= 0
            or child["link_index"] != parent["ifindex"] or info["info_kind"] != "macvlan"
            or info["info_data"]["mode"] != "private"
            or any("UP" not in x["flags"] or "LOWER_UP" not in x["flags"] for x in (parent, child))):
        raise ValueError("service interface is not the active private macvlan child of the publication NIC")
    route = one(capture["service_route"], "service return route")
    if (route["dst"] != str(gateway) or route["dev"] != "mppub0" or "gateway" in route
            or not any(a["family"] == "inet" and a["local"] == route["prefsrc"] for a in origin["addr_info"])):
        raise ValueError("service return route does not use the direct publication path")
    mtus = {"mac_bridge": bridge_mtu, "mac_route": route_mtu, "worker_eth1": parent["mtu"], "service_mppub0": child["mtu"]}
    route_metrics = route.get("metrics", [])
    if isinstance(route_metrics, dict):
        route_metrics = [route_metrics]
    if not isinstance(route_metrics, list) or any(not isinstance(item, dict) for item in route_metrics):
        raise ValueError("invalid service route metrics")
    for item in [route, *route_metrics]:
        if "mtu" in item and item["mtu"] != mtu:
            raise ValueError("service return route has a different MTU")
    if any(value != mtu for value in mtus.values()):
        raise ValueError(f"expected configured MTU {mtu} throughout the direct path, observed {mtus}")
    check_probe(capture["ping"], iface, gateway, worker, mtu)
    return {"mac_interface": iface, "configured_mtu": mtus, "host_to_worker_df_echo_ipv4_bytes": mtu,
            "df_echo_replies": 3, "service_return_interface": "mppub0"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--mtu", type=int, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(qualify(json.loads(args.capture.read_text()), args.mtu), indent=2))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        parser.exit(1, f"MTU path unqualified: {exc}\n")
