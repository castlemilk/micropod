"""Check an offline IPv4 MTU capture for a native direct-macvlan worker.

Usage: python3 scripts/relaybench/mtu_path.py CAPTURE.json --mtu 9000 [--require-bidirectional]

One JSON object contains raw observations from a single owner-identified fixture:
  worker_ipv4, gateway_ipv4: Micropod's dedicated publication addresses
  mac_route: macOS 'route -n get WORKER' output
  mac_bridge: 'ifconfig BRIDGE' for the interface in mac_route
  worker_links: Linux 'ip -j -d address show' in the worker namespace
  service_links: same command in the service namespace
  service_route: service 'ip -j -4 route get GATEWAY'
  ping: {argv, returncode, stdout} for the Darwin ping command in check_probe()

Optional worker_to_host contains an integer echo_id (1..65535), worker_route
(worker 'ip -j -4 route get GATEWAY'), ping (Linux iputils argv/returncode/stdout)
and bridge_capture (Darwin tcpdump argv/returncode/stdout/stderr). Use C-locale
output. For MTU 9000, the worker ping arguments are:
  -4 -n -M do -I eth1 -e ID -c 3 -s 8972 GATEWAY
Start tcpdump on the Mac bridge during that probe with arguments:
  -i BRIDGE -t -n -v -s 0 -c 3 'icmp and src host WORKER and dst host GATEWAY and icmp[0] = 8 and icmp[4:2] = ID'
The matching identifier ties the bridge's DF requests to the worker probe.
This verifier only reads captures. TCP MSS and service payload delivery require
separate observations.

The worker handles ICMP. Its macvlan child only admits leased TCP connections.
The required Darwin probe covers host-to-worker reachability. The optional
worker and bridge observations cover worker-to-host reachability. The service
checks establish link configuration.
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


def successful_command(record, executables, arguments):
    args = record["argv"]
    if (not isinstance(args, list) or not args or args[0] not in executables or args[1:] != arguments
            or type(record["returncode"]) is not int or record["returncode"] != 0):
        raise ValueError(f"invalid or unsuccessful {executables[0]} command")


def check_route_mtu(route, mtu, direction):
    metrics = route.get("metrics", [])
    if isinstance(metrics, dict):
        metrics = [metrics]
    if not isinstance(metrics, list) or any(not isinstance(item, dict) for item in metrics):
        raise ValueError(f"invalid {direction} route metrics")
    if any("mtu" in item and item["mtu"] != mtu for item in [route, *metrics]):
        raise ValueError(f"{direction} route has a different MTU")


def check_worker_probe(reverse, bridge, gateway, worker, mtu):
    echo_id = reverse["echo_id"]
    if type(echo_id) is not int or not 1 <= echo_id <= 65535:
        raise ValueError("invalid worker echo identifier")
    route = one(reverse["worker_route"], "worker route to gateway")
    if (route["dst"] != str(gateway) or route["prefsrc"] != str(worker) or route["dev"] != "eth1"
            or "gateway" in route or "via" in route):
        raise ValueError("worker return route must use the direct publication NIC and source")
    check_route_mtu(route, mtu, "worker return")
    data_bytes, icmp_bytes = mtu - 28, mtu - 20
    probe = reverse["ping"]
    successful_command(probe, ("ping", "/bin/ping", "/usr/bin/ping"),
                       ["-4", "-n", "-M", "do", "-I", "eth1", "-e", str(echo_id), "-c", "3",
                        "-s", str(data_bytes), str(gateway)])
    headers = [line for line in probe["stdout"].splitlines() if line.startswith("PING ")]
    target, source = re.escape(str(gateway)), re.escape(str(worker))
    header = rf"PING {target}\s*\({target}\) from {source} eth1\s*:\s+{data_bytes}\({mtu}\) bytes of data\."
    if len(headers) != 1 or not re.fullmatch(header, headers[0]):
        raise ValueError("worker did not report the expected source, interface, target and datagram size")
    replies = re.findall(r"(?m)^(\d+) bytes from ([\d.]+): icmp_seq=(\d+)\b.*$", probe["stdout"])
    expected = [(icmp_bytes, str(gateway), i) for i in (1, 2, 3)]
    if sorted((int(n), addr, int(seq)) for n, addr, seq in replies) != expected:
        raise ValueError("worker DF replies are incomplete, duplicated, short or misdirected")
    summaries = re.findall(r"(?m)^\d+ packets transmitted,.*$", probe["stdout"])
    if len(summaries) != 1 or not re.fullmatch(r"3 packets transmitted, 3 received, 0(?:\.0+)?% packet loss, time \d+ms", summaries[0]):
        raise ValueError("worker DF probe lacks a complete zero-loss summary")

    capture = reverse["bridge_capture"]
    expression = f"icmp and src host {worker} and dst host {gateway} and icmp[0] = 8 and icmp[4:2] = {echo_id}"
    successful_command(capture, ("tcpdump", "/usr/sbin/tcpdump"),
                       ["-i", bridge, "-t", "-n", "-v", "-s", "0", "-c", "3", expression])
    stderr = capture["stderr"].splitlines()
    if (not any(re.search(rf"\blistening on {re.escape(bridge)},", line) for line in stderr)
            or [line for line in stderr if "packets captured" in line] != ["3 packets captured"]
            or [line for line in stderr if "dropped by kernel" in line] != ["0 packets dropped by kernel"]):
        raise ValueError("need a complete capture on the routed Mac bridge")
    lines = [line.strip() for line in capture["stdout"].splitlines() if line.strip()]
    if len(lines) != 6:
        raise ValueError("need three decoded IPv4 echo requests on the Mac bridge")
    sequences = []
    for header, request in zip(lines[::2], lines[1::2]):
        if not re.fullmatch(rf"IP \(tos [^,]+, ttl \d+, id \d+, offset 0, flags \[DF\], proto ICMP \(1\), length {mtu}\)", header):
            raise ValueError("bridge did not receive the exact unfragmented DF datagram")
        fields = re.fullmatch(rf"{re.escape(str(worker))} > {re.escape(str(gateway))}: ICMP echo request, "
                              rf"id {echo_id}, seq (\d+), length {icmp_bytes}", request)
        if not fields:
            raise ValueError("bridge request endpoints, identifier or ICMP length differ from the probe")
        sequences.append(int(fields[1]))
    if sorted(sequences) != [1, 2, 3]:
        raise ValueError("bridge did not observe all three distinct worker requests")
    return {"worker_to_host_df_echo_ipv4_bytes": mtu, "worker_to_host_df_echo_replies": 3,
            "bridge_observed_worker_df_requests": 3}


def qualify(capture, mtu, *, require_bidirectional=False):
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
    check_route_mtu(route, mtu, "service return")
    if any(value != mtu for value in mtus.values()):
        raise ValueError(f"expected configured MTU {mtu} throughout the direct path, observed {mtus}")
    check_probe(capture["ping"], iface, gateway, worker, mtu)
    result = {"mac_interface": iface, "configured_mtu": mtus, "host_to_worker_df_echo_ipv4_bytes": mtu,
              "df_echo_replies": 3, "service_return_interface": "mppub0"}
    if "worker_to_host" in capture:
        result.update(check_worker_probe(capture["worker_to_host"], iface, gateway, worker, mtu))
    elif require_bidirectional:
        raise ValueError("bidirectional IPv4 qualification requires a corroborated worker_to_host probe")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--mtu", type=int, required=True)
    parser.add_argument("--require-bidirectional", action="store_true",
                        help="require independent DF requests from both ends of the IPv4 host-only hop")
    args = parser.parse_args()
    try:
        print(json.dumps(qualify(json.loads(args.capture.read_text()), args.mtu, require_bidirectional=args.require_bidirectional), indent=2))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        parser.exit(1, f"MTU path unqualified: {exc}\n")
