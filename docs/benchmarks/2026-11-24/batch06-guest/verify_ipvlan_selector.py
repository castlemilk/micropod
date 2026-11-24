"""Replay the same synthetic IPv4 corpus with the lease keyed directly from TCP wire bytes."""
import hashlib
import json
from pathlib import Path
import socket
import struct

from ipvlan_l3 import checksum, frame


def translate(packet, leases):
    if packet[12:14] != bytes.fromhex("0800") or packet[14] != 0x45 or packet[23] != 6:
        raise ValueError("expected the recorded IPv4/TCP frame layout")
    port = struct.unpack_from("!H", packet, 36)[0]
    destination = leases.get(port)
    if destination is None:
        return packet
    out = bytearray(packet)
    out[30:34] = destination
    out[24:26] = bytes(2)
    struct.pack_into("!H", out, 24, checksum(out[14:34]))
    out[50:52] = bytes(2)
    pseudo = out[26:34] + struct.pack("!BBH", 0, 6, len(out)-34)
    struct.pack_into("!H", out, 50, checksum(pseudo + out[34:]))
    return bytes(out)


if __name__ == "__main__":
    raw = json.loads(Path(__file__).with_name("ipvlan-l3.json").read_text())
    control, candidate = [raw["arms"][n]["frames"] for n in ("worker_ip", "leased_child_ip")]
    leases = {18080:socket.inet_aton("192.0.2.20"), 18081:socket.inet_aton("192.0.2.21")}
    for seq, (a, b) in enumerate(zip(control, candidate, strict=True)):
        payload = hashlib.sha256(f"service-marker-{seq}".encode()).digest()
        original = frame(seq, a["port"], socket.inet_aton("192.0.2.5"), socket.inet_aton("192.0.2.1"), payload)
        assert hashlib.sha256(original).hexdigest() == a["frame_sha256"]
        actual = translate(original, leases)
        assert hashlib.sha256(actual).hexdigest() == b["frame_sha256"]
    assert len(control) == 96
    print("Independent TCP destination-port lookup reproduced all 96 candidate frame digests.")
