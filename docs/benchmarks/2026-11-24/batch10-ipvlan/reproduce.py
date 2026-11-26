"""Replay the same archived publication tuples across two compiled Linux link-driver TX paths."""
import gzip
import hashlib
import ipaddress
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REV = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
ARCHIVE = "docs/benchmarks/2026-11-21/gamma-direct-macvlan.json.gz"
PUBLISHER = "guest/runner/docker_port_direct_linux.go"
MAC = "drivers/net/macvlan.c"
IPV = "drivers/net/ipvlan/ipvlan_core.c"
FILES = {
    MAC: "8acd99e9496a3d7cc9c7ad7557549c85f1ae991cb2e42edb6dfc3ddaf5f81f28",
    IPV: "172136934bfd87a8d29c2ba34b51eb2a5663551dc8a84360ac1fa6266c88d4c3",
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def git(path):
    return subprocess.check_output(["git", "show", f"{REV}:{path}"], cwd=HERE)


def function(source, prefix):
    begin = source.index(prefix)
    return source[begin:source.index("\n}", begin) + 2]


def packed(addr):
    return ipaddress.IPv4Address(addr).packed


def checksum(blob):
    blob += bytes(len(blob) % 2)
    total = sum(x[0] for x in struct.iter_unpack("!H", blob))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return total ^ 65535


def engine_frames(data):
    trial = data["records"]["workers"]["trial"]
    pub = trial["boot.json"]["publishedAddress"]
    raw_rule = trial["root-before"]
    gateway, gateway_mac = re.search(r"\n([0-9.]+) lladdr ([0-9a-f:]{17}) ", raw_rule).groups()
    child_mac = trial["state"]["interfaces"]["mppub0"]["mac"]
    mapping = re.search(rf"elements = \{{ (\d+) : {child_mac} \}}", raw_rule)
    port = int(mapping[1])
    pod = re.search(rf"elements = \{{ {child_mac} \. ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) \}}", raw_rule)[1]
    assert trial["after"]["interfaces"]["mppub0"]["mac"] == child_mac
    assert f"ip saddr {pub} ip daddr {gateway} ip protocol tcp" in raw_rule
    assert data["checks"]["neighbor_requests"].splitlines() == ["ok"] * 4
    src_mac, dst_mac = [bytes.fromhex(s.replace(":", "")) for s in [child_mac, gateway_mac]]
    src, dst = packed(pub), packed(gateway)
    tcp = bytearray(struct.pack("!HHIIBBHHH", port, 49152, 10, 20, 0x50, 0x18, 4096, 0, 0) + b"return marker")
    pseudo = src + dst + struct.pack("!BBH", 0, 6, len(tcp))
    struct.pack_into("!H", tcp, 16, checksum(pseudo + tcp))
    header = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(tcp), 1, 0x4000, 64, 6, 0, src, dst))
    struct.pack_into("!H", header, 10, checksum(header))
    assert checksum(header) == checksum(pseudo + tcp) == 0
    arp = struct.pack("!HHBBH6s4s6s4s", 1, 0x0800, 6, 4, 1, src_mac, packed(pod), bytes(6), dst)
    return [pub, gateway, pod], {
        "published_tcp_reply": dst_mac + src_mac + bytes.fromhex("0800") + header + tcp,
        "pod_gateway_arp_request": bytes([255]) * 6 + src_mac + bytes.fromhex("0806") + arp,
    }


def main(kernel):
    archive = git(ARCHIVE)
    assert sha(archive) == "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976"
    data = json.loads(gzip.decompress(archive))
    addresses, frames = engine_frames(data)
    pub = git(PUBLISHER)
    for invariant in (b"Mode: netlink.MACVLAN_MODE_PRIVATE", b"Scope: netlink.SCOPE_LINK", b"State: netlink.NUD_STALE", b"arp operation request arp daddr ip"):
        assert invariant in pub
    sources = {name: (kernel / name).read_bytes() for name in FILES}
    assert {name: sha(content) for name, content in sources.items()} == FILES
    mac, ip = sources[MAC].decode(), sources[IPV].decode()
    dispatch = function(ip, "int ipvlan_queue_xmit(")
    assert "case IPVLAN_MODE_L3:" in dispatch and "return ipvlan_xmit_mode_l3(skb, dev);" in dispatch
    fns = [function(mac, "static int macvlan_queue_xmit(")]
    for prefix in ("static void ipvlan_skb_crossing_ns(", "static noinline_for_stack int ipvlan_process_v4_outbound(", "static int ipvlan_process_outbound(", "static int ipvlan_xmit_mode_l3("):
        fns.append(function(ip, prefix))
    include = "\n\n".join(fns) + "\n"
    rows = []
    cc = os.environ.get("CC", "cc")
    with tempfile.TemporaryDirectory() as workspace:
        work = Path(workspace)
        (work / "pinned_tx.inc").write_text(include)
        exe = work / "tx_fixture"
        subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-I", str(work), str(HERE / "tx_fixture.c"), "-o", str(exe)], check=True)
        for packet, frame in frames.items():
            for mode in ("macvlan-private", "ipvlan-l3"):
                run = subprocess.run([str(exe), mode, *addresses], input=frame, capture_output=True, check=True)
                rows.append({"arm": mode, "packet": packet, "frame_sha256": sha(frame), "frame_hex": frame.hex(), **json.loads(run.stdout)})
    assert [(r["direct_lower_egress"], r["parent_route_lookup"], r["parent_local_out"], r["dropped_by_driver"]) for r in rows] == [
        (1, 0, 0, 0), (0, 1, 1, 0), (1, 0, 0, 0), (0, 0, 0, 1)]
    return {"date": "2026-11-24", "id": "233.02", "evidence_tier": "source/fixture", "tested_revision": REV,
            "archive": ARCHIVE, "archive_sha256": sha(archive), "historical_recording_base": data["baseline_commit"],
            "publisher_sha256": sha(pub), "linux": "7.3.5", "tar_sha256_recorded": data["kernels"]["source_sha256"],
            "driver_source_sha256": FILES, "compiled_kernel_functions_sha256": sha(include.encode()),
            "harness_sha256": sha((HERE / "tx_fixture.c").read_bytes()), "reproducer_sha256": sha(Path(__file__).read_bytes()),
            "compiler": subprocess.check_output([cc, "--version"], text=True).splitlines()[0],
            "attempts": len(rows), "rows": rows, "measured_delivered_mib_s": None, "p95_ms": None, "p99_ms": None,
            "network_drops": None, "cpu_per_gib": None, "runnable_time": None,
            "scope": "Same two synthetic Ethernet frames, identical bytes per pair from archived trial addressing; no child owns the gateway. Cross-namespace and successful parent unicast FIB plus lower-device/LOCAL_OUT calls are adapters, not wire observations. An injected ARP frame tests the TX entry point, not whether L3 creates ARP. No timers or live endpoints."}


if __name__ == "__main__":
    print(json.dumps(main(Path(sys.argv[1])), indent=2, sort_keys=True))
