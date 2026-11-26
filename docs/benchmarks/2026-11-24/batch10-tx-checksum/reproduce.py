"""Replay Linux device dependency normalization on the recorded virtio-net TX feature set."""
import gzip
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REVISION = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
ARCHIVE = "docs/benchmarks/2026-11-24/tx-offload-bql-readbacks.json.gz"
PINS = {
    "net/core/dev.c": "8b3c43e8becfd552ead597c2e009edf16b126924a7cbe4c5c961e74563b76274",
    "include/linux/netdevice.h": "c01410d782e5c984ee118c5f6a041fb7cc91ce5c1ee06493de92d44670fd5907",
    "include/linux/netdev_features.h": "023f2d45c9651d29c81451a044fa5071f0481f95cfefff70bc30766a9834d1a0",
    "include/linux/skbuff.h": "bcc75ea787040e9073f5bd3ae70fc5da4c2f9ae40694d565369c8093b7166e5b",
    "net/ethtool/common.c": "74fe941414941ea54fcad596a29976fa038265c7868e6eb361ef0ecebd1b20ee",
    "drivers/net/virtio_net.c": "d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace",
    "drivers/net/macvlan.c": "8acd99e9496a3d7cc9c7ad7557549c85f1ae991cb2e42edb6dfc3ddaf5f81f28",
}
ALIASES = {"rx-checksumming": "rx-checksum", "generic-segmentation-offload": "tx-generic-segmentation", "generic-receive-offload": "rx-gro"}
AGGREGATES = {"tx-checksumming", "scatter-gather", "tcp-segmentation-offload"}
NAMES = ("generic_checksum", "ipv4_checksum", "ipv6_checksum", "ipv4_tso", "ipv6_tso",
         "ipv4_tso_mangleid", "software_gso", "scatter_gather", "ipv4_needs_gso", "ipv6_needs_gso")


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def definition(src, signature):
    pos = src.index(signature)
    return src[pos:src.index("\n}", pos) + 2]


def read_stock(names):
    blob = subprocess.check_output(["git", "show", f"{REVISION}:{ARCHIVE}"], cwd=HERE)
    assert digest(blob) == "1ade90ef711545a7ad913c8bd8725cd7fe999dd3da985944f978cd72d0265fc0"
    records = json.loads(gzip.decompress(blob))["nic"]
    stock = {}
    for key in ("original1", "original2", "original-repeat1", "original-repeat2"):
        out = records[key]
        assert str(records[key + ".status"]).strip() == "0" and "driver: virtio_net" in out
        features = out.split("Features for eth1:\n")[1].split("\n\n")[0]
        assert re.search(r"tx-checksum-ip-generic: on$", features, re.M)
        assert all(f"tx-checksum-{family}: off [fixed]" in features for family in ["ipv4", "ipv6"])
        enabled = [ALIASES.get(key, key) for key in re.findall(r"^\s*([\w-]+): on(?: \[fixed\])?$", features, re.M) if key not in AGGREGATES]
        stock[key] = {"enabled_bits": sorted(names[label] for label in enabled), "raw_feature_sha256": digest(features.encode())}
    assert len({tuple(row["enabled_bits"]) for row in stock.values()}) == 1
    return stock


