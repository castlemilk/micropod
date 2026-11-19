#!/usr/bin/env python3
"""Time a verified Micropod view read inside OrbStack via two storage paths."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import tempfile
import uuid

from receipt import ROOT, Receipt, require, run
from storage import SHAPES, fixture, verify

IMAGE = 'ghcr.io/containerd/busybox:1.36@sha256:907ca53d7e2947e849b839b1cd258c98fd3916c60f2e6e70c30edbf741ab6754'
CHECK = """
set -eu
cd /data
test ! -e ignored
test "$(readlink link)" = pkg-00/file-0000
test "$(find . -type f | wc -l | tr -d ' ')" = "$1"
sha256sum -c /control/sums >/dev/null
echo verified
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', required=True)
    parser.add_argument('--rounds', type=int, default=3, choices=range(1, 31))
    args = parser.parse_args()
    rec = Receipt(args.json, 'orbstack-sharedfs-consumer')
    docker = ['docker', '--context', 'orbstack']
    info = json.loads(run([*docker, 'info', '--format', '{{json .OperatingSystem}}']).stdout)
    require('orbstack' in info.lower(), 'expected the OrbStack daemon')
    rec.data.update(engine=info, cache='warm, seeded read-only data', image=IMAGE, shapes={})
    rec.record('pull-verifier', lambda: (run([*docker, 'pull', IMAGE], timeout=120), {})[1])
    if rec.data['samples'][-1]['outcome'] != 'pass':
        return rec.finish()
    image_id = json.loads(run([*docker, 'image', 'inspect', IMAGE]).stdout)[0]['Id']
    rec.data['image_id'] = image_id

    def guest(mounts, command):
        name = 'mpq-io-' + uuid.uuid4().hex
        options = []
        for mount in mounts:
            options.extend(['--mount', mount])
        try:
            return run([*docker, 'run', '--pull=never', '--rm', '--name', name, '--network=none',
                        '--cpus', '1', '--memory', '64m', *options, image_id, *command], timeout=150)
        except Exception:
            ids = run([*docker, 'ps', '-aq', '--filter', f'name=^/{name}$']).stdout.strip()
            if ids:
                run([*docker, 'rm', '-f', name])
            raise

    with tempfile.TemporaryDirectory(prefix='mp-orb-io-') as temp:
        base = Path(temp)
        folder = ROOT / 'Sources/MicropodSharedFS'
        sources = [folder / f'{name}.swift' for name in ('SharedView', 'SharedFSStaging', 'ChunkHash')]
        run(['xcrun', 'swiftc', '-O', '-target', f'{platform.machine()}-apple-macosx15.0',
             '-module-cache-path', base / 'modules', '-o', base / 'view-tool', *sources,
             ROOT / 'scripts/bench_sharedfs_view.swift'], timeout=180)
        for shape in ('mixed', 'many-files', 'large-file'):
            with tempfile.TemporaryDirectory(dir=base) as shape_dir:
                work = Path(shape_dir)
                view = work / 'view'
                control = work / 'control'
                control.mkdir()
                hashes, size = fixture(work / 'source', *SHAPES[shape])
                clone = run([base / 'view-tool', 'native', work / 'source', view], timeout=150)
                verify(view, hashes)
                sums = ''.join(f'{hashes[name]}  {name}\n' for name in sorted(hashes))
                (control / 'sums').write_text(sums)
                rec.data['shapes'][shape] = {'regular_files': len(hashes), 'logical_bytes': size,
                    'manifest_sha256': hashlib.sha256(sums.encode()).hexdigest(), 'view_build': clone.stdout.strip()}
                volume = 'mpq-io-' + uuid.uuid4().hex
                run([*docker, 'volume', 'create', volume])
                try:
                    guest([f'type=bind,src={view},dst=/src,readonly', f'type=volume,src={volume},dst=/dst'],
                          ['sh', '-ec', 'cp -a /src/. /dst/'])
                    modes = [('host-bind', f'type=bind,src={view},dst=/data,readonly'),
                             ('named-volume', f'type=volume,src={volume},dst=/data,readonly')]
                    for block in range(args.rounds + 1):
                        for mode, mount in (modes if block % 2 == 0 else reversed(modes)):
                            def check():
                                reply = guest([mount, f'type=bind,src={control},dst=/control,readonly'],
                                              ['sh', '-c', CHECK, 'verify', str(len(hashes))])
                                require(reply.stdout.strip() == 'verified', 'missing verified result')
                                return {'verified_regular_files': len(hashes)}
                            rec.record('launch-scan-hash-remove', check, solution=mode, shape=shape,
                                       block=block, warmup=block == 0)
                finally:
                    run([*docker, 'volume', 'rm', volume])
    return rec.finish()


if __name__ == '__main__':
    raise SystemExit(main())
