#!/usr/bin/env python3
"""On-demand matched host-filesystem and persistent chunk-store scale qualification."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import tempfile
import time

from receipt import ROOT, Receipt, digest, require, run

MIB = 1 << 20
XATTR = 'com.micropod.qualification'
SHAPES = {'small': (32, 1), 'mixed': (512, 16), 'many-files': (4096, 16), 'large-file': (64, 256),
          'tree-50k': (50000, 16), 'gib': (64, 1024)}


def fixture(source, count, mib):
    source.mkdir()
    (source / 'ignored').mkdir()
    (source / '.syncignore').write_bytes(b'ignored\n')
    hashes = {'.syncignore': digest(source / '.syncignore')}
    total = 8
    for i in range(count):
        data = hashlib.shake_256(f'file-{i}'.encode()).digest(4096)
        name = f'pkg-{i % 16:02}/file-{i:04}'
        path = source / name
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(data)
        (source / 'ignored' / path.name).write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
        total += len(data)
    # Alternating compressible and high-entropy blocks, with an eight-MiB repeat period.
    blocks = [hashlib.shake_256(f'block-{i}'.encode()).digest(1 << 18) if i % 2 else
              bytes([i]) * (1 << 18) for i in range(32)]
    with (source / 'payload').open('wb') as out:
        for i in range(mib * 4):
            out.write(blocks[i % len(blocks)])
    hashes['payload'] = digest(source / 'payload')
    (source / 'empty').touch()
    hashes['empty'] = hashlib.sha256(b'').hexdigest()
    marker = source / 'pkg-00' / 'file-0000'
    marker.chmod(0o751)
    os.utime(marker, (1700000000, 1700000000))
    run(['/usr/bin/xattr', '-w', XATTR, 'preserved', marker])
    (source / 'link').symlink_to('pkg-00/file-0000')
    return hashes, total + mib * MIB


def verify(view, hashes):
    names = set()
    directories = set()
    for root, dirs, files in os.walk(view):
        base = Path(root).relative_to(view)
        directories.update(str(base / name) for name in dirs)
        for name in files:
            rel = str(base / name)
            names.add(rel)
            p = view / rel
            if rel == 'link':
                require(p.is_symlink() and os.readlink(p) == 'pkg-00/file-0000', 'symlink target')
            else:
                require(rel in hashes and stat.S_ISREG(p.lstat().st_mode) and digest(p) == hashes[rel],
                        f'type or content: {rel}')
    require(names == set(hashes) | {'link'}, 'path set mismatch')
    require(directories == {str(Path(name).parent) for name in hashes if '/' in name}, 'directory set mismatch')
    marker = view / 'pkg-00' / 'file-0000'
    info = marker.stat()
    require(stat.S_IMODE(info.st_mode) == 0o751 and info.st_mtime_ns == 1700000000000000000, 'mode or mtime')
    require(run(['/usr/bin/xattr', '-p', XATTR, marker]).stdout.strip() == 'preserved', 'xattr')


def compile_tools(work):
    src = ROOT / 'Sources' / 'MicropodSharedFS'
    scripts = ROOT / 'scripts'
    def build(name, modules, main):
        run(['xcrun', 'swiftc', '-O', '-module-cache-path', work / 'modules', '-o', work / name, *[src / (m + '.swift') for m in modules], main],
            timeout=180)
    build('view', ['SharedView', 'SharedFSStaging', 'ChunkHash'], scripts / 'bench_sharedfs_view.swift')
    build('chunk', ['ChunkStore', 'ChunkRepresentation', 'ChunkFileManifest', 'ChunkHash', 'SharedFSStaging'],
          Path(__file__).with_name('chunk_roundtrip.swift'))


def view_batch(tool, solution, source, dest, hashes, clients):
    outputs = [dest / f'view-{i}' for i in range(clients)]
    def create(out):
        if solution == 'rsync':
            run(['/usr/bin/rsync', '-aE', '--exclude=ignored', str(source) + '/', out], timeout=150)
            return {}
        text = run([tool, solution, source, out], timeout=150).stdout
        return {k: float(v) if k == 'elapsed_ms' else int(v) for k, v in
                (item.split('=') for item in text.split())}
    start = time.perf_counter()
    with ThreadPoolExecutor(clients) as pool:
        workers = list(pool.map(create, outputs))
    elapsed = (time.perf_counter() - start) * 1000
    for out in outputs:
        verify(out, hashes)
    return {'operation_ms': round(elapsed, 3), 'workers': workers, 'verified_views': len(outputs)}


def chunk_case(tool, encoding, source, dest, expected_hash, size):
    result = json.loads(run([tool, encoding, source, dest], timeout=150).stdout)
    require(digest(dest / 'restored') == expected_hash == result['sha256'], 'restored digest')
    require(result['logical_bytes'] == size and result['chunks'] == size // (256 << 10) and
            result['unique_chunks'] == min(32, result['chunks']), 'chunk accounting')
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--json', required=True)
    ap.add_argument('--profile', choices=['smoke', 'scale', 'extended'], default='scale')
    ap.add_argument('--rounds', type=int, default=5)
    ap.add_argument('--shapes', nargs='+', choices=SHAPES, help='override the profile fixture list')
    ap.add_argument('--serial-only', action='store_true', help='run single-client views for longer paired series')
    args = ap.parse_args()
    if args.rounds < 1:
        ap.error('rounds must be positive')
    receipt = Receipt(args.json, 'host-storage')
    device = run(['df', '-P', tempfile.gettempdir()]).stdout.splitlines()[-1].split()[0]
    filesystem = next((line.rsplit(' (', 1)[-1].split(',')[0] for line in
                       run(['/sbin/mount']).stdout.splitlines() if line.startswith(device + ' on ')), 'unknown')
    receipt.data.update(profile=args.profile, filesystem=filesystem,
                        macos=platform.mac_ver()[0], rsync=run(['/usr/bin/rsync', '--version']).stdout.splitlines()[0],
                        swift=run(['swift', '--version']).stdout.splitlines()[0],
                        cache_state='warm host page cache, new destination and new chunk store per sample',
                        shapes={}, sources={name: digest(ROOT / 'Sources' / 'MicropodSharedFS' / name) for name in
                        ['SharedView.swift', 'ChunkHash.swift', 'ChunkStore.swift', 'ChunkRepresentation.swift',
                         'SharedFSStaging.swift', 'ChunkFileManifest.swift']})
    profiles = {'smoke': ['small'], 'scale': ['small', 'mixed', 'many-files', 'large-file'],
                'extended': ['tree-50k', 'gib']}
    shapes = args.shapes or profiles[args.profile]
    solutions = ['native', 'copy', 'rsync']
    with tempfile.TemporaryDirectory(prefix='mp-storage-') as temporary:
        work = Path(temporary)
        compile_tools(work)
        for shape, (count, mib) in SHAPES.items():
            if shape not in shapes:
                continue
            source = work / shape
            hashes, total = fixture(source, count, mib)
            receipt.data['shapes'][shape] = dict(small_files=count, ignored_files=count, payload_mib=mib,
                regular_files=len(hashes), logical_bytes=total, symlinks=1,
                content_manifest_sha256=hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest())
            for clients in ([1, 4, 8] if shape == 'mixed' and not args.serial_only else [1]):
                for turn in range(args.rounds + 1):
                    shift = turn % len(solutions)
                    for solution in solutions[shift:] + solutions[:shift]:
                        with tempfile.TemporaryDirectory(dir=work) as dest:
                            receipt.record('filtered-view', lambda: view_batch(work / 'view', solution, source,
                                Path(dest), hashes, clients), solution=solution, shape=shape, clients=clients,
                                warmup=turn == 0, block=turn)
            if shape not in ('many-files', 'tree-50k'):
                for turn in range(args.rounds + 1):
                    for encoding in (['raw', 'lz4'] if turn % 2 == 0 else ['lz4', 'raw']):
                        with tempfile.TemporaryDirectory(dir=work) as dest:
                            receipt.record('chunk-roundtrip', lambda: chunk_case(work / 'chunk', encoding,
                                source / 'payload', Path(dest), hashes['payload'], mib * MIB),
                                solution=encoding, shape=shape, warmup=turn == 0, block=turn)
            shutil.rmtree(source)
    return receipt.finish()


if __name__ == '__main__':
    raise SystemExit(main())
