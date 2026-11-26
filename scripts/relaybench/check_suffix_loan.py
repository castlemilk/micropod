"""Measure one owner-local transferable buffer using a pinned production relay and anonymous sockets."""
import hashlib
import json
import math
import platform
import random
import statistics
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
REVISION = 'f12d3ca5'
ARMS = ('stock', 'loan')
FLAGS = ['-std=gnu11', '-O2', '-Wall', '-Wextra', '-Werror']
BLOCKS = 16


def digest(data):
    return hashlib.sha256(data).hexdigest()


def build(folder, sources, arm, sanitize):
    folder.mkdir()
    for name, data in sources.items():
        (folder / name).write_bytes(data)
    if arm == 'loan':
        subprocess.run(['patch', '-s', '-F', '0', '-i', str(HERE / 'suffix_loan.patch')], cwd=folder, check=True)
    flags = list(FLAGS)
    if sanitize:
        flags.extend(['-O1', '-g', '-fsanitize=address,undefined', '-fno-sanitize-recover=all'])
    binary = folder / 'fixture'
    subprocess.run(['clang', *flags, f'-DLOAN={int(arm == "loan")}', '-DRELAY_SOURCE="PublishedTCP.c"',
                    '-DBENCH_HELPERS="filter_work.c"', '-iquote', str(folder), '-I', str(folder),
                    str(folder / 'suffix_loan.c'), '-o', str(binary)], check=True)
    return binary, digest((folder / 'PublishedTCP.c').read_bytes())


def run(binary, mode):
    result = subprocess.run([str(binary), mode], check=True, capture_output=True, text=True, timeout=18)
    if result.stderr:
        raise ValueError(f'fixture emitted diagnostics: {result.stderr}')
    rows = [json.loads(line) for line in result.stdout.splitlines()]
    if mode == 'qualify':
        if rows != [{'qualified': True}]:
            raise ValueError('incomplete ownership qualification')
    else:
        if [r['client_capacity'] for r in rows] != [1048576, 32768]:
            raise ValueError('missing pressure or roomy control')
        for r in rows:
            if (r['bulk_bytes'] != 100663296 or r['flows'] != 4 or r['waves'] != 48 or len(r['fresh_ns']) != 48
                    or min(r['fresh_ns']) <= 0 or r['elapsed_ns'] <= 0 or r['owner_ns'] <= 0):
                raise ValueError('incomplete measured wave')
    return rows


def aggregate(samples):
    total_bytes = sum(s['bulk_bytes'] for s in samples)
    fresh = sorted(ns for s in samples for ns in s['fresh_ns'])
    return {'owner_cpu_s_per_gib': sum(s['owner_ns'] for s in samples) * 2**30 / (1e9 * total_bytes),
            'verified_mib_s': total_bytes * 1e9 / (2**20 * sum(s['elapsed_ns'] for s in samples)),
            'fresh_p95_us': fresh[math.ceil(0.95 * len(fresh)) - 1] / 1000}


def summary(blocks, index):
    per_arm = {arm: [aggregate([sample['rows'][index] for sample in block if sample['arm'] == arm])
                     for block in blocks] for arm in ARMS}
    metrics = {}
    for metric in per_arm['stock'][0]:
        changes = [100 * (b[metric] / a[metric] - 1) for a, b in zip(per_arm['stock'], per_arm['loan'])]
        rng = random.Random(23007)
        boot = sorted(statistics.median(rng.choices(changes, k=len(changes))) for _ in range(10000))
        metrics[metric] = {'arm_medians': {arm: round(statistics.median(r[metric] for r in per_arm[arm]), 4) for arm in ARMS},
                           'median_paired_change_percent': round(statistics.median(changes), 2),
                           'bootstrap_95_percent_interval': [round(boot[249], 2), round(boot[9749], 2)]}
    return metrics


