"""Bounded, untimed Darwin datagram socket-pair burst with a paused reader."""
import errno
import hashlib
import json
import platform
import random
import socket
import struct
from pathlib import Path

BASE = 16384
SIZE = 1500
OFFERS = 128


def burst(receive_space):
    tx, rx = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    with tx, rx:
        tx.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, BASE)
        rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, receive_space)
        send = tx.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)
        receive = rx.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
        tx.setblocking(False)
        rx.setblocking(False)
        frames = [struct.pack('!I', i) + bytes([i]) * (SIZE - 4) for i in range(OFFERS)]
        accepted, refused = [], []
        for i, frame in enumerate(frames):
            try:
                if tx.send(frame) != SIZE:
                    raise ValueError("short datagram send")
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.ENOBUFS):
                    raise
                refused.append([i, errno.errorcode[exc.errno]])
            else:
                accepted.append(i)
        received = []
        while True:
            try:
                received.append(rx.recv(SIZE + 1))
            except BlockingIOError:
                break
        if received != [frames[i] for i in accepted]:
            raise ValueError("missing, reordered, duplicated, or short datagram")
        if not refused:
            raise ValueError("burst did not reach receiver capacity")
        # A fresh marker after drain checks whether the endpoint remains usable.
        marker = b"after-drain"
        if tx.send(marker) != len(marker) or rx.recv(SIZE) != marker:
            raise ValueError("marker delivery failed")
        return dict(effective_sndbuf=send, effective_rcvbuf=receive, received=len(received),
                    received_bytes=sum(map(len, received)), accepted_sequences=accepted,
                    refused=refused, marker_recovered=True,
                    received_sha256=hashlib.sha256(b''.join(received)).hexdigest())


def main():
    if platform.system() != "Darwin":
        raise RuntimeError("Darwin fixture required")
    orders = [[BASE, 4 * BASE], [4 * BASE, BASE]] * 4
    random.Random(22903).shuffle(orders)
    rows = []
    for order in orders:
        block = []
        for size in order:
            try:
                row = burst(size)
            except (OSError, ValueError) as exc:
                row = dict(error=str(exc))
            block.append(dict(requested_rcvbuf=size, **row))
        rows.append(block)
    print(json.dumps(dict(direction="229.03", date="2026-11-24", tier="local host only",
                          source_base="38e4fbca6b10e87835278d3b8bf38622333dad04",
                          fixture_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                          platform=platform.platform(), send_space=BASE, frame_bytes=SIZE,
                          offered_frames_per_arm=OFFERS, seed=22903, blocks=rows), indent=2))


if __name__ == "__main__":
    main()
