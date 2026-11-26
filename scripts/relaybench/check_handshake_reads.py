"""Compare fresh connection filter registration in the production Darwin relay on anonymous streams."""
import hashlib
import json
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
RELAY = ROOT / 'Sources/CPublishedTCP'
FLAGS = ['-std=gnu11', '-O2', '-Wall', '-Wextra', '-Werror']
ARMS = ('stock', 'deferred')
PAIRS = 12


def compile_arm(output, deferred, batched, sanitize=False, *, oneshot=False):
    flags = [*FLAGS, f'-DMICROPOD_BENCH_DEFER_HANDSHAKE_READS={int(deferred)}',
             f'-DMICROPOD_BATCH_STREAM_FILTERS={int(batched)}']
    if oneshot:
        flags.append('-DMICROPOD_BENCH_ONESHOT_CONNECT=1')
    if sanitize:
        flags += ['-O1', '-g', '-fsanitize=address,undefined', '-fno-sanitize-recover=all']
    subprocess.run(['clang', *flags, '-I', str(RELAY / 'include'), str(HERE / 'handshake_reads.c'),
                    '-o', str(output)], check=True)


def run(binary, mode):
    result = subprocess.run([str(binary), mode], check=True, capture_output=True, text=True, timeout=10)
    rows = [json.loads(line) for line in result.stdout.splitlines()]
    if result.stderr or [row['async'] for row in rows] != [False, True]:
        raise ValueError(f'incomplete or unclean fixture: {mode}: {result.stderr}')
    return rows


def comparison(blocks, index, field):
    rates = [100 * (b['deferred'][index][field] / b['stock'][index][field] - 1) for b in blocks]
    # Resample complete matched blocks, preserving both arms of the pair.
    rng = random.Random(230)
    boot = sorted(statistics.median(rng.choices(rates, k=len(rates))) for _ in range(10000))
    return {'paired_median_percent': round(statistics.median(rates), 2),
            'bootstrap_95_percent_interval': [round(boot[249], 2), round(boot[9749], 2)],
            'deferred_lower_pairs': sum(rate < 0 for rate in rates), 'pairs': len(rates)}


def main():
    if sys.platform != 'darwin':
        raise SystemExit('Darwin kqueue required')
    correctness = []
    blocks = []
    with tempfile.TemporaryDirectory(prefix='handshake-reads-') as work:
        local = Path(work)
        for batched in (False, True):
            for i, arm in enumerate(ARMS):
                binary = local / 'sanitize'
                compile_arm(binary, i, batched, sanitize=True)
                for mode in ('qualify', 'qualify-split'):
                    rows = run(binary, mode)
                    correctness.append({'arm': arm, 'batched': batched, 'owner': mode,
                                        'change_calls_per_immediate_async': [row['setup_change_syscalls'] for row in rows]})
        binaries = {arm: local / arm for arm in ARMS}
        for i, arm in enumerate(ARMS):
            compile_arm(binaries[arm], i, False)
            run(binaries[arm], 'measure')
        for i in range(PAIRS):
            order = ARMS if i % 2 == 0 else tuple(reversed(ARMS))
            block = {'order': list(order)}
            for arm in order:
                rows = run(binaries[arm], 'measure')
                expected = (3, 6) if arm == 'stock' else (2, 4)
                for row, calls in zip(rows, expected):
                    if (row['flows'] != 512 or row['setup_change_syscalls'] != 512 * calls
                            or row['setup_filters'] != 512 * calls or row['setup_cpu_ns'] <= 0
                            or row['relay_cpu_ns'] < row['setup_cpu_ns']):
                        raise ValueError(f'inconsistent {arm} counters: {row}')
                block[arm] = rows
            blocks.append(block)
    files = [RELAY / 'PublishedTCP.c', RELAY / 'include/PublishedTCP.h', HERE / 'handshake_reads.c', Path(__file__).resolve()]
    print(json.dumps({
        'schema': 1, 'completed_utc': datetime.now(timezone.utc).isoformat(), 'host': platform.machine(),
        'darwin': platform.release(), 'compiler': subprocess.check_output(['clang', '--version'], text=True).splitlines()[0],
        'flags': FLAGS, 'sampled_defines': {'MICROPOD_BENCH_DEFER_HANDSHAKE_READS': {'stock': 0, 'deferred': 1},
                                           'MICROPOD_BATCH_STREAM_FILTERS': 0},
        'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
        'method': 'Two builds of the same source, one background-QoS fixture thread, one process at a time. '
                  'One unscored warmup per arm, then twelve alternating paired blocks. Each arm verifies '
                  '512 immediate and 512 asynchronous fresh flows per block, 98 request bytes and 148 reply '
                  'bytes per flow, both halves closed. Setup thread CPU includes adoption and the first '
                  'drain through the request write. Lifecycle thread CPU adds the response and closing drains. '
                  'Client/server work, socket-pair creation, and byte verification are outside the clocks.',
        'scope': 'Darwin descriptor setup, kqueue/filter submissions, buffering, and relay I/O are real. Each guest '
                 'socket call substitutes a preconnected anonymous UNIX descriptor, TCP-only options return success, '
                 'and the connect call selects immediate, EINPROGRESS or an injected error. Both arms share '
                 'these substitutions. No TCP, VMM or client latency is measured. All filters submitted during '
                 'the timed setup are counted; the syscall counts exclude readiness polls and socket operations.',
        'correctness': {'covered': ['early queued request withheld pending connect', 'immediate and async connect',
                       'server-first reply and FIN behind real backpressure', 'retry delivers early data and FIN once',
                       'revoke while pending', 'partial registration ENOMEM closes both sides',
                       'replacement flows use the same owner', 'exact request, reply and half-close order'],
                        'sanitizers': ['address', 'undefined'], 'runs': correctness},
        'summary': [{'async': bool(i), 'setup_cpu': comparison(blocks, i, 'setup_cpu_ns'),
                     'lifecycle_cpu': comparison(blocks, i, 'relay_cpu_ns')} for i in (0, 1)],
        'blocks': blocks,
    }, indent=2))


if __name__ == '__main__':
    main()
