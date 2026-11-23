"""Compare the stock contiguous relay pump with two iovecs, using AF_UNIX only."""
import gzip
import hashlib
import json
import platform
import statistics
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
ARCHIVE = ROOT / 'docs/benchmarks/2026-11-21/gamma-published-profile.json.gz'
RELAY = ROOT / 'Sources/CPublishedTCP'
FLAGS = ['-std=gnu11', '-Wall', '-Wextra', '-Werror', '-O2']


def execute(binary, mode):
    result = subprocess.run([str(binary), mode], check=True, timeout=20, text=True,
                            stdout=subprocess.PIPE)
    return [json.loads(row) for row in result.stdout.splitlines()]


def archive_bounds(chunk_size):
    profiles = json.loads(gzip.decompress(ARCHIVE.read_bytes()))['final_profiles']
    output = {}
    for name in ('fresh', 'bulk'):
        lease = profiles[name]['lease']
        upper = lease['blocked_writes'] * chunk_size
        total = lease['upload_bytes'] + lease['download_bytes']
        output[name] = {
            'json_path': f'final_profiles.{name}.lease', 'reads': lease['reads'],
            'writes': lease['writes'], 'blocked_writes': lease['blocked_writes'],
            'transfer_bytes': total, 'max_new_pending_allocations': lease['blocked_writes'],
            'max_suffix_copy_bytes': upper, 'max_suffix_copy_pct_of_payload': round(100 * upper / total, 6),
        }
    return output


def main():
    if sys.platform != 'darwin':
        raise SystemExit('This diagnostic uses Darwin kqueue and background thread QoS.')
    arms = ('scalar', 'vectored')
    blocks = []
    qualifications = {}
    with tempfile.TemporaryDirectory(prefix='relay-iov-') as scratch:
        binaries = {arm: Path(scratch) / arm for arm in arms}
        for flag, arm in enumerate(arms):
            subprocess.run(['clang', *FLAGS, f'-DUSE_IOV={flag}', '-I', str(RELAY / 'include'),
                            str(HERE / 'vectored_pump.c'), '-o', str(binaries[arm])], check=True)
            qualifications[arm] = execute(binaries[arm], 'qualify')
            execute(binaries[arm], 'measure')
        if qualifications['scalar'] != qualifications['vectored'] or len(qualifications['scalar']) != 5:
            raise ValueError('mismatched socket fixture controls')
        for i in range(8):
            order = arms if i % 2 == 0 else tuple(reversed(arms))
            block = {'order': list(order)}
            for arm in order:
                rows = execute(binaries[arm], 'measure')
                if [row['chunk_bytes'] for row in rows] != [148, 262144]:
                    raise ValueError('incomplete fixed-work measurements')
                if any(row['thread_cpu_ns'] <= 0 for row in rows):
                    raise ValueError('missing pump thread CPU time')
                block[arm] = rows
            blocks.append(block)
    summary = []
    for i in range(2):
        sample = blocks[0]['scalar'][i]
        changes = [100 * (b['vectored'][i]['thread_cpu_ns'] / b['scalar'][i]['thread_cpu_ns'] - 1)
                   for b in blocks]
        summary.append({'chunk_bytes': sample['chunk_bytes'], 'chunks_per_sample': sample['rounds'],
                        'paired_cpu_change_percent': {'min': round(min(changes), 2),
                            'median': round(statistics.median(changes), 2), 'max': round(max(changes), 2)},
                        'faster_vectored_pairs': sum(d < 0 for d in changes)})
    sources = [Path(__file__).resolve(), HERE / 'vectored_pump.c', HERE / 'vectored_pump.h',
               HERE / 'filter_work.c', RELAY / 'PublishedTCP.c', RELAY / 'include/PublishedTCP.h', ARCHIVE]
    result = {
        'schema': 1, 'completed_utc': datetime.now(timezone.utc).isoformat(),
        'machine': platform.machine(), 'darwin_release': platform.release(),
        'compiler': subprocess.check_output(['clang', '--version'], text=True).splitlines()[0],
        'flags': FLAGS, 'source_sha256': {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                         for path in sources},
        'method': 'One background-QoS thread in one process at a time, anonymous UNIX socket pairs. '
                  'The candidate splits each contiguous read or write buffer at one third and invokes '
                  'readv/writev. One unscored warmup per arm precedes eight pairs in alternating order. '
                  'Per-call thread CPU covers the production pump with the same counters in both arms. '
                  'Seeding, dispatch, and ordered byte verification are outside the timed interval. '
                  'CPU changes apply to this local fixture only.',
        'qualification': qualifications,
        'archived_bounds': archive_bounds(qualifications['scalar'][-1]['max_chunk']),
        'bound_basis': 'Each pump call has one contiguous buffer and at most one payload syscall per '
                       'direction. Subdividing it saves zero data syscalls per successful read/write pair. '
                       'A new pending suffix is allocated only after a partial/blocked write, at most '
                       'once per event and at most 256 KiB. Retry writes advance the offset in place. '
                       'The archived bound covers suffix allocation and copying only. Connection records '
                       'and changes to buffering, read-ahead, queue layout or scheduling are outside it.',
        'summary': summary, 'blocks': blocks,
    }
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
