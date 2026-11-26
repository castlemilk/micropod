"""Measure reassigning unused read allowance within one native Darwin kqueue poll."""
import argparse
import fcntl
import hashlib
import json
import math
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
RELAY_REV = '86ca2713a0791d26c137e9a8c6385e1b6bd04ebb'
STAGING_REV = '2e9b37c1e68334c443d71b729f0bd6334d824ddd'
SOURCE = 'Sources/CPublishedTCP/PublishedTCP.c'
ARMS = ('stock', 'credit')
SEED = 230152412
WARM = [0, 15]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(tmp):
    seals = {}
    files = [(RELAY_REV, SOURCE), (RELAY_REV, 'Sources/CPublishedTCP/include/PublishedTCP.h'),
             (STAGING_REV, 'scripts/relaybench/filter_work.c')]
    for revision, name in files:
        dest = tmp / Path(name).name
        dest.write_bytes(subprocess.check_output(['git', '-C', ROOT, 'show', f'{revision}:{name}']))
        seals[name] = sha(dest)
    stock = json.loads((HERE.parent/'disposable-local-fixture/20261124T062433Z/revised-runtime-build.json').read_bytes())
    if seals[SOURCE] != stock['source_sha256'][SOURCE] or stock['source_revision'] != RELAY_REV:
        raise ValueError('source differs from the live baseline')
    subprocess.run(['patch', '-s', '-F', '0', '-i', HERE/'read-credit.patch'], cwd=tmp, check=True)
    binary = tmp/'burst'
    flags = ['-std=gnu11', '-O2', '-Wall', '-Wextra', '-Werror', '-DRELAY_SOURCE="PublishedTCP.c"']
    subprocess.run(['xcrun', 'clang', *flags, '-I', tmp, HERE/'burst.c', '-o', binary], check=True)
    seals.update(executable=sha(binary), patched_source=sha(tmp/'PublishedTCP.c'), patch=sha(HERE/'read-credit.patch'),
                 fixture=sha(HERE/'burst.c'), driver=sha(Path(__file__)), flags=flags)
    return binary, seals


def schedule():
    rng = random.Random(SEED)
    orders = [list(ARMS), list(reversed(ARMS))] * 4
    rng.shuffle(orders)
    plan = []
    for arms in orders:
        layouts = list(range(16)) * 4
        rng.shuffle(layouts)
        plan.append(dict(arms=arms, layouts=layouts))
    return plan


def execute(binary, arm, layouts):
    proc = subprocess.run([binary, arm, *map(str,layouts)], capture_output=True, text=True, timeout=35)
    if proc.returncode:
        raise RuntimeError(f'{arm}: exit {proc.returncode} after {len(proc.stdout.splitlines())} waves, {proc.stderr}')
    rows = [json.loads(line) for line in proc.stdout.splitlines()]
    validate(arm, layouts, rows)
    return rows


def validate(arm, layouts, rows):
    if [r['layout'] for r in rows] != layouts:
        raise ValueError('incomplete wave schedule')
    for r in rows:
        if (r['bytes'] != 4*2**20 or r['markers'] != 1 or r['half_closes'] != 34 or
            min(r['bulk_ns'], r['owner_ns'], r['reply_ns'], r['polls'], r['callbacks']) <= 0 or
            r['reads'] != r['writes'] or not 16 <= r['reads'] <= 24 or
            (arm == 'stock' and (r['reads'] != 24 or r['above_cap_reads'] != 0))):
            raise ValueError(f'bad counts: {arm} {r}')


def pctl(values, fraction):
    return sorted(values)[math.ceil(fraction*len(values)) - 1]


def metrics(rows):
    total = sum(r['bytes'] for r in rows)
    return dict(MiB_s=total/2**20/(sum(r['bulk_ns'] for r in rows)/1e9),
                callback_CPU_s_per_GiB=sum(r['owner_ns'] for r in rows)/1e9/(total/2**30),
                reply_p95_us=pctl([r['reply_ns']/1000 for r in rows], .95),
                reply_p99_us=pctl([r['reply_ns']/1000 for r in rows], .99),
                mean_reads=statistics.mean(r['reads'] for r in rows))


def summarize(data):
    plan = schedule()
    if data['status'] != 'complete' or plan != data['schedule'] or len(data['attempts']) != 2*len(plan):
        raise ValueError('incomplete or different predeclared plan')
    pairs = []
    for i, block in enumerate(plan):
        pair = {}
        for j, arm in enumerate(block['arms']):
            attempt = data['attempts'][2*i+j]
            if (attempt['arm'], attempt['block']) != (arm, i+1):
                raise ValueError('different arm order')
            validate(arm, WARM+block['layouts'], attempt['waves'])
            pair[arm] = metrics(attempt['waves'][len(WARM):])
        pairs.append(pair)
    rng = random.Random(SEED)
    indices = rng.choices(range(len(pairs)), k=20000*len(pairs))
    summary = {}
    for key in pairs[0]['stock']:
        changes = [100*(p['credit'][key]/p['stock'][key]-1) for p in pairs]
        draws = [statistics.median(changes[i] for i in indices[start:start+len(pairs)])
                 for start in range(0,len(indices),len(pairs))]
        summary[key] = dict(stock=statistics.median(p['stock'][key] for p in pairs),
                            credit=statistics.median(p['credit'][key] for p in pairs),
                            paired_pct=statistics.median(changes),
                            pair_bootstrap_95_pct=[pctl(draws,.025),pctl(draws,.975)],
                            changes_pct=changes)
    return summary


def save(path, data):
    tmp = path.with_suffix('.partial')
    tmp.write_text(json.dumps(data, indent=2, allow_nan=False)+'\n')
    tmp.replace(path)


def main(action, dest):
    if action == 'summary':
        print(json.dumps(summarize(json.loads(dest.read_bytes())), indent=2))
        return
    with tempfile.TemporaryDirectory() as directory:
        binary, seals = build(Path(directory))
        if action == 'smoke':
            for arm in ARMS:
                print(arm, execute(binary, arm, WARM))
            return
        with (HERE.parent/'disposable-local-fixture/terminal-run.lock').open('rb') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            data = dict(host=platform.node(), os=platform.mac_ver()[0], machine=platform.machine(),
                        compiler=subprocess.check_output(['xcrun','clang','--version'], text=True).splitlines()[0],
                        seal=seals, source_revision=RELAY_REV, staging_revision=STAGING_REV, seed=SEED,
                        schedule=schedule(), warmup_layouts=WARM, status='started', attempts=[])
            dest.touch(exist_ok=False)
            save(dest, data)
            try:
                for i, block in enumerate(data['schedule'], 1):
                    for arm in block['arms']:
                        row = dict(block=i, arm=arm, start_ns=time.time_ns())
                        data['attempts'].append(row)
                        save(dest, data)
                        row['waves'] = execute(binary, arm, WARM+block['layouts'])
                        row['end_ns'] = time.time_ns()
                        save(dest, data)
                        time.sleep(.15)
                data['status'] = 'complete'
            except BaseException as e:
                data.update(status='interrupted', error=repr(e))
                raise
            finally:
                save(dest, data)
            print(json.dumps(summarize(data), indent=2))


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=('smoke','run','summary'))
    p.add_argument('output', type=Path, nargs='?', default=HERE/'first-attempts.json')
    opts = p.parse_args()
    main(opts.action, opts.output)
