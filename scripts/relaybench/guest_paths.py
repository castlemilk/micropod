"""Identify the two established guest IPv4 sockets held by a proposed TCP forwarder."""
import argparse
import ipaddress
import json
import os
import re
from pathlib import Path
from uuid import UUID


def endpoint(text):
    addr, port = text.rsplit(":", 1)
    value = int(port)
    if not 1 <= value <= 65535:
        raise ValueError("expected an established socket port")
    return f"{ipaddress.IPv4Address(addr)}:{value}"


def proc_endpoint(raw):
    address, port = raw.split(":")
    if len(address) != 8 or len(port) != 4:
        raise ValueError("invalid arm64 /proc/net/tcp endpoint")
    # The kernel prints the IPv4 address as a native-endian word.
    return f"{ipaddress.IPv4Address(bytes.fromhex(address)[::-1])}:{int(port, 16)}"


def established_inode(table, local, peer):
    matches = []
    for line in table.splitlines()[1:]:
        fields = line.split()
        if len(fields) < 10:
            raise ValueError("incomplete /proc/net/tcp row")
        if fields[3] == "01" and (proc_endpoint(fields[1]), proc_endpoint(fields[2])) == (local, peer):
            matches.append(int(fields[9]))
    if len(matches) != 1 or matches[0] <= 0:
        raise ValueError(f"need one established socket from {local} to {peer}")
    return matches[0]


def process_identity(directory):
    stat = (directory / "stat").read_text()
    pid, sep, command = stat.partition(" (")
    _, close, rest = command.rpartition(") ")
    fields = rest.split()  # begins at field 3 (state), starttime is field 22
    if not sep or not close or pid != directory.name or len(fields) < 20:
        raise ValueError(f"incomplete process identity for {directory.name}")
    ns = os.readlink(directory / "ns/net")
    if not re.fullmatch(r"net:\[\d+\]", ns):
        raise ValueError(f"incomplete network namespace for {directory.name}")
    return {"pid": int(pid), "start_ticks": int(fields[19]), "netns": ns}


def socket_inodes(owner):
    inodes = set()
    for entry in (owner / "fd").iterdir():
        try:
            target = os.readlink(entry)
        except FileNotFoundError:
            continue
        match = re.fullmatch(r"socket:\[(\d+)\]", target)
        if match:
            inodes.add(int(match[1]))
    return inodes


def check(proc, forwarder, ingress_pid, egress_pid, incoming, outgoing):
    pids = (forwarder, ingress_pid, egress_pid)
    if any(type(pid) is not int or pid <= 0 for pid in pids):
        raise ValueError("expected positive guest PIDs")
    owner, ingress, egress = (proc / str(pid) for pid in pids)
    directories = dict.fromkeys((owner, ingress, egress))
    boot_file = proc / "sys/kernel/random/boot_id"
    boot = str(UUID(boot_file.read_text().strip()))
    first = {d: process_identity(d) for d in directories}
    owned_before = socket_inodes(owner)
    legs = {}
    for name, directory, pair in (("incoming", ingress, incoming), ("outgoing", egress, outgoing)):
        local, peer = map(endpoint, pair)
        inode = established_inode((directory / "net/tcp").read_text(), local, peer)
        legs[name] = {"local": local, "peer": peer, "netns": first[directory]["netns"], "inode": inode}
    observed = {leg["inode"] for leg in legs.values()}
    if len(observed) != 2 or not observed <= (owned_before & socket_inodes(owner)):
        raise ValueError("the recorded forwarder must own both distinct socket inodes")
    if str(UUID(boot_file.read_text().strip())) != boot or any(process_identity(d) != first[d] for d in directories):
        raise ValueError("guest boot, process or namespace changed during inspection")
    return {"guest_boot": boot, "forwarder": first[owner], "legs": legs}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("proc", type=Path, help="captured Linux/arm64 procfs root, with symlinks preserved")
    parser.add_argument("--forwarder", type=int, required=True)
    parser.add_argument("--ingress-pid", type=int, required=True, help="process in the accepted socket's namespace")
    parser.add_argument("--egress-pid", type=int, required=True, help="process in the dialed socket's namespace")
    for direction in ("incoming", "outgoing"):
        parser.add_argument("--" + direction, nargs=2, metavar=("LOCAL_IP:PORT", "PEER_IP:PORT"), required=True)
    args = parser.parse_args()
    try:
        result = check(args.proc, args.forwarder, args.ingress_pid, args.egress_pid, args.incoming, args.outgoing)
    except (ValueError, OSError) as exc:
        parser.exit(1, f"Socket pair unverified: {exc}\n")
    print(json.dumps(result, indent=2))
