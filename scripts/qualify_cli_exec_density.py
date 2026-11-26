#!/usr/bin/env python3
"""Measure piped CLI exec on eight simultaneously attached CI containers per engine."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import statistics
import subprocess
import tempfile
import time
import uuid


def checked(argv, env, timeout=30):
    return subprocess.run(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, check=True).stdout


def clock_ms(start):
    return round((time.monotonic_ns() - start) / 1e6, 3)


def hash_stream(argv, env):
    # Independent size and byte check for the 32 MiB stdout-only measurement.
    digest = hashlib.sha256()
    total = 0
    with tempfile.TemporaryFile() as output:
        subprocess.run(argv + ['sh', '-c', 'dd if=/dev/zero bs=65536 count=512 2>/dev/null'],
                       stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.PIPE, env=env, check=True, timeout=30)
        output.seek(0)
        for block in iter(lambda: output.read(262144), b''):
            total += len(block)
            digest.update(block)
    zero = hashlib.sha256()
    for _ in range(512):
        zero.update(bytes(65536))
    if total != 32 * 1048576 or digest.digest() != zero.digest():
        raise RuntimeError(f'32 MiB stdout check returned {total} bytes, SHA-256 {digest.hexdigest()}')
    return {'bytes': total, 'sha256': digest.hexdigest()}


def wave(prefixes, env, payloads):
    command = ['sh', '-c', 'printf "ready\\n" >&2; cat; printf "%s\\n" "$1" >&2; exit "$2"']
    start = time.monotonic_ns()
    processes = []
    try:
        with selectors.DefaultSelector() as poll:
            pending = {}
            for i, prefix in enumerate(prefixes):
                p = subprocess.Popen(prefix + command + ['sh', f'job-{i}', str(10 + i)], env=env,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
                processes.append(p)
                pending[i] = bytearray()
                poll.register(p.stderr, selectors.EVENT_READ, i)
            deadline = time.monotonic() + 20
            while pending:
                ready = poll.select(max(0, deadline-time.monotonic()))
                if not ready:
                    raise RuntimeError(f'Execs still waiting for readiness: {list(pending)}')
                for key, _ in ready:
                    buf = pending[key.data]
                    part = os.read(key.fd, 6-len(buf))
                    if not part:
                        raise RuntimeError(f'Exec {key.data} ended before its readiness marker: {bytes(buf)!r}')
                    buf.extend(part)
                    if not b'ready\n'.startswith(buf):
                        raise RuntimeError(f'Exec {key.data} failed before readiness: {bytes(buf)!r}')
                    if len(buf) == 6:
                        poll.unregister(key.fileobj)
                        del pending[key.data]
        ready_ms = clock_ms(start)

        def transfer(i):
            out, err = processes[i].communicate(payloads[i], timeout=25)
            if (processes[i].returncode, out, err) != (10+i, payloads[i], f'job-{i}\n'.encode()):
                raise RuntimeError(f'Exec {i} returned {processes[i].returncode}, {len(out)} stdout bytes, stderr {err[:200]!r}')

        with ThreadPoolExecutor(len(processes)) as pool:
            list(pool.map(transfer, range(len(processes))))
        return {'ms': clock_ms(start), 'all_ready_ms': ready_ms, 'jobs': len(processes),
                'bytes_each_direction': sum(map(len, payloads))}
    finally:
        for proc in processes:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                stream.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', required=True, type=Path)
    parser.add_argument('--hvf-root', required=True, type=Path)
    parser.add_argument('--orbstack-host', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--image', default='alpine:3.23')
    args = parser.parse_args()
    cli = str(args.cli.resolve(strict=True))
    docker = shutil.which('docker')
    root = args.hvf_root.resolve(strict=True)
    socket = root / 'run/docker.sock'
    if not socket.is_socket() or not args.orbstack_host.startswith('unix:///'):
        parser.error('Both engines must have explicit running Unix endpoints')
    if socket.samefile(args.orbstack_host.removeprefix('unix://')):
        parser.error('The two Docker endpoints must be distinct')
    if args.output.exists():
        parser.error('The output path already exists')

    batch = uuid.uuid4().hex[:16]
    label = f'micropod.qa.exec-density={batch}'
    image = args.image
    # A distinct predictable payload per job catches cross-stream or cross-job mixing.
    payloads = [bytes((byte+i) % 256 for byte in range(256)) * 8192 for i in range(8)]
    with open(cli, 'rb') as executable:
        cli_digest = hashlib.file_digest(executable, 'sha256').hexdigest()
    result = {'schema': 1, 'run': batch, 'label': label, 'image': image, 'jobs': len(payloads),
              'bytes_per_job_each_direction': len(payloads[0]), 'endpoints': {}, 'warmup': {}, 'rounds': [],
              'integrity_32_mib': {}, 'cleanup': {}, 'cli_sha256': cli_digest}
    with tempfile.TemporaryDirectory(prefix='mp-cli-density-') as temp:
        scope = Path(temp)
        common = dict(os.environ, HOME=temp, CFFIXED_USER_HOME=temp, DOCKER_CONFIG=temp,
                      MICROPOD_NO_UPDATE_NOTIFIER='1', MICROPOD_RUNTIME='cli',
                      MICROPOD_CONTAINER_CLI_PATH=str(scope/'unused-apple'))
        for var in ('DOCKER_CONTEXT', 'DOCKER_API_VERSION'):
            common.pop(var, None)
        envs = {}
        cells = {}
        try:
            for backend, host, runtime in [('hvf', 'unix://'+str(socket), 'hvf'), ('orb', args.orbstack_host, 'docker')]:
                env = dict(common, DOCKER_HOST=host, MICROPOD_DEFAULT_RUNTIME=runtime,
                           MICROPOD_HVF_ROOT=str(root if backend=='hvf' else scope/'unused-hvf'),
                           MICROPOD_RUNTIMES_CONFIG=str(scope/(backend+'.json')))
                if checked([docker, 'ps', '-aq', '--filter', 'label='+label], env).strip():
                    raise RuntimeError('New run label already has containers')
                envs[backend] = env
                names = []
                begin = time.monotonic_ns()
                for i in range(len(payloads)):
                    name = f'mp-stream-{batch}-{i}'
                    checked([docker,'run','--detach','--pull=never','--name',name,'--label',label,
                             '--cpus','1','--memory','128m',image,'sleep','600'], env)
                    names.append(name)
                control = [docker, 'exec', names[0]]
                busybox = checked(control+['sha256sum','/bin/busybox','/etc/alpine-release'],env).decode()
                result['endpoints'][backend] = {'host':host, 'names':names, 'provision_ms':clock_ms(begin),
                                                'busybox_and_release':busybox,
                                                'server':checked([docker, 'version','--format','{{json .Server}}'],env).decode().strip()}
                for client, binary in [('micropod',cli),('docker',docker)]:
                    key = backend+'-'+client
                    suffix = ['--'] if client=='micropod' else []
                    cells[key] = ([[binary,'exec','-i',name]+suffix for name in names],env)
                    result['integrity_32_mib'][key] = hash_stream([binary, 'exec',names[0]]+suffix,env)
            if result['endpoints']['hvf']['busybox_and_release'] != result['endpoints']['orb']['busybox_and_release']:
                raise RuntimeError('Alpine userspace differs across engines')
            order = ['hvf-micropod','orb-micropod','hvf-docker','orb-docker']
            for key in order:
                result['warmup'][key] = wave(*cells[key], payloads)
            for indices in [(0,1,3,2), (1,2,0,3), (2,3,1,0), (3,0,2,1)]:
                row = {}
                for i in indices:
                    key = order[i]
                    row[key] = wave(*cells[key], payloads)
                result['rounds'].append(row)
            result['median_ms'] = {key: statistics.median(row[key]['ms'] for row in result['rounds']) for key in order}
        finally:
            for backend, env in envs.items():
                try:
                    query = [docker, 'ps', '-aq', '--filter', 'label='+label]
                    ids = checked(query, env).decode().split()
                    if ids:
                        checked([docker, 'rm', '-f', *ids], env, timeout=45)
                    remaining = checked(query, env).decode().split()
                    result['cleanup'][backend] = {'removed':len(ids), 'remaining':remaining}
                except (OSError, subprocess.SubprocessError) as error:
                    result['cleanup'][backend] = {'error':str(error)}
            args.output.write_text(json.dumps(result,indent=2)+'\n')
    if any('error' in row or row['remaining'] for row in result['cleanup'].values()):
        raise RuntimeError(f'Container cleanup incomplete: {result["cleanup"]}')


if __name__ == '__main__':
    main()
