"""Compile pinned Linux fq scheduling functions and record all dequeue first attempts."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
BASE = '922e862694ae6d6e9cb3cc9fcfd6c0a86d9ada21'
TAR = '8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990'
SOURCE = '29b796533fff2d9b2a71b3e6f4150580ccf7b07d7d87bca3d768079958331038'
FUNCTIONS = ['void fq_flow_set_detached', 'void fq_flow_add_tail', 'struct fq_flow *fq_classify',
             'struct sk_buff *fq_peek', 'void fq_erase_head', 'void fq_dequeue_skb',
             'struct fq_flow_head *fq_pband_head_select', 'struct sk_buff *fq_dequeue']


def digest(data):
    return hashlib.sha256(data).hexdigest()


def measure(source):
    text = (source / 'net/sched/sch_fq.c').read_bytes()
    assert digest(text) == SOURCE
    parts = []
    for name in FUNCTIONS:
        start = text.index(('\nstatic ' + name + '(').encode()) + 1
        parts.append(text[start:text.index(b'\n}\n', start) + 3])
    functions = b'\n'.join(parts)
    harness = HERE / 'fq_initial.c'
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        (root / 'fq_functions.inc').write_bytes(functions)
        binary = root / 'replay'
        subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-I', temp,
                        str(harness), '-o', str(binary)], check=True)
        lines = subprocess.check_output([binary], text=True).splitlines()
    observations = []
    assert len(lines) == 12
    for line in lines:
        a, b, c, order = line.split()
        initial, size, arrival = map(int, (a, b, c))
        assert sorted(order) == ['B'] * 32 + ['F'] + ['O'] * 32
        ahead = order[arrival:order.index('F')]
        observations.append(dict(initial_quantum_bytes=initial, new_bulk_skb_bytes=size,
                                 fresh_arrives_after_total_dequeues=arrival, raw_dequeue_order=order,
                                 intervening_skbs=len(ahead),
                                 intervening_qdisc_bytes=ahead.count('O') * 1514 + ahead.count('B') * size,
                                 first_old_position_1based=order.index('O')+1,
                                 drained_qdisc_bytes=32*(size+1514)+256))
    return dict(date='2026-11-24', stable_id='231.08', evidence_tier='source/fixture', micropod_base=BASE,
                linux_version='7.3.5', linux_tar_sha256=TAR, sch_fq_sha256=SOURCE,
                functions=FUNCTIONS, functions_sha256=digest(functions),
                fixture_sha256=digest(harness.read_bytes()), script_sha256=digest(Path(__file__).read_bytes()),
                cc=subprocess.check_output(['cc', '--version'], text=True).splitlines()[0],
                fixture='One eligible band, unlimited pacing, ordered fixed timestamps, no device. '
                        'Old O (already active, 32 x 1514 B, ordinary credit 3028 B). Newly classified '
                        'bulk B (32 x selected size); newly classified F (1 x 256 B) appended at ordinal 0, 1 or 12. '
                        'Ordinary quantum 3028 B in both arms. Stock initial quantum 15140 B, candidate 3028 B.',
                observations=observations)


if __name__ == '__main__':
    print(json.dumps(measure(Path(sys.argv[1])), indent=2))
