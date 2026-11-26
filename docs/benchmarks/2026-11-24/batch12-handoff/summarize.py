"""Verify raw first attempts and compare all clean paired observations in MiB/s."""
from hashlib import sha256
from itertools import product
import json
from pathlib import Path
from statistics import median, quantiles
import sys


def effect(rows):
    if not rows:return None
    a,b=zip(*rows);ratios=[100*(y/x-1) for x,y in rows if x]
    if len(ratios)<2:return {'stock':median(a),'batch2':median(b),'paired_pct':None,'ci95_pct':None}
    draws=sorted(median(draw) for draw in product(ratios,repeat=len(ratios)))
    bounds=quantiles(draws,n=40,method='inclusive')
    return {'stock':median(a),'batch2':median(b),'paired_pct':median(ratios),'ci95_pct':[bounds[0],bounds[-1]],'higher_pairs':sum(y>x for x,y in rows)}


def summarize(path):
    data=json.loads(path.read_bytes()); rows=data['attempts']; arms=('stock','batch2'); blocks={}
    assert set(sum(data['orders'],[]))==set(arms) and len(rows)<=12
    fields={};files={}
    for row in rows:
        name=row['arm'];k=row['block'];assert data['orders'][k-1][row['order']-1]==name and name not in blocks.setdefault(k,{})
        blocks[k][name]=row
        if 'client' not in row:continue
        arm=path.parent/f'block-{k}-{name}'
        for f in ('client.out','client.err','relay.stderr'):
            p=arm/f;files[str(p.relative_to(path.parent))]=sha256(p.read_bytes()).hexdigest()
        assert json.loads((arm/'client.out').read_bytes())==row['client']
        accounting=[list(map(int,l.split()[1:])) for l in (arm/'relay.stderr').read_text().splitlines() if l.startswith('handoff ')]
        assert accounting==row['owner_accounting']
        if row['delivery_clean']:
            assert len(accounting)==2 and all(r[0]==137 and r[2]==137 and 0<=r[4]<=120 for r in accounting),accounting
            assert row['client']['reopened']==0 and not row['client']['errors']
    pairs=[(b['stock'],b['batch2']) for b in blocks.values() if len(b)==2 and all(r.get('delivery_clean') for r in b.values())]
    summary={'source_sha256':sha256(path.read_bytes()).hexdigest(),'status':data['status'],'attempts':len(rows),'joint_clean_pairs':len(pairs),'by_arm':{},'effects':{},'raw_sha256':files}
    for arm in arms:
        all_rows=[r for r in rows if r['arm']==arm and 'client' in r];clients=[r['client'] for r in all_rows]
        accounted=[v for r in all_rows for v in r['owner_accounting']];post=sum(r[4] for r in accounted)
        summary['by_arm'][arm]={'attempted':len([r for r in rows if r['arm']==arm]),'completed':len(all_rows),'clean':sum(r['delivery_clean'] for r in all_rows),'p95_guard':sum(r['latency_p95_at_most_75_ms'] for r in all_rows),'fresh':sum(c.get('arrivals',0) for c in clients),'errors':sum(len(c.get('errors') or []) for c in clients),'reopens':sum(c.get('reopened',0) for c in clients),'bulk_bytes':sum(c.get('bytes',0) for c in clients),'all_fd':sum(r[0] for r in accounted),'all_blocks':sum(r[1] for r in accounted),'post_initial_fd':sum(max(0,r[0]-17) for r in accounted),'post_initial_blocks':post,'lo0':{k:sum(r['loopback_host_shared_delta'][k] for r in all_rows) for k in ('in_errors','out_errors','in_queue_drops')} if all(r['loopback_host_shared_delta'] for r in all_rows) else None,'disk_min_GiB':min((r['minimum_observed_free_GiB'] for r in all_rows),default=None),'admission_idle_fraction':[r['admission']['idle_fraction'] for r in all_rows]}
    for key in ('mib_s','fresh_p95_us','fresh_p99_us','dispatch_p95_us'):
        summary['effects'][key]=effect([(a['client'][key],b['client'][key]) for a,b in pairs])
    for role in ('client','server','relay'):
        for k in ('cpu_s_per_scored_GiB','runnable_thread_s_per_wall_s','runnable_s'):
            summary['effects'][role+'_'+k]=effect([(a['cost_per_role'][role][k],b['cost_per_role'][role][k]) for a,b in pairs if a['cost_per_role'].get(role) and b['cost_per_role'].get(role)])
    return summary

if __name__=='__main__': print(json.dumps(summarize(Path(sys.argv[1])),indent=2))
