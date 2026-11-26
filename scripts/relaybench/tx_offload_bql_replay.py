"""Read the first attempts and guest TX counters from same-boot Linux NIC experiments."""
import argparse
import json
import re
from statistics import median

from gamma_contrasts import GIB, ROOT, clean_client, process_delta, read_receipt
from guest_tx_replay import check
from nic_steering_replay import VCPU

BENCH = ROOT / "docs/benchmarks"
SUPPLEMENT = "1ade90ef711545a7ad913c8bd8725cd7fe999dd3da985944f978cd72d0265fc0"


def nic_state(blob):
    tx = re.search(r'^\s*TX:\s+bytes packets errors dropped carrier collsns\s*\n\s*([\d ]+)\s*$', blob, re.M)
    fields = list(map(int, tx[1].split()))
    counters = dict(zip(('bytes','packets','errors','dropped','carrier','collisions'), fields))
    for name in ('tx0_kicks','tx0_tx_timeouts'):
        counters[name] = int(re.search(r'^\s*'+name+r': (\d+)$',blob,re.M)[1])
    flags = dict(re.findall(r'^[ \t]*([a-z0-9-]+): (on|off)(?: \[fixed\])?$',blob,re.M))
    return counters, flags


def replay(mode):
    archive = read_receipt(BENCH/'2026-11-21/gamma-vcpu-priority.json.gz',VCPU)
    inputs = read_receipt(BENCH/'2026-11-24/tx-offload-bql-readbacks.json.gz',SUPPLEMENT)[mode]
    source = archive['phases'][mode+'-trials']['runs']
    scope = archive['scopes']['fix-'+mode]
    check(scope['boot.json']['cpus']==4 and scope['state']['cpuset.cpus.effective']=='0-3' and
          scope['image']==archive['binaries']['image_config'] and scope['controller']=='reno','guest scope')
    arms = ['original','software-tso','original-repeat'] if mode=='nic' else ['bql-default','bql-512k']
    if mode=='bql':
        check('bql-512k) echo 524288 >"$bql/limit_max"' in inputs['command'] and
              '/limit_max 1879048192' in inputs['stock-bql'] and 'if i%2==0:order.reverse()' in inputs['driver'],
              'BQL setter, restore control and order')
    rows = []
    summaries = {}
    for arm in arms:
        arm_rows = []
        for i in range(1,3 if mode=='nic' else 5):
            before = ('set-'+arm if i==1 else arm+str(i-1)) if mode=='nic' else f'set-{arm}-{i}'
            after = arm+str(i) if mode=='nic' else f'{arm}-{i}'
            check(inputs[before+'.status'].strip()==inputs[after+'.status'].strip()=='0','command status')
            a,flags = nic_state(inputs[before]); b,more_flags = nic_state(inputs[after])
            check(flags==more_flags and flags['tcp-segmentation-offload']==('off' if arm=='software-tso' else 'on')
                  and flags['generic-segmentation-offload']==flags['generic-receive-offload']=='on','TCP offload state')
            if mode=='nic':
                stock_flags=nic_state(inputs['set-original'])[1]
                actual={k for k in stock_flags if stock_flags[k]!=flags[k]}
                expected={'tcp-segmentation-offload','tx-tcp-segmentation','tx-tcp6-segmentation','tx-tcp-mangleid-segmentation'}
                check(actual==(expected if arm=='software-tso' else set()), 'only TSO and its TCP subfeatures')
            else:
                stock_flags=nic_state(inputs['set-bql-default-1'])[1]
                check(flags==stock_flags, 'unchanged NIC flags across BQL arms')
                check(all(blob.splitlines()[1]=='driver: virtio_net' for blob in (inputs[before],inputs[after])),
                      'no per-round BQL readback between date and driver')
            counters={k:b[k]-a[k] for k in a}
            check(min(counters.values())>=0 and counters['bytes']>0 and counters['packets']>0,'interface continuity')
            r=source[arm][str(i)]; c=r['client']; errors=c['errors'] or []
            check(c['streams']==32 and c['arrivals']==240 and c['period_us']==25000 and
                  r['clean']==clean_client(c),'consistent offered work and clean score')
            n=sum('/id"' in e for e in errors)
            check(all('/id"' in e or '/data"' in e or e.startswith('stream ') for e in errors),'classified errors')
            relay_pid=int(re.search(r'pid = (\d+)',scope['role'])[1])
            check(len(r['before']['tasks'])==2 and r['before']['tasks'][1]['pid']==relay_pid, 'process identity')
            cost={}
            for role,task in zip(('vmm','relay'),r['before']['tasks']):
                d=process_delta(r['before'],r['after'],task['pid'])
                cost[role]=dict(cpu_s=d['cpu_s'],runnable_s=d['runnable_s'],observer_s=d['sample_seconds'],
                                cpu_s_per_scored_gib=d['cpu_s']/(c['bytes']/GIB) if r['clean'] else None)
            row=dict(block=i, arm=arm, epoch_ns=r['before']['epoch_ns'],clean=r['clean'], fresh_errors=n,
                     bulk_errors=len(errors)-n,bulk_reopens=c['reopened'],throughput_mib_s=c['mib_s'],
                     p95_ms=c['fresh_p95_us']/1000,p99_ms=c['fresh_p99_us']/1000,tx_interface=counters,
                     bytes_per_tx_packet=counters['bytes']/counters['packets'],
                     tx_kicks_per_interface_gib=counters['tx0_kicks']/(counters['bytes']/GIB),process=cost)
            arm_rows.append(row)
        rows.extend(arm_rows)
        clean=[r for r in arm_rows if r['clean']]
        summaries[arm]=dict(attempts=len(arm_rows),clean=len(clean),pass_75ms=sum(r['p95_ms']<=75 for r in clean),
                            fresh_errors=sum(r['fresh_errors'] for r in arm_rows),reopens=sum(r['bulk_reopens'] for r in arm_rows),
                            medians={k:median(r[k] for r in clean) if clean else None for k in
                                     ('p95_ms','p99_ms','throughput_mib_s','bytes_per_tx_packet','tx_kicks_per_interface_gib')})
    rows.sort(key=lambda r:r['epoch_ns'])
    order=[r['arm'] for r in rows]
    if mode=='bql':
        check(order==['bql-512k','bql-default','bql-default','bql-512k']*2,'balanced BQL ordering')
    else:
        check(order==[a for a in arms for _ in range(2)],'original, off, restored order')
    return dict(id='231.01' if mode=='nic' else '231.08', date='2026-11-24',tier='offline replay of archived VM first attempts',
                source='b30c57f8c97d112fb57dfd5588b6e8da9601e583',archive_sha256=VCPU,readbacks_sha256=SUPPLEMENT,
                boot=scope['boot.json']['boot'],vm=scope['vm'],image=scope['image'],client=archive['binaries']['client'],
                workload='32 bulk streams, 240 fixed arrivals in six seconds, all first attempts. Host process counters '
                         'span setup and drain. Interface byte and packet counters are driver-reported. No on-wire capture.',
                comparison=('Guest TCP segmentation on, then off, then restored; GSO/GRO both on. Two attempts per '
                            'sequential phase on one boot; no paired interval.' if mode=='nic' else
                            'Guest tx-0 BQL limit_max write of 524288 vs restoring stock 1879048192. All writes exited '
                            'successfully. The snapshots lack post-write limit_max/inflight/limit values. Four '
                            'alternating blocks; zero clean controls, so no qualified throughput ratio. BQL here is '
                            'driver TX queue control, distinct from fq/socket buffer controls.'),
                summary=summaries,rows=rows, verdict=(
                    'Retain TSO for the candidate control. Disabling it sharply reduced receiver throughput and '
                    'changed guest packet geometry and notification work on this archived boot. The restored arm '
                    'still lost delivery once. Repeat only within a separately qualified live comparison.'
                    if mode=='nic' else
                    'Prioritize a bounded 512 KiB request for replication. Record actual limit_max, inflight, and '
                    'limit using explicit paths at each boundary. All four stock attempts lost delivery. '
                    'No jointly clean throughput ratio or effective queue size can be inferred.'),
                uncertainty='Short single-guest screen; no independent-boot interval.',
                benchmark_snapshot='ad0646d6292076b6ddf7647f2dc806d785d8f8fb',
                replay_base='2ccda8507355b8220258db2ce8160f3113d3e1ff')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('mode',choices=('nic','bql'))
    print(json.dumps(replay(p.parse_args().mode),indent=2,allow_nan=False))
