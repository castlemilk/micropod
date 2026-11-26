"""Six paired first-attempts. Only the Swift accept-to-owner dispatch policy changes."""
import argparse
from contextlib import ExitStack, contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import select
import shutil
import time
import subprocess
import sys
import uuid
from build import WORK, sha

FLOOR_GIB = 60
SEED = 202611242308
POLICIES = ('stock','batch2')


def mixed():
    spec=importlib.util.spec_from_file_location('sealed_mixed',WORK/'suite.py')
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    return mod


def admission(base):
    before=base.system_counter('host_cpu',4)
    start=time.monotonic();time.sleep(2)
    after=base.system_counter('host_cpu',4)
    delta=[(b-a)%2**32 for a,b in zip(before,after)] if isinstance(before,list) and isinstance(after,list) else None
    idle=delta[2]/sum(delta) if delta and sum(delta)>0 else None
    free=shutil.disk_usage(WORK).free/2**30
    return {'time':base.now(),'idle_fraction':idle,'raw_cpu_before':before,'raw_cpu_after':after,'cpu_delta':delta,
            'observation_s':time.monotonic()-start,'eligible':idle is not None and idle>=.90 and free>=FLOOR_GIB,
            'idle_status':'measured' if idle is not None else 'unavailable: missing or non-advancing host ticks',
            'filesystem_free_GiB':free}


@contextmanager
def owned_relay(base, name, service_port, destination, marker, first):
    logfile=destination/'relay.stderr'
    with logfile.open('xb') as log:
        child=subprocess.Popen([WORK/('relay-'+name),str(service_port)],stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE,stderr=log,text=True)
        try:
            if not select.select([child.stdout],[],[],8)[0]: raise TimeoutError('relay bind')
            state=json.loads(child.stdout.readline());first['relay_configuration']=state
            assert state['workers']==2 and state['read_bytes']==256*1024 and state['callback_events']==128 and state['guest_port']==service_port,state
            endpoint=('127.0.0.1',state['port'])
            assert base.exchange(endpoint,'/id')==marker.encode()
            payload=base.exchange(endpoint,'/data')
            assert hashlib.sha256(payload).hexdigest()==base.PAYLOAD and len(payload)==8<<20
            yield child,f'127.0.0.1:{state["port"]}'
        finally:
            if child.poll() is None:
                child.stdin.close()
                try:child.wait(timeout=5)
                except subprocess.TimeoutExpired:base.stop(child)
            child.stdout.close();log.flush()
            rows=[list(map(int,l.split()[1:])) for l in logfile.read_text().splitlines() if l.startswith('handoff ')]
            first['owner_accounting']=rows
            if child.returncode!=0 or len(rows)!=2 or not all(len(r)==5 and r[0]==r[2] and r[1]==r[3] and r[1]<=r[0]<=2*r[1] for r in rows):
                raise ValueError(('relay admission accounting',child.returncode,rows))
            if name=='stock' and any(r[0]!=r[1] for r in rows): raise ValueError('stock must submit one block per fd')


def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('mode',choices=['smoke','run','diagnostic']);ap.add_argument('output',type=Path);args=ap.parse_args()
    base=mixed(); out=args.output.resolve();out.mkdir(parents=False,exist_ok=False)
    build=json.loads((WORK/'build.json').read_text());assert all(sha(WORK/p)==h for p,h in build['binaries'].items())
    assert sha(Path(__file__).resolve())==build['fixture_sha256']['study.py']
    orders=[list(POLICIES),list(POLICIES[::-1])]*3;random.Random(SEED).shuffle(orders)
    receipt={'stable_id':'230.08','scope':'Darwin host-only mixed load, native loopback relay and service','mode':args.mode,'seed':SEED,'orders':orders,'attempts':[],'smokes':[], 'build':build,'created':base.now(),'filesystem_floor_GiB':FLOOR_GIB,'idle_floor_fraction':0.9,'accounting_columns':['accepted','enqueued_blocks','adopted','completed_blocks','blocks_started_by_receive_order_after_first_17_per_owner']}
    dest=out/'receipt.json';save=lambda:base.write(dest,receipt);save()
    try:
        with ExitStack() as all_owned:
            marker='handoff-'+uuid.uuid4().hex;server,svcport=base.service(all_owned,marker,out)
            if args.mode=='smoke':
                for name in POLICIES:
                    d=out/name;d.mkdir();first={'arm':name};receipt['smokes'].append(first);save()
                    with owned_relay(base,name,svcport,d,marker,first):pass
                    save()
            else:
                for block,order in enumerate(orders,1):
                    for pos,name in enumerate(order,1):
                        d=out/f'block-{block}-{name}';d.mkdir()
                        first={'arm':name,'block':block,'order':pos,'started':base.now()};receipt['attempts'].append(first);save()
                        with ExitStack() as owned:
                            rp,addr=owned.enter_context(owned_relay(base,name,svcport,d,marker,first));gate=admission(base);first['admission']=gate;save()
                            if 'error' in gate or gate['filesystem_free_GiB']<FLOOR_GIB or (args.mode=='run' and not gate['eligible']):
                                receipt['status']='pre-start gate blocked';return
                            first.update(base.observe_client(owned,server,rp,addr,marker,d,FLOOR_GIB));save()
                        first['finished']=base.now();save()
                        if first['minimum_observed_free_GiB']<FLOOR_GIB:receipt['status']='disk gate lost';return
        receipt['status']='smoke complete' if args.mode=='smoke' else 'complete'
    except BaseException as ex:
        receipt.update(status='interrupted',error=repr(ex));raise
    finally:
        receipt['finished']=base.now();save();print(receipt.get('status'),dest,flush=True)

if __name__=='__main__':main()
