"""Compile Linux MTU-probe and retry gates; model fixed DF forwarding and byte receipt."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
PAYLOAD = bytes((i * 19 + 1) % 256 for i in range(17896))
DIGEST = hashlib.sha256(PAYLOAD).hexdigest()


def forward(mss):
    received = bytearray()
    rejected = 0
    accepted = 0
    for offset in range(0, len(PAYLOAD), mss):
        part = PAYLOAD[offset : offset + mss]
        if len(part) + 52 > 1500:
            rejected += 1
            continue
        received.extend(part)
        accepted += 1
    return dict(accepted=accepted, rejected_oversize=rejected, receiver_bytes=len(received),
                receiver_sha256=hashlib.sha256(received).hexdigest(), complete=received == PAYLOAD)


def main():
    observations = []
    with tempfile.TemporaryDirectory() as tmp:
        binary = Path(tmp) / "fixture"
        subprocess.run(["cc", "-std=c11", "-Wall", "-Werror", str(HERE / "fixture.c"),
                        "-o", str(binary)], check=True)
        for setting in (0, 1):
            out = subprocess.check_output([binary, str(setting)], text=True)
            for line in out.splitlines():
                elapsed, mss, enabled, low = map(int, line.split())
                observations.append(dict(tcp_mtu_probing=setting, elapsed_since_first_retransmit_ms=elapsed,
                                         send_mss=mss, probing_enabled=enabled, search_low_mtu=low,
                                         simulated_df_receiver=forward(mss)))
    assert [r["send_mss"] for r in observations] == [8948] * 5 + [1024]
    assert [r["simulated_df_receiver"]["complete"] for r in observations] == [False] * 5 + [True]
    def sha(name):
        return hashlib.sha256((HERE / name).read_bytes()).hexdigest()
    return dict(date="2026-11-24", stable_id="229.02", tier="source/fixture",
                micropod_head="2e9b37c1e68334c443d71b729f0bd6334d824ddd", linux="v7.3.5",
                kernel_config_sha256="a0da9a6ab98e69e253f2e8a27664bdb23f08ab4cef1dd66178c38c26d0035c9c",
                hz=250, source_sha256={f:sha(f) for f in ("fixture.c","kernel_excerpt.h","source.json","reproduce.py")},
                fixture=dict(ipv4_header=20,tcp_header_including_timestamps=32, cached_pmtu=9000,
                             advertised_mss=8960, tcp_window=262144, bottleneck_mtu=1500,
                             feedback="no ICMP PTB; unchanged destination", df=True,
                             payload_bytes=len(PAYLOAD),payload_sha256=DIGEST),
                observations=observations)


if __name__ == "__main__":
    print(json.dumps(main(), indent=2))
