#!/usr/bin/env python3
"""Measure local Engine API v1.44 through an identified OrbStack Unix socket."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import socket
import struct
import tarfile
import tempfile
from urllib.parse import quote, urlencode
import uuid

from engine import compile_guest
from receipt import Receipt, require


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost', timeout=50)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def read_streams(body):
    streams = {1: bytearray(), 2: bytearray()}
    pos = 0
    while pos < len(body):
        channel, size = struct.unpack_from('>B3xI', body, pos)
        pos += 8
        require(channel in streams and pos + size <= len(body), 'malformed Docker output frame')
        streams[channel].extend(body[pos:pos + size])
        pos += size
    require(streams == {1: b'guest-out\n', 2: b'guest-err\n'}, 'unexpected stdout or stderr')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', type=Path, default=Path.home() / '.orbstack/run/docker.sock')
    parser.add_argument('--json', required=True)
    parser.add_argument('--clients', type=int, nargs='+', default=[1, 4, 8])
    parser.add_argument('--rounds', type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 50 or not all(1 <= c <= 32 for c in args.clients):
        parser.error('use 1..50 rounds and 1..32 simultaneous containers')
    rec = Receipt(args.json, 'orbstack-engine-api')
    prefix = 'mpq-api-' + uuid.uuid4().hex[:20]
    image = prefix + ':fixture'

    def request(method, resource, *, expected=(200,), data=None, binary=None):
        headers = {}
        body = None
        if binary is not None:
            headers['Content-Type'] = 'application/x-tar'
            body = binary
        elif data is not None:
            headers['Content-Type'] = 'application/json'
            body = json.dumps(data).encode()
        con = UnixHTTP(str(args.socket))
        try:
            con.request(method, '/v1.44' + resource, body, headers)
            reply = con.getresponse()
            raw = reply.read()
            if reply.status not in expected:
                raise RuntimeError(f'{method} {resource.split("?")[0]} returned {reply.status}: {raw[:450]!r}')
            return raw
        finally:
            con.close()

    def record(case, fn, **dimensions):
        row = rec.record(case, fn, **dimensions)
        print('API_SAMPLE', json.dumps({k: v for k, v in row.items() if k != 'load_start'}),
              flush=True)
        return row

    info = json.loads(request('GET', '/info'))
    version = json.loads(request('GET', '/version'))
    require('orbstack' in (info['OperatingSystem'] + info['KernelVersion']).lower(), 'unexpected engine')
    rec.data.update(server=version['Version'], kernel=info['KernelVersion'], guest_arch=version['Arch'],
                    cpu=info['NCPU'], memory=info['MemTotal'], cache='warm engine, imported rootfs')
    with tempfile.TemporaryDirectory(prefix='mpq-api-') as temp, ExitStack() as cleanup:
        binary = Path(temp) / 'probe'
        rec.data.update(compile_guest(binary, version['Arch'], os.environ))
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode='w', format=tarfile.USTAR_FORMAT) as tf:
            entry = tarfile.TarInfo('probe')
            entry.mode, entry.size = 0o755, binary.stat().st_size
            with binary.open('rb') as f:
                tf.addfile(entry, f)
        layer = archive.getvalue()
        rec.data['rootfs_sha256'] = hashlib.sha256(layer).hexdigest()
        def import_rootfs():
            params = urlencode({'fromSrc': '-', 'repo': prefix, 'tag': 'fixture'})
            payload = request('POST', '/images/create?' + params, binary=layer)
            for line in payload.splitlines():
                event = json.loads(line)
                require(not event.get('error') and not event.get('errorDetail'), 'import failed')
            found = json.loads(request('GET', '/images/' + quote(image, safe='') + '/json'))
            require(found['Architecture'] == version['Arch'], 'imported guest architecture mismatch')
            return {'image_id': found['Id']}
        cleanup.callback(lambda: record('release-image', lambda: (
            request('DELETE', '/images/' + quote(image, safe=''), expected=(200, 404)), {})[1]))
        imported = record('rootfs-import-inspect', import_rootfs)
        if imported['outcome'] != 'pass':
            return 1

        def create(name, verb, network):
            spec = {'Image': image, 'Cmd': ['/probe', verb], 'Tty': False,
                    'HostConfig': {'NetworkMode': network, 'Memory': 64 << 20, 'NanoCpus': 1000000000}}
            reply = request('POST', '/containers/create?' + urlencode({'name': name}), expected=(201,), data=spec)
            return json.loads(reply)['Id']

        def remove_container(name):
            request('DELETE', f'/containers/{name}?force=1&v=1', expected=(204, 404))

        def attach():
            name = prefix + '-service'
            net_name = prefix + '-bridge'
            try:
                net = json.loads(request('POST', '/networks/create', expected=(201,),
                                         data={'Name': net_name, 'Driver': 'bridge'}))['Id']
                ident = create(name, 'hold', 'bridge')
                request('POST', f'/containers/{ident}/start', expected=(204,))
                request('POST', f'/networks/{net}/connect', data={'Container': ident})
                state = json.loads(request('GET', f'/containers/{ident}/json'))
                require(state['NetworkSettings']['Networks'][net_name]['NetworkID'] == net, 'network membership')
            finally:
                remove_container(name)
                request('DELETE', '/networks/' + net_name, expected=(204, 404))
        record('post-create-network-connect-inspect-remove', attach)

        def one(_):
            name = prefix + '-' + uuid.uuid4().hex[:14]
            try:
                ident = create(name, 'exit23', 'none')
                target = '/containers/' + ident
                request('POST', target + '/start', expected=(204,))
                end = json.loads(request('POST', target + '/wait?condition=not-running'))
                require(end['StatusCode'] == 23 and not end.get('Error'), 'unexpected exit result')
                read_streams(request('GET', target + '/logs?stdout=1&stderr=1'))
            finally:
                remove_container(name)
        for clients in args.clients:
            for block in range(args.rounds + 1):
                def batch():
                    with ThreadPoolExecutor(max_workers=clients) as pool:
                        list(pool.map(one, range(clients)))
                    return {'known_exits': clients}
                record('api-create-start-wait-logs-remove', batch, solution='orbstack', clients=clients,
                       block=block, warmup=block == 0)
    return rec.finish()


if __name__ == '__main__':
    raise SystemExit(main())
