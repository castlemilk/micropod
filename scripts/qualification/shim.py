#!/usr/bin/env python3
"""Negotiate the production Docker shim and record two known gaps without needing a guest VM."""
import argparse
from http.client import HTTPConnection
import json
import os
from pathlib import Path
import shutil
import socket
import tempfile

from daemon import daemon
from receipt import ROOT, Receipt, require, run


def probe(binaries, work):
    endpoint = str(work / 'shim.sock')
    env = {**os.environ, 'MICROPOD_SHIM_SOCKET': endpoint, 'MICROPOD_SHIM_TCP_PORT': '0',
           'MICROPOD_SHIM_BRIDGE': '127.0.0.1', 'MICROPOD_SHIM_STATE': str(work / 'state.json'),
           'MICROPOD_SHAREDFS_SOCKET': str(work / 'no-share.sock')}
    def request(method, path, body=None):
        con = HTTPConnection('localhost', timeout=5)
        try:
            con.sock = socket.socket(socket.AF_UNIX)
            con.sock.settimeout(5)
            con.sock.connect(endpoint)
            con.request(method, path, body=body)
            response = con.getresponse()
            return response.status, response.headers, response.read()
        finally:
            con.close()
    with daemon(binaries / 'micropod-docker-shim', env, work, 'MICROPOD_SHIM_SOCKET'):
        status, _, raw = request('GET', '/version')
        version = json.loads(raw)
        require(status == 200 and version['GitCommit'] == 'micropod-shim', 'wrong daemon identity')
        api = version['ApiVersion']
        for method in ['HEAD', 'GET']:
            status, headers, body = request(method, '/_ping')
            require(status == 200 and headers['API-Version'] == api and headers['OSType'] == 'linux', 'ping negotiation')
            require(headers['Content-Length'] == '3' and body.strip() == (b'OK' if method == 'GET' else b''),
                    'HEAD/GET representation length or body')
        require(request('GET', f'/v{api}/_ping')[0] == 200, 'negotiated API prefix')
        result = {'api': api, 'minimum_api': version['MinAPIVersion'], 'docker_client': None,
                  'image_import_probe_http': request('POST', '/images/create?fromSrc=-', b'')[0],
                  'network_connect_probe_http': request('POST', '/networks/missing/connect', b'{"Container":"missing"}')[0]}
        if shutil.which('docker'):
            for variable in ('DOCKER_API_VERSION', 'DOCKER_CONTEXT', 'DOCKER_HOST'):
                env.pop(variable, None)
            actual = run(['docker', '--host', 'unix://' + endpoint, 'version', '--format', '{{.Server.APIVersion}}'],
                         env=env, timeout=10).stdout.strip()
            require(actual == api, 'Docker client version handshake')
            result['docker_client'] = run(['docker', '--version']).stdout.strip()
        print('Micropod shim observations:', json.dumps(result, sort_keys=True))
        return result


if __name__ == '__main__':
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument('--json', required=True)
    args.add_argument('--bin', type=Path, default=ROOT / '.build' / 'debug')
    config = args.parse_args()
    receipt = Receipt(config.json, 'production-docker-shim')
    with tempfile.TemporaryDirectory(prefix='mps-', dir='/tmp') as temp:
        receipt.record('docker-api-negotiation', lambda: probe(config.bin.resolve(), Path(temp)))
    raise SystemExit(receipt.finish())