def main(tree):
    sources = {name: (tree / name).read_bytes() for name in PINS}
    assert {name: digest(blob) for name, blob in sources.items()} == PINS
    src = {name: blob.decode() for name, blob in sources.items()}
    dev, net = src["net/core/dev.c"], src["include/linux/netdevice.h"]
    skb, mac = src["include/linux/skbuff.h"], src["drivers/net/macvlan.c"]
    names = {label: "NETIF_F_" + feature for feature, label in re.findall(r'\[NETIF_F_(\w+)_BIT\]\s*=\s*"([^"]+)"', src["net/ethtool/common.c"])}
    stock = read_stock(names)
    bits = stock["original1"]["enabled_bits"]
    virtio_ops = definition(src["drivers/net/virtio_net.c"], "static const struct net_device_ops virtnet_netdev")
    assert ".ndo_fix_features" not in virtio_ops and ".ndo_set_features" in virtio_ops
    assert "segs = skb_gso_segment(skb, features);" in dev
    begin = skb.rindex("enum {", 0, skb.index("SKB_GSO_TCPV4 ="))
    gso_enum = skb[begin:skb.index("\n};", begin) + 3]
    macros = mac[mac.index("#define ALWAYS_ON_OFFLOADS"):mac.index("#define MACVLAN_STATE_MASK")]
    code = [gso_enum, macros, "#define ARCHIVED_FEATURES (" + "|".join(bits) + ")"]
    code += [definition(dev, signature) for signature in ("static bool netdev_has_ip_or_hw_csum(", "static netdev_features_t netdev_fix_features(", "netdev_features_t netdev_increment_features(")]
    code += [definition(mac, "static netdev_features_t macvlan_fix_features(")]
    code += [definition(net, signature) for signature in ("static inline bool net_gso_ok(", "static inline bool skb_gso_ok(", "static inline bool netif_needs_gso(")]
    compiled = "\n".join(code)
    hdr = re.sub(r"^#include <[^>]+>\n", "", src["include/linux/netdev_features.h"], flags=re.M)
    rows = {}
    cc = os.environ.get("CC", "cc")
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp)
        (path / "features.inc").write_text(hdr)
        (path / "kernel.inc").write_text(compiled)
        exe = path / "features"
        subprocess.run([cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-I", str(path), str(HERE / "feature_fixture.c"), "-o", str(exe)], check=True)
        for arm in ("stock", "checksum-off"):
            lines = subprocess.check_output([str(exe), arm], text=True).splitlines()
            rows[arm] = {}
            for row in lines:
                iface, mask, *values = row.split()
                rows[arm][iface] = {"mask": mask, **dict(zip(NAMES, map(int, values), strict=True))}
    for arm, enabled in [("stock", 1), ("checksum-off", 0)]:
        p = rows[arm]["eth1"]
        assert p["generic_checksum"] == p["ipv4_tso"] == p["ipv6_tso"] == p["ipv4_tso_mangleid"] == enabled
        assert p["ipv4_checksum"] == p["ipv6_checksum"] == 0
        assert p["software_gso"] == p["scatter_gather"] == 1
        assert p["ipv4_needs_gso"] == p["ipv6_needs_gso"] == 1 - enabled
        assert rows[arm]["macvlan"]["ipv4_needs_gso"] == rows[arm]["macvlan"]["ipv6_needs_gso"] == 0
    return {"date": "2026-11-24", "id": "231.01", "tier": "source/fixture", "revision": REVISION,
            "archive": ARCHIVE, "archive_sha256": "1ade90ef711545a7ad913c8bd8725cd7fe999dd3da985944f978cd72d0265fc0",
            "stock_readbacks": stock, "driver": "virtio_net", "linux": "7.3.5", "files": PINS,
            "compiled_function_sha256": digest(compiled.encode()), "harness_sha256": digest((HERE / "feature_fixture.c").read_bytes()),
            "reproducer_sha256": digest(Path(__file__).read_bytes()), "compiler": subprocess.check_output([cc, "--version"], text=True).splitlines()[0],
            "request_delta": ["-NETIF_F_HW_CSUM"], "attempts": 2, "rows": rows,
            "scope": "One unchanged and one checksum-disabled request. One partial-checksum TCP GSO skb per protocol, no fragments, gso_size 1448. Macvlan modeled with fixed upper requested capabilities. No kernel boot, device mutation, packet send, CPU time or delivery measurement."}


if __name__ == "__main__":
    print(json.dumps(main(Path(sys.argv[1])), indent=2, sort_keys=True))
