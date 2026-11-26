"""Matched 256 KiB control with no opportunity to spend read credit."""
import argparse
import fcntl
import json
from pathlib import Path
import random
import statistics
import subprocess
import tempfile
import time

import run as mixed

SEED = 230152413
HERE = Path(__file__).resolve().parent


def schedule():
    rng = random.Random(SEED)
    orders = [list(mixed.ARMS), list(reversed(mixed.ARMS))] * 4
    rng.shuffle(orders)
    plan = []
    for order in orders:
        layouts = list(range(16)) * 4
        rng.shuffle(layouts)
        plan.append(dict(arms=order, layouts=layouts))
    return plan


def validate(layouts, waves):
    if [r['layout'] for r in waves] != layouts:
        raise ValueError('incomplete receiver schedule')
    for r in waves:
        if (r['bytes'], r['reads'], r['writes'], r['above_cap_reads'], r['markers'],
                r['half_closes'], r['max_poll_bytes']) != (4*2**20, 16, 16, 0, 1, 34, 4*2**20):
            raise ValueError('changed workload, incomplete transfer or unexpected credit')
        if min(r[k] for k in ('reply_ns','bulk_ns','owner_ns','callbacks','polls')) <= 0:
            raise ValueError('invalid timing or callback evidence')


def summary(data):
    plan = schedule()
    if data['status'] != 'complete' or data['plan'] != plan or len(data['attempts']) != 2*len(plan):
        raise ValueError('incomplete control')
    pairs = []
    for i, block in enumerate(plan):
        pair = {}
        for j, arm in enumerate(block['arms']):
            row = data['attempts'][2*i+j]
            if (row['block'], row['arm']) != (i+1,arm):
                raise ValueError('changed order')
            validate(mixed.WARM+block['layouts'],row['waves'])
            pair[arm] = mixed.metrics(row['waves'][len(mixed.WARM):])
        pairs.append(pair)
    rng = random.Random(SEED)
    indices = [rng.choices(range(len(pairs)),k=len(pairs)) for _ in range(20000)]
    result = {}
    for key in pairs[0]['stock']:
        changes = [100*(p['credit'][key]/p['stock'][key]-1) for p in pairs]
        draws = [statistics.median(changes[i] for i in sample) for sample in indices]
        result[key] = dict(stock=statistics.median(p['stock'][key] for p in pairs),
                           credit=statistics.median(p['credit'][key] for p in pairs),
                           paired_pct=statistics.median(changes), changes_pct=changes,
                           pair_bootstrap_95_pct=[mixed.pctl(draws,.025), mixed.pctl(draws,.975)])
    return result


def measure(dest):
    with tempfile.TemporaryDirectory(prefix='mp-homogeneous-') as tmp:
        tmp = Path(tmp)
        binary, seals = mixed.build(tmp)
        original = (HERE/'burst.c').read_text()
        layout = 'lengths[i] = i%2 == parity ? SMALL : DEEP;'
        if original.count(layout) != 1:
            raise ValueError('unknown mixed-supply fixture')
        source = tmp/'homogeneous.c'
        source.write_text(original.replace(layout, 'lengths[i] = 256 * 1024;'))
        subprocess.run(['xcrun','clang',*seals['flags'],'-I',tmp,source,'-o',binary], check=True)
        seals.update(homogeneous_source=mixed.sha(source), homogeneous_executable=mixed.sha(binary),
                     homogeneous_driver=mixed.sha(Path(__file__)))
        with (HERE.parent/'disposable-local-fixture/terminal-run.lock').open('rb') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX | fcntl.LOCK_NB)
            plan = schedule()
            data = dict(status='started', seed=SEED, plan=plan, warmup_layouts=mixed.WARM, seals=seals,
                        host=mixed.platform.node(), os=mixed.platform.mac_ver()[0], arch=mixed.platform.machine(), attempts=[])
            dest.touch(exist_ok=False)
            mixed.save(dest,data)
            try:
                for i, block in enumerate(plan,1):
                    for arm in block['arms']:
                        row = dict(arm=arm,block=i,start_ns=time.time_ns())
                        data['attempts'].append(row)
                        mixed.save(dest,data)
                        layouts = mixed.WARM+block['layouts']
                        proc = subprocess.run([binary,arm,*map(str,layouts)],capture_output=True,text=True,timeout=35)
                        row['waves'] = [json.loads(s) for s in proc.stdout.splitlines()]
                        row['end_ns'] = time.time_ns()
                        if proc.returncode:
                            raise ValueError(f'{arm} exited {proc.returncode}: {proc.stderr}')
                        validate(layouts,row['waves'])
                        mixed.save(dest,data)
                        time.sleep(.15)
                data['status'] = 'complete'
            except BaseException as exc:
                data.update(status='interrupted',error=repr(exc))
                raise
            finally:
                mixed.save(dest,data)
    return data


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=('run','summary'))
    parser.add_argument('output',type=Path,nargs='?',default=HERE/'homogeneous-first.json')
    opts = parser.parse_args()
    data = measure(opts.output) if opts.action=='run' else json.loads(opts.output.read_bytes())
    print(json.dumps(summary(data),indent=2))
