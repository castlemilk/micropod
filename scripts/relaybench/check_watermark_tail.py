"""Replay the archived adaptive-read prototype at 128 KiB using anonymous Darwin socket pairs."""
import gzip
import hashlib
import json
import platform
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ARCHIVE = ROOT / 'docs/benchmarks/2026-11-21/gamma-mixed-scheduler.json.gz'
ARCHIVE_SHA = '9e3b184de862aafacff47312878441e940d030e8cfc8342c0e479d064f4724c8'
HEADER_COMMIT = '816121afd30fba52bda7828418cd963d4216166b'
HEADER_PATH = 'Sources/CPublishedTCP/include/PublishedTCP.h'


def main():
    if sys.platform != 'darwin':
        raise SystemExit('This local kqueue fixture requires Darwin.')
    archive_bytes = ARCHIVE.read_bytes()
    if hashlib.sha256(archive_bytes).hexdigest() != ARCHIVE_SHA:
        raise ValueError('scheduler archive digest differs')
    receipt = json.loads(gzip.decompress(archive_bytes))
    source = receipt['records']['fixtures/lowat.c'].encode()
    header = subprocess.check_output(['git', 'show', f'{HEADER_COMMIT}:{HEADER_PATH}'], cwd=ROOT)
    header_sha = hashlib.sha256(header).hexdigest()
    if header_sha != receipt['source_sha256'][HEADER_PATH]:
        raise ValueError('prototype header digest differs from the archive')
    samples = []
    flags = ['-std=gnu11', '-O2', '-Wall', '-Wextra', '-Werror', '-DMP_LOW=131072']
    with tempfile.TemporaryDirectory(prefix='relay-lowat-') as name:
        scratch = Path(name)
        (scratch / 'archive_lowat.c').write_bytes(source)
        (scratch / 'PublishedTCP.h').write_bytes(header)
        binary = scratch / 'fixture'
        subprocess.run(['clang', *flags, '-I', name, '-I', str(HERE), str(HERE / 'watermark_tail.c'),
                        '-o', str(binary)], check=True)
        for _ in range(6):
            raw = subprocess.check_output([str(binary)], text=True, timeout=5)
            rows = [json.loads(line) for line in raw.splitlines()]
            if [row['fin'] for row in rows] != [False, True]:
                raise RuntimeError('missing open or half-closed fixture')
            samples.append(rows)
    sources = (Path(__file__).resolve(), HERE / 'watermark_tail.c', HERE / 'filter_work.c')
    print(json.dumps({
        'schema': 1, 'observed_utc': datetime.now(timezone.utc).isoformat(), 'darwin': platform.release(),
        'arch': platform.machine(), 'compiler': subprocess.check_output(['clang', '--version'], text=True).splitlines()[0],
        'flags': flags, 'archive': str(ARCHIVE.relative_to(ROOT)), 'archive_sha256': ARCHIVE_SHA,
        'prototype_path': 'records["fixtures/lowat.c"]', 'prototype_sha256': hashlib.sha256(source).hexdigest(),
        'header_commit': HEADER_COMMIT, 'header_sha256': header_sha,
        'fixture_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
        'scope': 'Archived dedicated-owner prototype on a single background-QoS thread; anonymous local sockets. '
                 'No TCP, VM, libdispatch, throughput or mixed-arrival latency measurement.',
        'method': 'The first byte and all subsequent chunks used real read readiness. Exactly 256 KiB promoted '
                  'only the tested direction. On an open connection, a 17-byte trailer produced no read event '
                  'before the timer; after demotion it was readable and the connection remained open. With FIN, '
                  'the high watermark remained active, including if a timer event was already pending. The first '
                  'EV_EOF carried 17 unread bytes, the next carried zero, and the peer received the bytes before '
                  'its EOF. The reverse marker succeeded in each case. The open-row wait times measure time '
                  'spent waiting in the fixture for the configured 2 ms timer; dispatch time depends on scheduling.',
        'samples': samples,
    }, indent=2))


if __name__ == '__main__':
    main()
