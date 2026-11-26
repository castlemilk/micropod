"""Balanced private socketpair timing for the bounded short-read scheduling patch."""
import json
import platform
import random
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from statistics import median

from check_handshake_reads import FLAGS
from gamma_contrasts import paired_median_interval
from test_final_read_fin import HERE, RELAY, ROOT, digest, run
from test_short_reused_ready import PATCH

FIXTURE = HERE / 'short_reused_timing.c'
SEED = 241106
PAIRS = 16


def sample(binary, workload):
    row, = run(binary, workload)
    waves = 64
    mixed = workload == 'mixed'
    if (row['waves'] != waves or row['bytes'] != waves * (1048576 + (18 if mixed else 0))
            or len(row['tag_ns']) != (waves if mixed else 0)
            or not 0 < row['owner_cpu_ns'] <= row['wall_ns'] or not all(t > 0 for t in row['tag_ns'])):
        raise ValueError(f'incomplete timing case: {workload} {row}')
    metrics = {'verified_mib_s': (row['bytes'] / 2**20) / (row['wall_ns'] / 1e9),
               'owner_cpu_ms_per_gib': row['owner_cpu_ns'] / 1e6 / (row['bytes'] / 2**30)}
    if mixed:
        ordered = sorted(row['tag_ns'])
        metrics.update(tag_p50_us=median(ordered) / 1000, tag_p95_us=ordered[60] / 1000,
                       tag_p99_us=ordered[63] / 1000)
    return row | {'metrics': metrics}


def collect():
    stock = RELAY / 'PublishedTCP.c'
    blocks = []
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        candidate = work / stock.name
        shutil.copyfile(stock, candidate)
        subprocess.run(['patch', '-s', '-F', '0', str(candidate), '-i', str(PATCH)], check=True)
        binaries = {}
        for arm, source in [('stock', stock), ('candidate', candidate)]:
            binary = work / arm
            subprocess.run(['clang', *FLAGS, '-I', str(RELAY / 'include'), f'-DRELAY_SOURCE="{source}"',
                            str(FIXTURE), '-o', str(binary)], check=True)
            binaries[arm] = binary
            for mode in ('mixed', 'bulk'):
                sample(binary, mode)
        binary_hashes = {arm: digest(binary) for arm, binary in binaries.items()}
        rng = random.Random(SEED)
        orders = {}
        for mode in ('mixed', 'bulk'):
            orders[mode] = [('candidate', 'stock'), ('stock', 'candidate')] * (PAIRS // 2)
            rng.shuffle(orders[mode])
        workloads = [('mixed', 'bulk'), ('bulk', 'mixed')] * (PAIRS // 2)
        rng.shuffle(workloads)
        for i, modes in enumerate(workloads):
            block = {'workload_order': modes}
            for mode in modes:
                order = orders[mode][i]
                block[mode] = {'arm_order': order, **{arm: sample(binaries[arm], mode) for arm in order}}
            blocks.append(block)
    summary = {}
    for mode in ('mixed', 'bulk'):
        summary[mode] = {}
        for name in blocks[0][mode]['stock']['metrics']:
            values = {arm: [b[mode][arm]['metrics'][name] for b in blocks] for arm in ('stock', 'candidate')}
            ratios = [b / a for a, b in zip(values['stock'], values['candidate'])]
            summary[mode][name] = {
                'arm_medians': {k: median(v) for k, v in values.items()},
                'paired_median_change_pct': 100 * (median(ratios) - 1),
                'paired_bootstrap_95_pct': [100 * (v - 1) for v in paired_median_interval(ratios)],
            }
    files = [stock, RELAY / 'include/PublishedTCP.h', FIXTURE, PATCH, HERE / 'filter_work.c',
             HERE / 'test_final_read_fin.py', HERE / 'test_short_reused_ready.py',
             HERE / 'check_handshake_reads.py', HERE / 'gamma_contrasts.py', Path(__file__).resolve()]
    return {'method': 'Sixteen balanced pairs per workload on one background thread. After two unscored waves, '
                      'each measured invocation runs 64 waves. Sixteen already bulk-classified streams each offer '
                      '64 KiB once per wave. The mixed workload adds a 17-byte reply on a previously bulk flow '
                      'and one byte on an unclassified stream. Wall throughput includes offering, relay and '
                      'verification. CPU counts the relay callback. Marker time starts at callback entry and ends '
                      'after the successful write. Bootstrap resamples full paired invocations. This is a '
                      'host socketpair service-order experiment, excluding TCP connection setup and the VM.',
            'primary': 'mixed tag_p95_us', 'collected_utc': datetime.now(timezone.utc).isoformat(),
            'seed': SEED, 'pairs': PAIRS, 'flags': FLAGS, 'arch': platform.machine(), 'darwin': platform.release(),
            'compiler': subprocess.check_output(['clang', '--version'], text=True).splitlines()[0],
            'base': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip(),
            'sha256': {str(p.relative_to(ROOT)): digest(p) for p in files},
            'binary_sha256': binary_hashes, 'summary': summary, 'blocks': blocks}


if __name__ == '__main__':
    print(json.dumps(collect(), indent=2))
