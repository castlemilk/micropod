"""Verify the final-payload half-close candidate using Darwin kqueue and local stream pairs."""
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RELAY = ROOT / 'Sources/CPublishedTCP'
FIXTURE = HERE / 'final_read_fin.c'
PATCH = HERE / 'final_read_fin.patch'
FLAGS = ['-std=gnu11', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
         '-fsanitize=address,undefined', '-fno-sanitize-recover=all']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(binary, *args):
    result = subprocess.run([str(binary), *args], check=True, capture_output=True, text=True, timeout=15)
    if result.stderr:
        raise ValueError('fixture diagnostics: ' + result.stderr)
    return [json.loads(line) for line in result.stdout.splitlines()]


def collect():
    rows = {}
    binaries = {}
    lifecycle = {}
    expected = {'empty', 'short', 'over-cap', 'delayed-fin', 'limited-read', 'short-write', 'flagged-terminal-event'}
    with tempfile.TemporaryDirectory(prefix='relay-final-fin-') as tmp:
        work = Path(tmp)
        candidate = work / 'PublishedTCP.c'
        shutil.copyfile(RELAY / candidate.name, candidate)
        subprocess.run(['patch', '-s', '-F', '0', str(candidate), '-i', str(PATCH)], check=True)
        for arm, source in [('stock', RELAY / candidate.name), ('candidate', candidate)]:
            binary = work / arm
            subprocess.run(['clang', *FLAGS, '-I', str(RELAY / 'include'), f'-DRELAY_SOURCE="{source}"',
                            str(FIXTURE), '-o', str(binary)], check=True)
            output = run(binary)
            rows[arm] = {row['case']: row for row in output}
            if len(output) != len(expected) or set(rows[arm]) != expected:
                raise ValueError('incomplete terminal-read cases')
            checks = run(binary, 'qualify')
            if {(x['owner'], x['room_bytes']) for x in checks} != {
                    (owner, space) for owner in ('dedicated', 'split') for space in (0, 16 * 1024)}:
                raise ValueError('missing pressured lease release qualification')
            lifecycle[arm] = checks
            binaries[arm] = digest(binary)
    for case in expected:
        a, b = (rows[arm][case] for arm in ('stock', 'candidate'))
        saved = int(case in ('short', 'over-cap', 'limited-read'))
        for field in ('zero_reads', 'reads', 'ready_events', 'empty_fin_events', 'ready_polls'):
            if a[field] - b[field] != saved or a['zero_reads'] != 1:
                raise ValueError(f'{case}: unexpected {field}: {a[field]} vs {b[field]}')
        for field in ('bytes', 'writes', 'partial_writes', 'disable_reads', 'data_fin_events', 'first_fin_bytes'):
            if a[field] != b[field]:
                raise ValueError(f'{case}: different work in {field}')
    source = [RELAY / 'PublishedTCP.c', RELAY / 'include/PublishedTCP.h', HERE / 'filter_work.c',
              PATCH, FIXTURE, Path(__file__).resolve()]
    return {'method': 'One isolated established relay flow per scenario, real AF_UNIX sockets and Darwin kqueue. '
                      'Read, write and poll counts cover the guest response and its FIN. The reverse-data and '
                      'two-way FIN controls run after counting. A separate suite revokes pressured leases on '
                      'both queue types. The flagged event and limited read are injected controls.',
            'coverage': 'No TCP, VM, latency or throughput measurement. Actual TCP FIN/reset races and the '
                        'fraction of TCP responses arriving together with FIN require their own qualification.',
            'darwin': platform.release(), 'arch': platform.machine(),
            'compiler': subprocess.check_output(['clang', '--version'], text=True).splitlines()[0],
            'flags': FLAGS, 'source_sha256': {str(p.relative_to(ROOT)): digest(p) for p in source},
            'binary_sha256': binaries, 'rows': rows, 'lifecycle': lifecycle}


@unittest.skipUnless(sys.platform == 'darwin', 'requires Darwin kqueue')
class FinalReadFinTests(unittest.TestCase):
    def test_terminal_event_counts_and_bidirectional_stream_lifetime(self):
        collect()


if __name__ == '__main__':
    print(json.dumps(collect(), indent=2))
