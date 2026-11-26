"""Measure bounded full-duplex datagram admission on a paused Darwin socket pair."""
import collections
import errno
import hashlib
import json
import platform
import random
import socket
import struct
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path

HERE = Path(__file__).resolve().parent
OFFERS = 48
SEED = 2290302
KIB = 1024


def sha(data):
    return hashlib.sha256(data).hexdigest()


def frame(mtu, direction, sequence):
    source, dest = (1, 2) if direction == 0 else (2, 1)
    source_mac = bytes([2, 0, 0, 0, 0, source])
    dest_mac = bytes([2, 0, 0, 0, 0, dest])
    ether = dest_mac + source_mac + b'\x08\x00'
    ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, mtu, sequence, 0x4000, 64, 253, 0,
                     socket.inet_aton(f'192.0.2.{source}'), socket.inet_aton(f'192.0.2.{dest}'))
    checksum = sum(struct.unpack('!10H', ip))
    while checksum >> 16:
        checksum = (checksum & 0xffff) + (checksum >> 16)
    ip = ip[:10] + struct.pack('!H', 0xffff ^ checksum) + ip[12:]
    body = bytes([direction, sequence]) * mtu
    return ether + ip + body[:mtu - len(ip)]


@contextmanager
def attachment(helper, endpoint, mtu):
    fd = endpoint.fileno()
    with subprocess.Popen([helper, str(fd), str(mtu)], pass_fds=(fd,), text=True,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
        try:
            values = tuple(map(int, child.stdout.readline().split()))
            if values != (mtu, fd):
                raise ValueError(f'attachment readback: {values}')
            yield values[0]
        finally:
            child.communicate('q')
            if child.returncode != 0:
                raise RuntimeError(f'attachment helper exited {child.returncode}')


def configure(sock, send, receive):
    sock.setblocking(False)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, send)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, receive)


def burst(helper, mtu, buffers, leading):
    left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    endpoints = [left, right]  # file handle client (peer), attachment fd
    with left, right:
        for sock, (send, receive) in zip(endpoints, buffers):
            configure(sock, send, receive)
        with attachment(helper, right, mtu) as readback:
            effective = [[sock.getsockopt(socket.SOL_SOCKET, key)
                          for key in (socket.SO_SNDBUF, socket.SO_RCVBUF)] for sock in endpoints]
            if effective != [list(pair) for pair in buffers]:
                raise ValueError(f'socket option readback {effective}, requested {buffers}')
            expected = [[], []]
            refused = [collections.Counter(), collections.Counter()]
            for index in range(OFFERS):
                for direction in [leading, 1 - leading]:
                    packet = frame(mtu, direction, index)
                    try:
                        sent = endpoints[direction].send(packet)
                    except OSError as exc:
                        if exc.errno not in (errno.EAGAIN, errno.ENOBUFS, errno.EMSGSIZE):
                            raise
                        refused[direction][errno.errorcode[exc.errno]] += 1
                    else:
                        if sent != len(packet):
                            raise ValueError('short datagram send')
                        expected[direction].append(packet)

            observations = []
            for direction, target in enumerate([right, left]):
                received = []
                while True:
                    try:
                        data, _, flags, _ = target.recvmsg(mtu + 15)
                    except BlockingIOError:
                        break
                    if flags & socket.MSG_TRUNC:
                        raise ValueError('truncated frame')
                    received.append(data)
                if expected[direction] != received or len(received) + sum(refused[direction].values()) != OFFERS:
                    raise ValueError('delivery, order, frame content or offer accounting mismatch')
                marker = frame(64, direction, OFFERS)
                if endpoints[direction].send(marker) != len(marker) or target.recv(128) != marker:
                    raise ValueError('post-drain recovery failed')
                observations.append(dict(received=len(received), received_bytes=sum(map(len, received)),
                                         refused=refused[direction], post_drain_marker=True,
                                         expected_sha256=sha(b''.join(expected[direction])),
                                         received_sha256=sha(b''.join(received))))
            return dict(attachment_mtu_readback=readback, effective_buffers=effective,
                        leading_sender=leading, client_to_fd=observations[0], fd_to_client=observations[1])


def configs(mtu):
    cases = dict(small_sender_4x=((8192, 32768),) * 2, qualified_2x=((16384, 32768),) * 2,
                 qualified_4x=((16384, 65536),) * 2,
                 client_only_4x=((16384, 65536), (16384, 32768)))
    cases['one_byte_short'] = ((mtu + 13, 65536),) * 2
    cases['exact_frame'] = ((mtu + 14, 65536),) * 2
    return cases


def main():
    if platform.system() != 'Darwin':
        raise RuntimeError('requires Darwin and the Virtualization SDK')
    sdk = Path(subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip())
    header = sdk / 'System/Library/Frameworks/Virtualization.framework/Headers/VZFileHandleNetworkDeviceAttachment.h'
    result = dict(issue='229.03', tier='Darwin socket pair and VZ attachment configuration',
                  macOS=platform.mac_ver()[0], arch=platform.machine(), sdk=str(sdk),
                  sdk_version=subprocess.check_output(['xcrun', '--show-sdk-version'], text=True).strip(),
                  checkout=subprocess.check_output(['git', '-C', HERE, 'rev-parse', 'HEAD'], text=True).strip(),
                  sources_sha256={p.name: sha(p.read_bytes()) for p in (Path(__file__), HERE / 'attachment.m', header)},
                  offered_frames_per_direction=OFFERS, seed=SEED, blocks=[])
    rng = random.Random(SEED)
    with tempfile.TemporaryDirectory() as tmp:
        helper = Path(tmp) / 'attachment'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror', '-fobjc-arc', '-framework', 'Foundation',
                        '-framework', 'Virtualization', HERE / 'attachment.m', '-o', helper], check=True)
        for block_index in range(4):
            cases = [(mtu, name, buffers) for mtu in (1500, 9000) for name, buffers in configs(mtu).items()]
            rng.shuffle(cases)
            block = []
            for mtu, name, buffers in cases:
                row = burst(helper, mtu, buffers, block_index % 2)
                block.append(dict(mtu=mtu, name=name, **row))
            result['blocks'].append(block)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
