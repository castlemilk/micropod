"""Compare the published worker IP with per-lease IPv4 selection on unicast input."""
import ctypes
import hashlib
import json
import socket
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE = "17bcd4355234b11da3a7a1da2ded52f4dc20f5d1"
SOURCE = "172136934bfd87a8d29c2ba34b51eb2a5663551dc8a84360ac1fa6266c88d4c3"
PUB = "guest/runner/docker_port_direct_linux.go"
KERNEL_SOURCE = "linux-7.3.5/drivers/net/ipvlan/ipvlan_core.c"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def function(source, sig):
    start = source.index(sig)
    return source[start:source.index("\n}", start) + 2] + "\n"


def checksum(buf):
    if len(buf) % 2:
        buf += bytes(1)
    total = sum(x[0] for x in struct.iter_unpack("!H", buf))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return (~total) & 65535


def frame(seq, port, dst, sender, payload):
    segment = bytearray(struct.pack("!HHIIBBHHH", 31000+seq, port, 1, 1, 0x50, 0x18, 16384, 0, 0) + payload)
    pseudo = sender + dst + struct.pack("!BBH", 0, 6, len(segment))
    struct.pack_into("!H", segment, 16, checksum(pseudo + segment))
    ip = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20+len(segment), seq, 0x4000, 64, 6, 0, sender, dst))
    struct.pack_into("!H", ip, 10, checksum(ip))
    ether = bytes.fromhex("0200000000010200000000020800")
    return ether + ip + segment


def score(selector, translated, target, sender, workers):
    rows = []
    delivered = {1: bytearray(), 2: bytearray()}
    expected = {1: bytearray(), 2: bytearray()}
    for seq in range(96):
        wanted, port = ((1, 18080), (2, 18081), (0, 19000))[seq % 3]
        payload = hashlib.sha256(f"service-marker-{seq}".encode()).digest()
        dst = target
        if translated and wanted:
            dst = workers[wanted-1]
        wire = frame(seq, port, dst, sender, payload)
        tcp = wire[34:]
        assert checksum(wire[14:34]) == checksum(wire[26:34] + struct.pack("!BBH",0,6,len(tcp)) + tcp) == 0
        owner = selector(wire[30:34], *workers)
        assert not (owner != wanted and owner > 0)
        if wanted:
            expected[wanted].extend(payload)
        if owner:
            delivered[owner].extend(tcp[20:])
        rows.append(dict(seq=seq, port=port, expected= wanted, received_by=owner, frame_sha256=digest(wire)))
    return dict(offered_per_lease=32, unleased_frames=32,
                correct_lease_frames=sum(r["expected"] > 0 and r["received_by"] == r["expected"] for r in rows),
                wrong_lease_frames=sum(r["received_by"] > 0 and r["received_by"] != r["expected"] for r in rows),
                unleased_parent_pass=sum(r["expected"] == r["received_by"] == 0 for r in rows),
                expected_payload_sha256=[digest(x) for x in expected.values()],
                received_payload_sha256=[digest(x) for x in delivered.values()],frames=rows)


def run(kernel):
    data = Path(kernel).read_bytes()
    assert digest(data) == SOURCE
    driver = data.decode()
    assert 'return ipvlan_handle_mode_l3(pskb, port);' in function(driver,'static rx_handler_result_t ipvlan_handle_mode_l2(')
    pub = subprocess.check_output(['git','show',f'{BASE}:{PUB}'],cwd=HERE)
    assert b'ether daddr set tcp dport map @listeners' in pub
    source = '\n'.join(function(driver,sig) for sig in ('static struct ipvl_addr *ipvlan_ht_addr_lookup4(',
                  'struct ipvl_addr *ipvlan_addr_lookup(', 'static rx_handler_result_t ipvlan_handle_mode_l3('))
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp/'ipvlan_functions.inc').write_text(source)
        subprocess.run(['cc','-std=c11','-Wall','-Werror','-shared','-fPIC','-I',str(tmp),
                        str(HERE/'ipvlan_probe.c'),'-o',str(tmp/'selector.so')],check=True)
        select = ctypes.CDLL(str(tmp/'selector.so')).choose_child
        select.argtypes = [ctypes.c_char_p] * 3
        parent, sender, *workers = map(socket.inet_aton,['192.0.2.5','192.0.2.1','192.0.2.20','192.0.2.21'])
        arms={name:score(select,mode,parent,sender,workers) for name,mode in [('worker_ip',False),('leased_child_ip',True)]}
    assert [x['correct_lease_frames'] for x in arms.values()] == [0,64]
    assert all(x['unleased_parent_pass'] == 32 for x in arms.values())
    assert arms['leased_child_ip']['expected_payload_sha256'] == arms['leased_child_ip']['received_payload_sha256']
    return dict(id='233.02',base=BASE,tier='source/fixture',driver_file=KERNEL_SOURCE,driver_sha256=SOURCE,
                functions_sha256=digest(source.encode()),publisher_sha256=digest(pub),harness_sha256=digest((HERE/'ipvlan_probe.c').read_bytes()),
                reproducer_sha256=digest(Path(__file__).read_bytes()),compiler=subprocess.check_output(['cc','--version'],text=True).splitlines()[0],
                synthetic_workload='Two child IPv4 addresses on the same unicast MAC. Compare preserving worker IP vs selecting one child IP per leased TCP port. Equal unleased negative traffic. Header checksums regenerated in both arms.',
                limitation='IPv4 detector, child table, final destination and port rule are modeled. No real nftables, namespace, TCP handshake, return or security qualification.',arms=arms)


if __name__ == '__main__':
    print(json.dumps(run(sys.argv[1]),indent=2))
