#!/usr/bin/env python3
"""Offline Docker client workflows against one explicitly selected engine."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
import tempfile
import time
import uuid

from receipt import Receipt, digest, require, run

DOCKERFILE = """FROM scratch AS process
COPY probe /probe
COPY input /input
RUN ["/probe", "copy", "/input", "/result"]
FROM scratch AS artifact
COPY --from=process /result /result
FROM artifact AS runnable
COPY probe /probe
ENTRYPOINT ["/probe"]
"""

# The engine/VM can already be warm. --no-cache affects solver steps only.
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    endpoint = ap.add_mutually_exclusive_group(required=True)
    endpoint.add_argument('--context')
    endpoint.add_argument('--host')
    ap.add_argument('--json', required=True)
    ap.add_argument('--rounds', type=int, default=1)
    ap.add_argument('--clients', type=int, nargs='+', default=[1, 4])
    ap.add_argument('--oci', action='store_true', help='also run the Linux reference OCI lifecycle with sudo -n runc')
    args = ap.parse_args()
    if not 1 <= args.rounds <= 200 or not all(1 <= n <= 64 for n in args.clients):
        ap.error('use 1..200 rounds and 1..64 clients')
    env = {k: v for k, v in os.environ.items() if k not in
           {'DOCKER_CONTEXT', 'DOCKER_HOST', 'BUILDX_BUILDER', 'BUILDKIT_HOST', 'DOCKER_DEFAULT_PLATFORM'}}
    selector = ['--context', args.context] if args.context else ['--host', args.host]
    # Pin Buildx to the engine's context; a named/remote ambient builder is a different contender.
    builder = args.context or 'default'
    def docker(*cmd, expected=0, timeout=60):
        return run(['docker', *selector, *cmd], env=env, expected=expected, timeout=timeout)
    rec = Receipt(args.json, 'engine-workflows')
    rec.data['selector'] = args.context or args.host.replace(str(Path.home()), '~')
    version = rec.record('engine-identity', lambda: {
        'version': json.loads(docker('version', '--format', '{{json .}}', timeout=10).stdout),
        'engine': json.loads(docker('info', '--format',
            '{"os":{{json .OperatingSystem}},"arch":{{json .Architecture}},"kernel":{{json .KernelVersion}},'
            '"storage":{{json .Driver}},"cpus":{{json .NCPU}},"memory":{{json .MemTotal}}}', timeout=10).stdout)})
    if version['outcome'] != 'pass':
        return rec.finish()
    arch = version['version']['Server']['Arch']
    require(arch in ('arm64', 'amd64'), f'unsupported native architecture {arch}')
    rec.data.update(guest_arch=arch, guest_source_sha256=digest(Path(__file__).with_name('guest.go')),
                    go=run(['go', 'version']).stdout.strip(), cache_state='warm engine, locally imported rootfs')
    prefix = 'mpq-' + uuid.uuid4().hex[:18]
    # Ruby/Go/Compose and other project tools are never pulled for this fixture.
    with tempfile.TemporaryDirectory(prefix='mp-engine-') as tmp, ExitStack() as cleanup:
        work = Path(tmp)
        ctx = work / 'context'
        ctx.mkdir()
        probe = ctx / 'probe'
        rec.record('guest-compile', lambda: compile_guest(probe, arch, env))
        if not probe.exists():
            return rec.finish()
        rec.data['guest_sha256'] = digest(probe)
        tag, built = prefix + ':import', prefix + ':build'
        def remove(*cmd):
            rec.record('cleanup-' + '-'.join(cmd[:2]), lambda: (docker(*cmd), {})[1])
        # Keep the runtime cases independent of solver and exporter support.
        with tarfile.open(work / 'rootfs.tar', 'w', format=tarfile.USTAR_FORMAT) as archive:
            info = tarfile.TarInfo('probe')
            info.size, info.mode = probe.stat().st_size, 0o755
            with probe.open('rb') as f:
                archive.addfile(info, f)
        rec.data['rootfs_tar_sha256'] = digest(work / 'rootfs.tar')
        def load():
            image = docker('image', 'import', '--change', 'ENTRYPOINT ["/probe"]', work / 'rootfs.tar', tag)
            cleanup.callback(remove, 'image', 'rm', tag)
            require(docker('image', 'inspect', '--format', '{{.Id}}', tag).stdout.strip() == image.stdout.strip(),
                    'imported image identity')
            return {'image_id': image.stdout.strip()}
        imported = rec.record('rootfs-import-inspect', load)
        # On a timeout, reconcile only this run's UUID-named objects.
        def owned_run(image, *command, flags=(), expected=0):
            name = prefix + '-' + uuid.uuid4().hex[:12]
            try:
                return docker('run', '--name', name, '--rm', '--pull=never', *flags, image, *command, expected=expected)
            except Exception:
                cleanup_if_exists('container', name)
                raise
        def cleanup_if_exists(kind, name):
            try:
                docker(kind, 'inspect', name, timeout=8)
            except RuntimeError as e:
                if 'no such' in str(e).lower() or 'not found' in str(e).lower():
                    return
                raise
            if kind == 'container':
                docker(kind, 'rm', '-f', name)
            else:
                docker(kind, 'rm', name)
        def check_builds():
            ident = docker('buildx', 'inspect', builder, timeout=20).stdout
            require('Driver:' in ident, 'Buildx builder identity missing')
            rec.data['builder'] = {'client': docker('buildx', 'version').stdout.strip(),
                                   'details': [l.strip() for l in ident.splitlines() if l.strip().startswith(
                                       ('Name:', 'Driver:', 'Endpoint:', 'BuildKit version:', 'Status:'))]}
            (ctx / 'Dockerfile').write_text(DOCKERFILE)
            (ctx / '.dockerignore').write_text('ignored\n')
            (ctx / 'ignored').write_bytes(b'never in output')
            for phase, value in [('solver-no-cache', 'alpha'), ('warm', 'alpha'), ('edited', 'bravo')]:
                (ctx / 'input').write_text(value)
                def build():
                    opts = ['--no-cache'] if phase == 'solver-no-cache' else []
                    proc = docker('buildx', 'build', '--builder', builder, '--platform', 'linux/' + arch,
                                  '--progress=plain', '--network=none', '--load', '-t', built, *opts, ctx, timeout=120)
                    lines = (proc.stdout + proc.stderr).splitlines()
                    ids = {l.split()[0] for l in lines if l.startswith('#') and ' RUN ' in l and '/probe' in l}
                    require(len(ids) == 1, 'missing RUN vertex')
                    cached = any(l.strip() == next(iter(ids)) + ' CACHED' for l in lines)
                    require(cached == (phase == 'warm'), f'wrong solver cache outcome: {cached}')
                    require(owned_run(built, 'read', '/result').stdout == value, 'loaded image output')
                    return {'run_vertex_cached': cached, 'output_sha256': hashlib.sha256(value.encode()).hexdigest()}
                rec.record('build-to-validated-output', build, solution=phase)
            def export():
                dest = work / 'exported'
                docker('buildx', 'build', '--builder', builder, '--platform', 'linux/' + arch, '--network=none',
                       '--target', 'artifact', '--output', f'type=local,dest={dest}', ctx, timeout=120)
                require({p.name for p in dest.iterdir()} == {'result'} and (dest / 'result').read_bytes() == b'bravo',
                        'multi-stage local export contents')
            rec.record('buildx-local-export', export)
        cleanup.callback(lambda: rec.record('cleanup-build-image', lambda: cleanup_if_exists('image', built)))
        rec.record('buildx-workflow', check_builds)
        if imported['outcome'] == 'pass':
            def identity():
                p = owned_run(tag, 'identity', flags=['--user', '123:456', '--hostname', 'qualify', '--network', 'none',
                                                     '--workdir', '/work', '--env', 'QUALIFY=ok'])
                require(p.stdout.strip() == '123:456|/work|ok|qualify', 'identity, cwd, argv, hostname or env')
            rec.record('process-identity', identity)
            def mounts():
                (work / 'bind').mkdir()
                (work / 'bind' / 'file').write_text('host')
                flags = ['--mount', f'type=bind,src={work}/bind,dst=/mnt,readonly']
                require(owned_run(tag, 'read', '/mnt/file', flags=flags).stdout == 'host', 'read-only bind input')
                owned_run(tag, 'readonly', '/mnt/file', flags=flags)
                require((work / 'bind' / 'file').read_text() == 'host', 'read-only bind content changed')
                volume = prefix + '-volume'
                cleanup.callback(lambda: rec.record('cleanup-volume', lambda: cleanup_if_exists('volume', volume)))
                docker('volume', 'create', volume)
                flags = ['--mount', f'type=volume,src={volume},dst=/mnt']
                owned_run(tag, 'write', '/mnt/out', 'persist', flags=flags)
                require(owned_run(tag, 'read', '/mnt/out', flags=flags).stdout == 'persist', 'named volume persistence')
            rec.record('readonly-bind-and-volume-reuse', mounts)
            def lifecycle():
                name, network = prefix + '-service', prefix + '-network'
                cleanup.callback(lambda: rec.record('cleanup-network', lambda: cleanup_if_exists('network', network)))
                docker('network', 'create', network)
                cleanup.callback(lambda: rec.record('cleanup-service', lambda: cleanup_if_exists('container', name)))
                docker('create', '--name', name, '--network', network, '--network-alias', 'qualify-svc', tag, 'hold')
                docker('start', name)
                p = docker('exec', name, '/probe', 'exit23', expected=23)
                require(p.stdout.strip() == 'guest-out' and p.stderr.strip() == 'guest-err', 'exec streams or exit')
                resolved = owned_run(tag, 'resolve', 'qualify-svc', flags=['--network', network]).stdout.strip()
                ipaddress.ip_address(resolved)
                docker('stop', '--time', '3', name)
                require(docker('wait', name).stdout.strip() == '0', 'unknown or incorrect wait')
                require(docker('inspect', '--format', '{{.State.Status}}:{{.State.ExitCode}}', name).stdout.strip()
                        == 'exited:0', 'state after SIGTERM')
                require(docker('logs', name).stdout.splitlines() == ['ready', 'stopped'], 'signal or logs')
            rec.record('network-dns-exec-signal-wait-logs', lifecycle)
            def compose():
                spec = work / 'compose.yaml'
                spec.write_text(f'services:\n  check:\n    image: {tag}\n    pull_policy: never\n    '
                                'command: [identity]\n    hostname: compose\n    working_dir: /work\n    '
                                'environment:\n      QUALIFY: compose\n')
                cli = ['compose', '-p', prefix, '-f', spec]
                rec.data['compose'] = docker('compose', 'version').stdout.strip()
                cleanup.callback(remove, *cli, 'down', '--timeout', '2')
                p = docker(*cli, 'up', '--exit-code-from', 'check', '--abort-on-container-exit', '--no-build')
                require('0:0|/work|compose|compose' in p.stdout, 'Compose result')
            rec.record('compose-up-exit-down', compose)
            for clients in args.clients:
                for block in range(args.rounds):
                    def batch():
                        def task(_):
                            p = owned_run(tag, 'exit23', flags=['--network', 'none', '--cpus', '1', '--memory', '64m'],
                                          expected=23)
                            require(p.stdout.strip() == 'guest-out' and p.stderr.strip() == 'guest-err',
                                    'wrong exit streams')
                        with ThreadPoolExecutor(clients) as pool:
                            list(pool.map(task, range(clients)))
                        return {'known_exits': clients}
                    rec.record('run-to-known-exit', batch, clients=clients, block=block)
        if args.oci:
            rec.record('native-runc-lifecycle', lambda: native_oci(probe, work, prefix))
    return rec.finish()


def compile_guest(probe, arch, env):
    run(['go', 'build', '-trimpath', '-buildvcs=false', '-ldflags=-s -w -buildid=', '-o', probe,
         Path(__file__).with_name('guest.go')], env={**env, 'GOOS': 'linux', 'GOARCH': arch, 'CGO_ENABLED': '0',
                                                    'GOTOOLCHAIN': 'local', 'GOFLAGS': ''}, timeout=120)
    return {'arch': arch, 'sha256': digest(probe)}


def native_oci(probe, work, name):
    import shutil
    require(platform.system() == 'Linux', 'runc needs a native Linux runner')
    bundle = work / 'bundle'
    root = bundle / 'rootfs'
    root.mkdir(parents=True)
    shutil.copy2(probe, root / 'probe')
    run(['runc', 'spec'], cwd=bundle)
    config = json.loads((bundle / 'config.json').read_text())
    config['process'].update(terminal=False, args=['/probe', 'hold'])
    for mount in config['mounts']:
        (root / mount['destination'].lstrip('/')).mkdir(parents=True, exist_ok=True)
    (bundle / 'config.json').write_text(json.dumps(config))
    # Separate state directory and exact container ID even on a shared Linux host.
    state = work / 'runc-state'
    state.mkdir()
    def runc(*args, expected=0):
        return run(['sudo', '-n', 'runc', '--root', state, *args], expected=expected, cwd=bundle, timeout=15)
    try:
        # The created init inherits stdio before start. Pipes here would keep
        # communicate() waiting for the very start command it precedes.
        with (work / 'oci-stdio').open('w') as output:
            cmd = ['sudo', '-n', 'runc', '--root', state, 'create', '--bundle', bundle, name]
            p = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=output, stderr=output, timeout=15)
        require(p.returncode == 0, (work / 'oci-stdio').read_text()[-1200:] or 'runc create failed')
        require(json.loads(runc('state', name).stdout)['status'] == 'created', 'OCI create state')
        runc('start', name)
        require(json.loads(runc('state', name).stdout)['status'] == 'running', 'OCI start state')
        p = runc('exec', name, '/probe', 'exit23', expected=23)
        require(p.stdout.strip() == 'guest-out' and p.stderr.strip() == 'guest-err', 'OCI exec result')
        runc('kill', name, 'TERM')
        deadline = time.monotonic() + 3
        while json.loads(runc('state', name).stdout)['status'] != 'stopped':
            require(time.monotonic() < deadline, 'OCI stop timeout')
            time.sleep(.025)
    finally:
        runc('delete', '--force', name)
    require(json.loads(runc('list', '--format', 'json').stdout) in (None, []), 'OCI leftover')
    return {'version': run(['runc', '--version']).stdout.strip()}


if __name__ == '__main__':
    raise SystemExit(main())
