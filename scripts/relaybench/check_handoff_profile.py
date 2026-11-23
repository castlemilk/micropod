"""Compile the real Swift/C relay and exercise its threaded profiling path without TCP."""
import hashlib
import json
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
RELAY = ROOT / 'Sources/CPublishedTCP'
SWIFT = ROOT / 'Sources/MicropodRuntime/NativeLoopbackRelay.swift'


def main():
    if sys.platform != 'darwin':
        raise SystemExit('This relay uses Darwin kqueue and dispatch.')
    with tempfile.TemporaryDirectory(prefix='relay-handoff-') as directory:
        local = Path(directory)
        (local / 'Bridge.h').write_text('#include "PublishedTCP.h"\nvoid fixture_submit(int);\nunsigned fixture_finish(void);\n')
        (local / 'module.modulemap').write_text('module CPublishedTCP { header "Bridge.h" export * }\n')
        obj = local / 'fixture.o'
        subprocess.run(['clang', '-std=gnu11', '-O2', '-Wall', '-Wextra', '-Werror', '-I', str(RELAY / 'include'),
                        '-c', str(HERE / 'handoff_profile_fixture.c'), '-o', str(obj)], check=True)
        binary = local / 'fixture'
        subprocess.run(['swiftc', '-swift-version', '6', '-module-cache-path', str(local / 'module-cache'), '-I', directory, '-Xcc', '-I' + str(RELAY / 'include'),
                        str(SWIFT), str(HERE / 'handoff_profile_fixture.swift'), str(obj), '-o', str(binary)], check=True)
        output = subprocess.check_output([str(binary)], text=True, timeout=10).splitlines()
    profiles = [json.loads(line.removeprefix('published TCP profile ')) for line in output
                if line.startswith('published TCP profile ')]
    if [p['port'] for p in profiles] != [4002, 4000]:
        raise ValueError('unexpected profile output for disabled, queued and inline modes')
    clocks = [line for line in output if line.startswith('clock ')]
    if clocks != ['clock 2 false 8', 'clock 2 true 16', 'clock 0 true 8']:
        raise ValueError(f'unexpected accept/adopt C timestamp counts: {clocks}')
    queued, inline = profiles
    if any(p['accepted'] != 8 or p['connect_errors'] != 8 or p['connected'] != 0 for p in profiles):
        raise ValueError('missing early-failed adoptions')
    if inline['handoff_by_worker'] or any(any(bins) for bins in inline['handoff'].values()):
        raise ValueError('inline adoption incorrectly counted as a handoff')
    owners = queued['handoff_by_worker']
    if len(owners) != 2:
        raise ValueError('missing owner profiles')
    for phase in ('accept_to_enqueue_us', 'enqueue_to_adopt_us', 'accept_to_adopt_us'):
        histograms = [owner[phase] for owner in owners]
        if any(len(bins) != 12 or sum(bins) != 4 for bins in histograms):
            raise ValueError(f'expected four samples for each owner: {phase}')
        if [sum(counts) for counts in zip(*histograms)] != queued['handoff'][phase]:
            raise ValueError(f'aggregate differs from per-worker counts: {phase}')
        if phase != 'accept_to_enqueue_us' and any(bins[-1] < 3 for bins in histograms):
            raise ValueError(f'queued work did not register the induced wait: {phase}')
    files = [SWIFT, RELAY / 'PublishedTCP.c', RELAY / 'include/PublishedTCP.h', Path(__file__).resolve(),
             HERE / 'handoff_profile_fixture.swift', HERE / 'handoff_profile_fixture.c']
    print(json.dumps({
        'schema': 1, 'darwin_release': platform.release(), 'source_sha256': {
            str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
        'scope': 'Eight descriptor handoffs per queued arm and eight direct accepts in the inline control. '
                 'Anonymous UNIX descriptors enter the production accept callback via a socketpair mailbox. '
                 'Real Swift owner queues run C adoption. Client TCP_NODELAY fails on the UNIX descriptor before '
                 'any dial. A 32 ms test gate holds previous setup work on each owner to force queue wait. '
                 'Histogram values describe this forced wait, not TCP or production latency.',
        'c_clock_calls': clocks, 'profiled': [{k: p[k] for k in ('port', 'accepted', 'connect_errors', 'handoff',
                                                                 'handoff_by_worker')} for p in profiles],
    }, indent=2))


if __name__ == '__main__':
    main()
