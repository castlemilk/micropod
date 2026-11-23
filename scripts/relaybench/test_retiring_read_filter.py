"""Compare both EOF orders on unchanged and patched native Darwin relay sources."""
import itertools
import json
import platform
import random
import statistics
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from check_handshake_reads import FLAGS as OPTIMIZED_FLAGS, run as run_lifecycle
from gamma_contrasts import paired_median_interval

from test_final_read_fin import FLAGS, HERE, RELAY, ROOT, digest, run


FIXTURE = HERE / 'retiring_read_filter.c'
PATCH = HERE / 'retiring_read_filter.patch'
CASES = set(itertools.product(('flat', 'split'), ('client', 'guest'),
                              ('ordinary', 'partial_write', 'flagged_error')))


def lifecycle_screen(work, sources):
    seed = 231126
    order_rng = random.Random(seed)
    orders = [('stock', 'candidate'), ('candidate', 'stock')] * 8
    order_rng.shuffle(orders)
    binaries = {}
    for arm, source in sources:
        binary = work / (arm + '-lifecycle')
        subprocess.run(['clang', *OPTIMIZED_FLAGS, '-I', str(RELAY / 'include'),
                        f'-DRELAY_SOURCE="{source}"', str(HERE / 'handshake_reads.c'), '-o', str(binary)], check=True)
        binaries[arm] = binary
        run_lifecycle(binary, 'measure')
    blocks = []
    for order in orders:
        block = {'order': order}
        for arm in order:
            samples = run_lifecycle(binaries[arm], 'measure')
            for i, row in enumerate(samples):
                if (row['flows'] != 512 or row['setup_change_syscalls'] != (3, 6)[i] * 512 or
                        row['setup_filters'] != row['setup_change_syscalls'] or
                        not 0 < row['setup_cpu_ns'] < row['relay_cpu_ns']):
                    raise ValueError(f'unmatched fresh flow work: {arm} {row}')
            block[arm] = samples
        blocks.append(block)
    summary = {}
    for i, mode in enumerate(('immediate', 'async')):
        per_flow = {arm: [block[arm][i]['relay_cpu_ns'] / block[arm][i]['flows'] for block in blocks]
                    for arm in ('stock', 'candidate')}
        ratios = [b / a for a, b in zip(per_flow['stock'], per_flow['candidate'])]
        summary[mode] = {
            'median_cpu_ns_per_flow': {arm: statistics.median(times) for arm, times in per_flow.items()},
            'paired_median_change_pct': 100 * (statistics.median(ratios) - 1),
            'paired_bootstrap_95_pct': [100 * (r - 1) for r in paired_median_interval(ratios)],
            'candidate_lower_pairs': sum(r < 1 for r in ratios),
        }
    return {
        'primary': 'Asynchronous full-flow relay thread CPU nanoseconds per flow.',
        'method': 'Dedicated flat owner on one background QoS thread. Each arm has one unscored warmup then '
                  'sixteen randomized, order-balanced pairs. Every arm forwards and checks 512 immediate and '
                  '512 asynchronous 98-byte requests and 148-byte replies. CPU time includes adoption, data '
                  'and close drains. The identical flow fixture counts filter calls, substitutes a connected '
                  'anonymous socket for guest TCP, and verifies responses and both FINs outside the clocks.',
        'seed': seed, 'flags': OPTIMIZED_FLAGS,
        'binary_sha256': {arm: digest(path) for arm, path in binaries.items()}, 'summary': summary, 'blocks': blocks,
    }


def collect(timing=False):
    rows = {}
    binaries = {}
    with tempfile.TemporaryDirectory(prefix='retiring-read-filter-') as tmp:
        work = Path(tmp)
        stock = RELAY / 'PublishedTCP.c'
        patched = work / stock.name
        shutil.copyfile(stock, patched)
        subprocess.run(['patch', '-s', '-F', '0', str(patched), '-i', str(PATCH)], check=True)
        sources = (('stock', stock), ('candidate', patched))
        for arm, source in sources:
            binary = work / arm
            subprocess.run(['clang', *FLAGS, '-I', str(RELAY / 'include'),
                            f'-DRELAY_SOURCE="{source}"', str(FIXTURE), '-o', str(binary)], check=True)
            binaries[arm] = digest(binary)
            samples = run(binary)
            indexed = {(r['owner'], r['first_fin'], r['scenario']): r for r in samples}
            if len(samples) != len(CASES) or set(indexed) != CASES:
                raise ValueError(f'{arm}: missing or duplicated case')
            rows[arm] = indexed
        timed = lifecycle_screen(work, sources) if timing else None
    comparisons = []
    for key in sorted(CASES):
        a, b = (rows[arm][key] for arm in ('stock', 'candidate'))
        last_a, last_b = a['last_filter_calls'], b['last_filter_calls']
        flagged = key[-1] == 'flagged_error'
        if last_a - last_b != int(not flagged):
            raise ValueError(f'{key}: unexpected final filter submissions {last_a}, {last_b}')
        for field in ('bytes', 'first_filter_calls', 'last_zero_reads', 'last_write_shutdowns'):
            if a[field] != b[field]:
                raise ValueError(f'{key}: changed {field}')
        if (a['first_filter_calls'], a['last_zero_reads'], a['last_write_shutdowns']) != (1, 1, int(not flagged)):
            raise ValueError(f'{key}: incorrect first FIN, final read or explicit shutdown')
        comparisons.append({k: v for k, v in a.items() if k != 'last_filter_calls'} |
                           {'stock_last_filter_calls': last_a, 'candidate_last_filter_calls': last_b})
    inputs = [stock, RELAY / 'include/PublishedTCP.h', PATCH, FIXTURE, HERE / 'filter_work.c',
              HERE / 'test_final_read_fin.py', HERE / 'check_handshake_reads.py', HERE / 'gamma_contrasts.py',
              HERE / 'handshake_reads.c', Path(__file__).resolve()]
    return {
        'method': 'Each arm runs the native event loop on established AF_UNIX stream pairs. Counts are real '
                  'kqueue filter-change submissions from the reverse payload through retirement. Each row also '
                  'checks byte order, both zero-length reads and explicit write shutdowns. The error control '
                  'marks an observed empty EOF event with ECONNRESET.',
        'scope': 'Fixed-work call counts on Darwin. The stock and candidate perform the final empty read. '
                 'Live TCP, VM throughput and request latency were not measured.',
        'base': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip(),
        'completed_utc': datetime.now(timezone.utc).isoformat(),
        'arch': platform.machine(), 'darwin': platform.release(),
        'compiler': subprocess.check_output(['clang', '--version'], text=True).splitlines()[0],
        'flags': FLAGS, 'sha256': {str(p.relative_to(ROOT)): digest(p) for p in inputs},
        'binary_sha256': binaries, 'cases_per_arm': len(CASES), 'rows': comparisons,
        **({'lifecycle_cpu': timed} if timing else {}),
    }


@unittest.skipUnless(sys.platform == 'darwin', 'requires Darwin kqueue')
class RetiringReadFilterTests(unittest.TestCase):
    def test_two_half_closes_and_error_retirement(self):
        collect()


if __name__ == '__main__':
    if sys.argv[1:] not in ([], ['--timing']):
        raise SystemExit('usage: test_retiring_read_filter.py [--timing]')
    print(json.dumps(collect(timing=bool(sys.argv[1:])), indent=2))
