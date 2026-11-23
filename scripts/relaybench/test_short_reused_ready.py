"""Check scheduling of a short reply on a previously bulk-classified relay flow."""
import json
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from test_final_read_fin import FLAGS, HERE, RELAY, ROOT, digest, run

FIXTURE = HERE / 'short_reused_ready.c'
PATCH = HERE / 'short_reused_ready.patch'
CASES = {(16, 0, 17, 0), (16, 8, 17, 0), (16, 0, 4096, 0), (16, 0, 4097, 0),
         (16, 0, 17, 65536), (32, 0, 17, 0)}


def collect():
    stock = RELAY / 'PublishedTCP.c'
    indexed = {}
    binaries = {}
    with tempfile.TemporaryDirectory() as temp:
        work = Path(temp)
        candidate = work / stock.name
        shutil.copyfile(stock, candidate)
        subprocess.run(['patch', '-s', '-F', '0', str(candidate), '-i', str(PATCH)], check=True)
        for arm, source in [('stock', stock), ('candidate', candidate)]:
            binary = work / arm
            subprocess.run(['clang', *FLAGS, '-I', str(RELAY / 'include'), f'-DRELAY_SOURCE="{source}"',
                            str(FIXTURE), '-o', str(binary)], check=True)
            binaries[arm] = digest(binary)
            output = run(binary)
            rows = {(r['background'], r['tails'], r['hint_bytes'], r['late_bytes']): r for r in output}
            if set(rows) != CASES or len(output) != len(CASES):
                raise ValueError(f'incomplete or duplicate output in {arm}')
            indexed[arm] = rows
    for key in CASES:
        background, tails, hint, late = key
        a, b = indexed['stock'][key], indexed['candidate'][key]
        expected = (background - tails) * 65536 + tails * 4096 + hint + late + 1
        if a['verified_bytes'] != expected or b['verified_bytes'] != expected:
            raise ValueError(f'changed verified work: {key}')
        if a['ahead_of_new_bytes'] != b['ahead_of_new_bytes']:
            raise ValueError(f'changed priority for the unclassified flow: {key}')
        if hint == 4097:
            if a != b:
                raise ValueError('4097-byte control changed')
            continue
        if b['ahead_of_tagged_bytes'] >= a['ahead_of_tagged_bytes']:
            raise ValueError(f'eligible read did not advance: {key}')
        if background == 16 and (b['ahead_of_new_bytes'] != 0 or b['ahead_of_tagged_bytes'] != tails * 4096 + 1):
            raise ValueError(f'changed order of fresh and previously bulk-classified flows: {key}')
        if late and (a['tagged_first_write'], b['tagged_first_write'], b['tagged_writes'],
                     b['nonempty_polls'] - a['nonempty_polls']) != (hint + late, 4096, 2, 1):
            raise ValueError('late burst was lost, uncapped, or rescanned unexpectedly')
    paths = [stock, RELAY / 'include/PublishedTCP.h', FIXTURE, PATCH, HERE / 'filter_work.c',
             HERE / 'test_final_read_fin.py', Path(__file__).resolve()]
    return {
        'method': 'Six Darwin AF_UNIX socketpair cases per arm. Stage established flows, prime all but one '
                  'with 16 KiB to activate production bulk classification, queue payloads, then drain a flat '
                  'owner once at its stock two-worker 128-event budget, width 24 and 256 KiB read cap. '
                  'Observe actual kqueue readiness and count forwarded bytes preceding each first write. '
                  'Check every byte, reverse payload, half-closes and retirement. The late-burst case appends '
                  '64 KiB after kevent returns a real 17-byte snapshot.',
        'scope': 'Deterministic service order. The new-flow marker uses an established unclassified direction. '
                 'No timed CPU, fresh connection setup, TCP or VM throughput measurement.',
        'base': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip(),
        'collected_utc': datetime.now(timezone.utc).isoformat(),
        'platform': {'machine': platform.machine(), 'darwin': platform.release(),
                     'compiler': subprocess.check_output(['clang', '--version'], text=True).splitlines()[0]},
        'flags': FLAGS, 'source_sha256': {str(p.relative_to(ROOT)): digest(p) for p in paths},
        'binary_sha256': binaries, 'rows': {arm: [rows[key] for key in sorted(CASES)] for arm, rows in indexed.items()},
    }


@unittest.skipUnless(sys.platform == 'darwin', 'requires Darwin kqueue')
class ShortReusedReadyTests(unittest.TestCase):
    def test_ready_hints_and_full_callback_order(self):
        collect()


if __name__ == '__main__':
    print(json.dumps(collect(), indent=2))
