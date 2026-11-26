"""Longer matched confirmation of the deferred handshakes' whole-flow CPU cost."""
import hashlib
import json
import platform
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from check_handshake_reads import ARMS, HERE, RELAY, ROOT, comparison, compile_arm, run


def main():
    if sys.platform != 'darwin':
        raise SystemExit('Darwin kqueue required')
    # Each arm has the same number of early, late, and consecutive positions per block.
    sequence = ('stock', 'deferred', 'deferred', 'stock', 'deferred', 'stock', 'stock', 'deferred')
    blocks = []
    with tempfile.TemporaryDirectory(prefix='confirm-handshake-') as directory:
        binaries = {arm: Path(directory) / arm for arm in ARMS}
        for i, arm in enumerate(ARMS):
            compile_arm(binaries[arm], i, False)
            run(binaries[arm], 'measure')
        for i in range(16):
            order = sequence if not i % 2 else tuple(reversed(sequence))
            block = {'order': list(order), 'samples': []}
            for arm in ARMS:
                block[arm] = [dict(setup_cpu_ns=0, relay_cpu_ns=0) for _ in range(2)]
            for arm in order:
                rows = run(binaries[arm], 'measure')
                expected = (3, 6) if arm == 'stock' else (2, 4)
                for j, row in enumerate(rows):
                    if row['flows'] != 512 or row['setup_change_syscalls'] != row['flows'] * expected[j]:
                        raise ValueError('incomplete or unmatched confirmation work')
                    for metric in ('setup_cpu_ns', 'relay_cpu_ns'):
                        block[arm][j][metric] += row[metric]
                block['samples'].append([[r['setup_cpu_ns'], r['relay_cpu_ns']] for r in rows])
            blocks.append(block)
    files = [Path(__file__).resolve(), HERE / 'check_handshake_reads.py', HERE / 'handshake_reads.c',
             RELAY / 'PublishedTCP.c', RELAY / 'include/PublishedTCP.h']
    print(json.dumps({
        'schema': 1, 'completed_utc': datetime.now(timezone.utc).isoformat(), 'darwin': platform.release(),
        'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
        'method': 'Independent fixed-size follow-up to relay-handshake-reads-offline.json. Same sources, compiler '
                  'flags, single background thread, warmups, traffic and clocks. Sixteen matched blocks, 4 invocations '
                  'per arm per block. Each invocation does 512 immediate and 512 async connections. Each sample in '
                  'order contains [setup_cpu_ns, relay_cpu_ns] for immediate then async. Confidence intervals resample '
                  'whole blocks. The primary follow-up endpoint is asynchronous whole-flow relay CPU. This measures '
                  'a synthetic connect result on real AF_UNIX streams, never live TCP or client latency.',
        'primary_async_lifecycle_cpu': comparison(blocks, 1, 'relay_cpu_ns'),
        'async_setup_cpu': comparison(blocks, 1, 'setup_cpu_ns'),
        'immediate_lifecycle_cpu': comparison(blocks, 0, 'relay_cpu_ns'),
        'immediate_setup_cpu': comparison(blocks, 0, 'setup_cpu_ns'), 'blocks': blocks,
    }, indent=2))


if __name__ == '__main__':
    main()