def main():
    if sys.platform != 'darwin':
        raise SystemExit('Requires Darwin kqueue and background thread QoS')
    revision = subprocess.check_output(['git', 'rev-parse', REVISION + '^{commit}'], cwd=ROOT, text=True).strip()
    pinned = {'PublishedTCP.c': 'Sources/CPublishedTCP/PublishedTCP.c',
              'PublishedTCP.h': 'Sources/CPublishedTCP/include/PublishedTCP.h', 'filter_work.c': 'scripts/relaybench/filter_work.c'}
    sources = {name: subprocess.check_output(['git', 'show', f'{revision}:{path}'], cwd=ROOT) for name, path in pinned.items()}
    sources['suffix_loan.c'] = (HERE / 'suffix_loan.c').read_bytes()
    blocks = []
    compiled = {}
    with tempfile.TemporaryDirectory(prefix='mp-suffix-') as work:
        root = Path(work)
        binaries = {}
        for arm in ARMS:
            checked, _ = build(root / (arm + '-checked'), sources, arm, True)
            run(checked, 'qualify')
            run(checked, 'measure')
            binaries[arm], compiled[arm] = build(root / arm, sources, arm, False)
            run(binaries[arm], 'measure')
        for i in range(BLOCKS):
            order = ('stock', 'loan', 'loan', 'stock') if not i % 2 else ('loan', 'stock', 'stock', 'loan')
            blocks.append([{'arm': arm, 'rows': run(binaries[arm], 'measure')} for arm in order])
    counters = ('writes', 'zero_writes', 'partial_writes', 'copy_ops', 'copy_bytes', 'malloc_calls', 'malloc_bytes')
    ranges = {}
    scenarios = ('roomy', 'pressured')
    for i, name in enumerate(scenarios):
        ranges[name] = {}
        for arm in ARMS:
            rows = [s['rows'][i] for b in blocks for s in b if s['arm'] == arm]
            ranges[name][arm] = {k: [min(r[k] for r in rows), max(r[k] for r in rows)] for k in counters}
    output = {'schema': 1, 'completed_utc': datetime.now(timezone.utc).isoformat(), 'darwin_release': platform.release(),
              'machine': platform.machine(), 'base_revision': revision, 'compiled_relay_sha256': compiled,
              'compiler': subprocess.check_output(['clang', '--version'], text=True).splitlines()[0], 'flags': FLAGS,
              'pinned_source_sha256': {pinned[k]: digest(sources[k]) for k in pinned},
              'diagnostic_sha256': {p.name: digest(p.read_bytes()) for p in (Path(__file__).resolve(), HERE / 'suffix_loan.c', HERE / 'suffix_loan.patch')},
              'candidate': 'On the first >=64 KiB unsent suffix on an owner without a loan, keep the consumed scratch buffer '
                           'on that direction with its write offset and switch scratch buffers. Allocate at most one extra '
                           '256 KiB buffer per owner lazily, retaining it until owner destruction. Concurrent stalled streams '
                           'and smaller suffixes continue to copy their exact remaining length.',
              'method': 'One background-QoS thread on anonymous AF_UNIX streams. Each invocation runs a roomy 1 MiB and then '
                        'a pressured 32 KiB downstream socket-buffer scenario, 4 established streams, 48 waves and 96 MiB '
                        'verified per scenario. Every wave offers two 256 KiB payloads per stream. One fresh staged handshake '
                        'and bidirectional exchange is submitted after the first owner pass. Its delay includes socketpair '
                        'creation and the loaded owner until the first response is read. One warmup per arm and 16 alternating '
                        'ABBA/BAAB blocks. Each block pools both invocations per arm. Intervals bootstrap the 16 whole blocks. '
                        'Primary metric is owner CPU seconds per verified GiB under pressure. Verified MiB/s uses full wave '
                        'wall time including seeding, comparison and the short exchanges. One thread cannot model arrivals '
                        'during a running callback. Socket setup for fresh exchanges stages connect readiness. There is no '
                        'IP, TCP, libdispatch scheduler, worker, or VM. Clock and heap/copy/write counters are equal in both arms.',
              'qualification': 'Both variants passed ASan/UBSan in measurement and dedicated ownership controls: simultaneous '
                               'blocked streams, zero and positive short writes, stalled-lease revocation and reuse while sibling '
                               'data survives, small suffix fallback, and in-order data/FIN plus reverse traffic. Candidate also '
                               'falls back to ordinary copying after failure to allocate its alternate buffer.',
              'summary': {name: summary(blocks, i) for i, name in enumerate(scenarios)}, 'counter_ranges_per_sample': ranges,
              'raw': blocks}
    print(json.dumps(output, separators=(',', ':')))


if __name__ == '__main__':
    main()
