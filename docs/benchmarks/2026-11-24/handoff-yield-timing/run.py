"""Run or summarize the native socketpair handoff experiment from its recorded sources."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
REV = '2e9b37c1e68334c443d71b729f0bd6334d824ddd'
PATCH = HERE.parent / 'handoff-aware-yield-native/candidate.patch'
SOCKET_FIXTURE = Path('scripts/relaybench/filter_work.c')
SOURCE = Path('Sources/CPublishedTCP/PublishedTCP.c')
HEADER = Path('Sources/CPublishedTCP/include/PublishedTCP.h')
SWIFT = Path('Sources/MicropodRuntime/NativeLoopbackRelay.swift')
SEED = 230062411
WARM = [2, 25]
ARMS = ('control', 'yield')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path, data):
    tmp = path.with_suffix('.partial')
    tmp.write_text(json.dumps(data, indent=2, allow_nan=False) + '\n')
    tmp.replace(path)


def build(tmp):
    binaries, hashes = {}, {}
    for name in ARMS:
        tree = tmp / name
        for file in (SOCKET_FIXTURE, SOURCE, HEADER, SWIFT):
            path = tree / file
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(subprocess.check_output(['git', '-C', ROOT, 'show', f'{REV}:{file}']))
        if name == 'yield':
            subprocess.run(['patch', '-s', '-F', '0', '-p1', '-i', PATCH], cwd=tree, check=True)
        binary = tree / 'fixture'
        subprocess.run(['xcrun', 'clang', '-std=gnu11', '-O2', '-Wall', '-Wextra', '-Werror',
                        f'-DYIELD_ON_HANDOFF={int(name == "yield")}', '-DMICROPOD_BENCH_FIXED_RELAY_BUDGET=1',
                        '-DRELAY_SOURCE="PublishedTCP.c"', '-I', tree / SOCKET_FIXTURE.parent,
                        '-I', tree / SOURCE.parent, '-I', tree / HEADER.parent,
                        HERE / 'burst.c', '-o', binary], check=True)
        binaries[name] = binary
        hashes[name] = {'binary':digest(binary), 'relay':digest(tree / SOURCE), 'header':digest(tree / HEADER),
                        'staging':digest(tree / SOCKET_FIXTURE)}
    return binaries, hashes


def plan():
    rng = random.Random(SEED)
    orders = [list(ARMS), list(reversed(ARMS))] * 4
    rng.shuffle(orders)
    blocks = []
    for arms in orders:
        positions = list(range(1, 33)) * 2
        rng.shuffle(positions)
        blocks.append({'arms':arms, 'positions':positions})
    return blocks


def execute(binary, positions):
    completion = subprocess.run([binary, *map(str, positions)], capture_output=True, text=True, timeout=35)
    if completion.returncode:
        raise RuntimeError(f'{binary.name} exited {completion.returncode} after '
                           f'{len(completion.stdout.splitlines())} waves: {completion.stderr}')
    rows = [json.loads(s) for s in completion.stdout.splitlines()]
    if [r['position'] for r in rows] != positions or any(
        r['bytes'] != 8 * 2**20 or r['half_closes'] != 18 or
        min(r['bulk_ns'], r['reply_ns'], r['callback_cpu_ns'], r['callbacks']) <= 0 or
        not 0 <= r['queue_ns'] <= r['reply_ns'] for r in rows
    ):
        raise ValueError('incomplete scored wave or wrong work')
    return rows


def pctl(ordered, n):
    # Nearest rank percentiles, applicable also to the empirical bootstrap distribution.
    import math
    return ordered[max(0, math.ceil(n*len(ordered))-1)]


def metrics(rows):
    byte_count = sum(v['bytes'] for v in rows)
    return {'MiB_s': byte_count / 2**20 / (sum(v['bulk_ns'] for v in rows) / 1e9),
            'callback_CPU_s_per_GiB': sum(v['callback_cpu_ns'] for v in rows) / 1e9 / (byte_count / 2**30),
            'reply_p95_us': pctl(sorted(v['reply_ns']/1000 for v in rows), .95),
            'reply_p99_us': pctl(sorted(v['reply_ns']/1000 for v in rows), .99),
            'queue_p95_us': pctl(sorted(v['queue_ns']/1000 for v in rows), .95)}


def summarize(raw):
    blocks = raw['plan']
    if raw['status'] != 'complete' or len(raw['attempts']) != 2 * len(blocks) or blocks != plan():
        raise ValueError('incomplete or different predeclared plan')
    by_arm = {arm:[] for arm in ARMS}
    for i, block in enumerate(blocks):
        for j, arm in enumerate(block['arms']):
            attempt = raw['attempts'][2*i+j]
            rows = attempt['waves']
            if (attempt['arm'], attempt['block'], [r['position'] for r in rows]) != (arm, i+1, WARM+block['positions']):
                raise ValueError('different paired schedule or missing waves')
            by_arm[arm].append(metrics(rows[len(WARM):]))
    a,b = [by_arm[arm] for arm in ARMS]
    rng = random.Random(SEED)
    resamples = [[rng.randrange(len(a)) for _ in a] for _ in range(20000)]
    out = {}
    for key in a[0]:
        effects = [100*(y[key]/x[key]-1) for x,y in zip(a,b)]
        boot = sorted(statistics.median(effects[i] for i in inds) for inds in resamples)
        out[key] = {'control':statistics.median(r[key] for r in a),'yield':statistics.median(r[key] for r in b),
                    'paired_pct':statistics.median(effects),'pair_bootstrap_95_pct':[pctl(boot,.025),pctl(boot,.975)],
                    'candidate_lower_in_pairs':sum(v<0 for v in effects), 'paired_changes_pct':effects}
    return out


def run(action, path):
    if action == 'summary':
        print(json.dumps(summarize(json.loads(path.read_text())), indent=2))
        return
    with tempfile.TemporaryDirectory(prefix='mp-handoff-timing-') as tmp:
        binaries, seals = build(Path(tmp))
        if action == 'smoke':
            for arm in ARMS:
                print(arm, execute(binaries[arm], [1,32]))
            return
        record = {'seed': SEED,'source_revision':REV, 'native_candidate_sha256':digest(PATCH),
                  'fixture_sha256':digest(HERE/'burst.c'),'driver_sha256':digest(HERE/'run.py'),
                  'compiler':subprocess.check_output(['xcrun','clang','--version'], text=True).splitlines()[0],
                  'host':platform.node(), 'machine':platform.machine(),'macos':platform.mac_ver()[0],
                  'binaries':seals,'plan':plan(),'warmup_positions':WARM,'attempts':[], 'status':'started'}
        # Coordinate timed host CPU use with the VM suite's exclusive lock.
        lock = (HERE.parent/'disposable-local-fixture/terminal-run.lock').open('rb')
        try:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            lock.close()
            raise RuntimeError('a local VM suite is active')
        path.touch(exist_ok=False)
        save(path, record)
        try:
            for i, block in enumerate(record['plan'], 1):
                for arm in block['arms']:
                    row = {'block':i,'arm':arm,'start_ns':time.time_ns()}
                    record['attempts'].append(row)
                    save(path,record)
                    row['waves'] = execute(binaries[arm], WARM+block['positions'])
                    row['end_ns'] = time.time_ns()
                    save(path,record)
                    time.sleep(.15)
            record['status'] = 'complete'
        except BaseException as error:
            record.update(status='interrupted',error=repr(error))
            raise
        finally:
            lock.close()
            save(path, record)
        print(json.dumps(summarize(record), indent=2))

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('smoke','run','summary'))
    parser.add_argument('path',type=Path,nargs='?',default=HERE/'first-attempts.json')
    args=parser.parse_args()
    run(args.action,args.path)
