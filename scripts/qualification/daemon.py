#!/usr/bin/env python3
"""Exercise the built CLI and standalone daemon over a private Unix socket on macOS."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

from receipt import ROOT, Receipt, digest, require, run


def until(check, description):
    limit = time.monotonic() + 8
    while not check():
        if time.monotonic() >= limit:
            raise TimeoutError(description)
        time.sleep(.025)


@contextmanager
def daemon(binary, env, work, socket_key='MICROPOD_SHAREDFS_SOCKET'):
    with (work / 'daemon.log').open('a') as log:
        p = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        try:
            def ready():
                if p.poll() is not None:
                    raise RuntimeError(f'daemon exited {p.returncode}')
                with socket.socket(socket.AF_UNIX) as sock:
                    sock.settimeout(.25)
                    return sock.connect_ex(env[socket_key]) == 0
            until(ready, 'daemon did not bind its private socket')
            yield
        finally:
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait(timeout=3)


def qualify(binaries, work):
    source = work / 'source'
    source.mkdir()
    env = {**os.environ, 'MICROPOD_SHAREDFS_SOCKET': str(work / 'socket'),
           'MICROPOD_SHAREDFS_CACHE': str(work / 'cache')}
    def cli(*args):
        return run([binaries / 'micropod', 'share', *args], env=env, timeout=12).stdout.strip()
    def mount(*flags):
        result = cli('mount', source, *flags).split()[0]
        info = dict(line.split(': ', 1) for line in cli('inspect', result).splitlines())
        require(info['id'] == result and info['readonly'] == str('--ro' in flags).lower(), 'mount inspect mode')
        return result, Path(info['view'])
    def visible(path, data):
        try:
            return path.read_bytes() == data
        except FileNotFoundError:
            return False

    (source / '.syncignore').write_text('ignored\n')
    (source / 'ignored').mkdir()
    (source / 'ignored' / 'private').write_text('filtered')
    (source / 'seed').write_text('seed')
    (source / 'link').symlink_to('seed')
    start = time.perf_counter()
    with daemon(binaries / 'micropod-sharedfs', env, work):
        ro_id, ro = mount('--shared', '--ro')
        ordinary_id, ordinary = mount('--ro')
        writable_id, writable = mount('--shared')
        require(ro != writable and ordinary != ro, 'mount access modes need separate backing views')
        with ThreadPoolExecutor(4) as pool:
            shared = list(pool.map(lambda _: mount('--shared'), range(4)))
        require(all(pair == (writable_id, writable) for pair in shared), 'concurrent shared identity')
        require(set(line.split()[0] for line in cli('list').splitlines()) == {ro_id, ordinary_id, writable_id},
                'mount list')
        for view in (ro, ordinary, writable):
            require((view / 'link').is_symlink() and (view / 'link').read_text() == 'seed'
                    and not (view / 'ignored').exists(), 'mount contents')
        (ro / 'ro-local').write_text('private')
        (ordinary / 'ordinary-local').write_text('private')
        cli('sync', ro_id)
        cli('sync', ordinary_id)
        (source / 'live').write_bytes(b'host')
        t = time.perf_counter()
        until(lambda: all(visible(v / 'live', b'host') for v in (ro, ordinary, writable)), 'host -> all views')
        live_ms = (time.perf_counter() - t) * 1000
        (writable / 'out').write_bytes(b'view')
        until(lambda: all(visible(v / 'out', b'view') for v in (source, ro, ordinary)), 'view -> host -> siblings')
        (writable / 'out').unlink()
        until(lambda: all(not (v / 'out').exists() for v in (source, ro, ordinary)), 'view deletion -> siblings')
        require(not (source / 'ro-local').exists() and not (source / 'ordinary-local').exists(), 'read-only writeback')
        (writable / 'manual').write_bytes(b'manual')
        cli('sync', writable_id)
        require(visible(source / 'manual', b'manual'), 'explicit sync')
        require('0 chunks' in cli('gc'), 'active mount GC')
        for _ in shared:
            cli('unmount', writable_id)
            require(writable.exists(), 'early unmount removed a shared view')
        cli('unmount', writable_id)
        require(not writable.exists(), 'final unmount left shared view')
        cli('unmount', ordinary_id)
        retained = ro
    with daemon(binaries / 'micropod-sharedfs', env, work):
        replacement_id, replacement = mount('--shared', '--ro')
        require(replacement != retained and visible(retained / 'ro-local', b'private'), 'restart lost earlier view')
        cli('unmount', replacement_id)
        require(cli('list') == 'no shared views' and '0 chunks' in cli('gc') and retained.exists(),
                'restart inventory or retained-view GC')
    return {'host_to_views_ms': round(live_ms, 3), 'total_ms': round(1000 * (time.perf_counter() - start), 3)}


def client_scale(receipt, binaries, work, rounds):
    env = {**os.environ, 'MICROPOD_SHAREDFS_SOCKET': str(work / 'scale.sock'),
           'MICROPOD_SHAREDFS_CACHE': str(work / 'scale-cache')}
    def cli(*args):
        return run([binaries / 'micropod', 'share', *args], env=env, timeout=20).stdout.strip()
    with daemon(binaries / 'micropod-sharedfs', env, work):
        for count in (32, 512):
            source = work / f'files-{count}'
            source.mkdir()
            (source / '.syncignore').write_text('ignored\n')
            (source / 'ignored').write_text('excluded')
            expected = {'.syncignore': digest(source / '.syncignore')}
            for i in range(count):
                data = hashlib.shake_256(str(i).encode()).digest(4096)
                (source / str(i)).write_bytes(data)
                expected[str(i)] = hashlib.sha256(data).hexdigest()
            for block in range(rounds + 1):
                levels = [1, 4, 8]
                for clients in levels[block % 3:] + levels[:block % 3]:
                    def batch():
                        with ThreadPoolExecutor(clients) as workers:
                            ids = list(workers.map(lambda _: cli('mount', source, '--shared').split()[0], range(clients)))
                        ready = time.perf_counter()
                        require(len(set(ids)) == 1, 'clients received different shared views')
                        info = dict(line.split(': ', 1) for line in cli('inspect', ids[0]).splitlines())
                        view = Path(info['view'])
                        require({f.name: digest(f) for f in view.iterdir()} == expected, 'mounted contents differ')
                        mounted = time.perf_counter()
                        with ThreadPoolExecutor(clients) as workers:
                            list(workers.map(lambda id_: cli('unmount', id_), ids))
                        require(not view.exists() and cli('list') == 'no shared views', 'leaked share or early release')
                        return {'ack_ms': round((ready - start) * 1000, 3),
                                'mount_verified_ms': round((mounted - start) * 1000, 3), 'clients_verified': clients}
                    start = time.perf_counter()
                    row = receipt.record('cli-share-batch', batch, shape=f'{count}-files', clients=clients,
                                         block=block, warmup=block == 0)
                    if row['outcome'] != 'pass':
                        return  # subsequent samples would inherit a failed mount


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--bin', type=Path, default=ROOT / '.build' / 'debug')
    ap.add_argument('--json', required=True)
    ap.add_argument('--scale-rounds', type=int, default=0, help='also measure 1/4/8 concurrent CLI clients')
    args = ap.parse_args()
    receipt = Receipt(args.json, 'standalone-daemon')
    # Short, private path for the Unix sockaddr on both CI and developer Macs.
    with tempfile.TemporaryDirectory(prefix='mpq-', dir='/tmp') as temporary:
        work = Path(temporary)
        row = receipt.record('mount-live-sync-refcount-restart-gc', lambda: qualify(args.bin.resolve(), work))
        if row['outcome'] == 'fail' and (work / 'daemon.log').exists():
            row['daemon_tail'] = (work / 'daemon.log').read_text()[-2000:].replace(temporary, '<fixture>')
            print(row['daemon_tail'])
        if args.scale_rounds > 0 and row['outcome'] == 'pass':
            client_scale(receipt, args.bin.resolve(), work, args.scale_rounds)
    return receipt.finish()


if __name__ == '__main__':
    raise SystemExit(main())
