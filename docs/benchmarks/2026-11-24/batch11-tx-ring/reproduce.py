"""Test stock vs doubled TX ring requests against pinned source and posted ethtool state."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REV = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
ARCHIVE = "docs/benchmarks/2026-11-24/tx-offload-bql-readbacks.json.gz"
DRIVER_HASH = "d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace"
READBACK_HASH = "1ade90ef711545a7ad913c8bd8725cd7fe999dd3da985944f978cd72d0265fc0"
NAMES = ("original1", "original2", "original-repeat1", "original-repeat2")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def get_function(source, signature):
    pos = source.index(signature)
    return source[pos:source.index("\n}", pos) + 2]


def replay(driver, output):
    source_bytes = driver.read_bytes()
    assert digest(source_bytes) == DRIVER_HASH
    source = source_bytes.decode()
    functions = [get_function(source, sig) for sig in ("static void virtnet_get_ringparam(",
                                                      "static int virtnet_set_ringparam(")]
    archive = subprocess.check_output(["git", "show", f"{REV}:{ARCHIVE}"], cwd=HERE)
    assert digest(archive) == READBACK_HASH
    readbacks = json.loads(gzip.decompress(archive))["nic"]
    observations = []
    with tempfile.TemporaryDirectory() as scratch:
        directory = Path(scratch)
        (directory / "driver.inc").write_text("\n\n".join(functions))
        exe = directory / "ring"
        subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-O2", "-I", scratch,
                        str(HERE / "fixture.c"), "-o", str(exe)], check=True)

        def request(rx_max, rx_now, tx_max, tx_now, desired):
            proc = subprocess.check_output([str(exe), *map(str, (rx_max, rx_now, tx_max, tx_now, desired))])
            keys = ("linux_status", "tx_resize_calls", "rx_resize_calls", "final_rx_entries", "final_tx_entries")
            return {"requested_tx_entries": desired, **dict(zip(keys, map(int, proc.split()), strict=True))}

        for name in NAMES:
            raw = readbacks[name]
            assert "driver: virtio_net\n" in raw and str(readbacks[name + ".status"]).strip() == "0"
            ring = raw.split("Ring parameters for eth1:\n", 1)[1].split("\n\n", 1)[0]
            high, now = ring.split("Current hardware settings:\n")
            def value(txt, which):
                return int(re.search(rf"^{which}:\s+(\d+)$", txt, re.M).group(1))
            limits = [value(high, "RX"), value(now, "RX"), value(high, "TX"), value(now, "TX")]
            assert limits == [256] * 4
            arms = [request(*limits, wanted) for wanted in (limits[3], 2 * limits[3])]
            assert [arm["linux_status"] for arm in arms] == [0, -22]
            assert all(arm["tx_resize_calls"] == arm["rx_resize_calls"] == 0 for arm in arms)
            observations.append({"readback": name, "header_sha256": digest(ring.encode()),
                                 "ethtool_ring_header": ring, "arms": arms})
        # Positive check that a permitted size does reach TX alone. Hardware is deliberately stubbed.
        positive = request(256, 256, 512, 256, 512)
        assert positive["linux_status"] == -12345 and positive["tx_resize_calls"] == 1
        assert positive["rx_resize_calls"] == 0

    data = {"micropod_analysis_revision": REV, "linux_version": "7.3.5",
            "virtio_net_sha256": DRIVER_HASH, "raw_readback_archive_sha256": READBACK_HASH,
            "observations": observations, "synthetic_positive_control": positive,
            "positive_control_note": "With advertised max TX 512, return sentinel -12345 at the first TX resize call. No hardware completion simulated."}
    with output.open("x") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("driver", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    replay(args.driver, args.output)
