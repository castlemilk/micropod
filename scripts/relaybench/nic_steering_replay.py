"""Reconcile kernel receive steering and send segmentation with retained guest and client observations."""
import argparse
import json
import re
from statistics import median

from gamma_contrasts import ROOT, GIB, read_receipt
from guest_tx_replay import check, paired_pct

BENCH = ROOT / "docs/benchmarks"
ARCHIVE = BENCH / '2026-11-21'
NIC = '2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f'
KERNEL = '9b1459f8b56a67874e4c21e62c19ed6f9373dbe2ed5a2791e309fe14fc9d7ad5'
VCPU = '066cd4071f3f926a228d87310f6d7b6f361c38f07c7a8240aa09a57f03f201e4'
READBACK = '0855463378443a2ab07bd4bc04905d433bddc0aa53baa26ee6b74448667dde48'


def steering():
    kernel = read_receipt(ARCHIVE / 'gamma-published-kernel.json.gz', KERNEL)
    trial = kernel['experiments']['receive_steering']
    check(len(trial['restore']) == len(trial['distribute']) == 6, 'complete six-block screen')
    pairs = []
    for control, candidate in zip(trial['restore'], trial['distribute']):
        arms = {}
        for name, data in [('restore', control), ('distribute', candidate)]:
            counts = data['net_rx_softirqs_per_cpu']
            check(len(counts) == 4 and min(counts) > 0 and data['parallel_barrier'] and
                  data['parallel_streams'] == 32 and data['requests'] == 150 and
                  len(data['parallel_bursts_mib_s']) == 5 and
                  median(data['parallel_bursts_mib_s']) == data['parallel_mib_s'], 'matched work, CPU counters and rate')
            arms[name] = dict(rx_softirqs=counts, total=sum(counts), busiest_share=max(counts)/sum(counts),
                              rate_mib_s=data['parallel_mib_s'], fresh_p95_us=data['fresh_p95_us'],
                              fresh_p99_us=data['fresh_p99_us'])
        pairs.append(arms)
    summary = {key: paired_pct([p['distribute'][key]/p['restore'][key] for p in pairs])
               for key in ['total', 'busiest_share', 'rate_mib_s']}
    medians = {arm: {k: median(p[arm][k] for p in pairs) for k in summary.keys() | {'fresh_p95_us','fresh_p99_us'}}
               for arm in ('restore','distribute')}
    prof = read_receipt(ARCHIVE / 'gamma-vnic.json.gz', NIC)
    raw = prof['raw']
    profiles = {}
    for arm in ('stock','rps'):
        key = 'bpf-' + arm + '-exact/'
        maps = {k: v for o in raw[key+'maps'] if o['type'] == 'map' for k,v in o['data'].items()}
        c = raw[key+'bulk.json']
        check(raw[key+'status'] == 0 and not raw[key+'bulk.err'] and not raw[key+'trace.err']
              and c['bytes'] == 6*GIB and c['streams'] == 32 and c['reopened_connections'] == 0, 'profile qualification')
        profiles[arm] = dict(rx_calls_by_cpu=maps['@rx_calls'], tx_bytes_by_cpu=maps['@tx_bytes'],
                             service_tcp_retransmit_events=maps['@tcp_retransmits'], payload_bytes=c['bytes'],
                             retransmit_events_per_payload_gib=maps['@tcp_retransmits']/6)
    return dict(id='237.05', tier='offline replay of archived VM measurements', kernel_archive_sha256=KERNEL,
                kernel_archive_revision='52d67399aad63ed5935c8a615727379d3f1a3636', binaries=kernel['sha256'],
                separate_profile_archive_sha256=NIC, separate_profile_source=prof['parent_commit'],
                work='Six archived alternating restore/distribute blocks, 32-stream synchronized bursts; idle fresh separate.',
                pairs=pairs, medians=medians, paired_pct=summary, separate_6gib_profile=profiles,
                limits='NET_RX softirq entries measure calls, not CPU time or packets. One separate traced transfer per arm cannot establish a causal retransmission effect. Burst receipt has no loaded fresh tail or first-attempt loss ledger. Bootstrap resamples complete pairs.')


def snapshot(text):
    counts = re.search(r'^\s*\d+:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+.*\bvirtio1$', text, re.M)
    return dict(gso_max_size=int(re.search(r'\bgso_max_size (\d+)', text)[1]),
                gso_ipv4_max_size=int(re.search(r'\bgso_ipv4_max_size (\d+)', text)[1]),
                tso=re.search(r'^tcp-segmentation-offload: (\w+)',text,re.M)[1],
                tx_timeouts=int(re.search(r'^\s*tx0_tx_timeouts: (\d+)',text,re.M)[1]),
                irq_cpus=list(map(int,counts.groups())))


def gso():
    archive = read_receipt(ARCHIVE / 'gamma-vcpu-priority.json.gz',VCPU)
    supplemental = read_receipt(BENCH / '2026-11-24/nic-gso-readbacks.json.gz',READBACK)
    check("('irq-all','all-cpus'),('gso-cap','small-gso')" in supplemental['nic-trials.py'] and
          'gso-cap) ip link set dev eth1 gso_max_size 16384' in supplemental['observe-nic.sh'], 'adjacent settings')
    runs = archive['phases']['nic-trials']['runs']
    rows = []
    for arm,cap in [('all-cpus',65536), ('small-gso',16384)]:
        previous = 'set-'+arm
        for i in range(1,3):
            label = arm+str(i)
            a,b = [snapshot(supplemental[n]) for n in (previous,label)]
            for n,facts in ((previous,a),(label,b)):
                check(supplemental[n+'.status'].strip()=='0' and facts['tso']=='on' and
                      facts['gso_max_size']==facts['gso_ipv4_max_size']==cap, 'cap and TSO readback')
            rec = runs[arm][str(i)]
            c = rec['client']
            errors = c['errors'] or []
            check(c['arrivals']==240 and c['streams']==32 and c['period_us']==25000 and
                  all('/id"' in e for e in errors) and rec['clean']==(not errors and not c['reopened']) and
                  len(c['per_stream_bytes']) == 32 and c['bytes']==sum(c['per_stream_bytes']), 'offer and complete counts')
            check(not rows or rec['before']['epoch_ns']>=rows[-1]['end_ns'], 'chronological arms')
            rows.append(dict(arm=arm, round=i, start_ns=rec['before']['epoch_ns'],end_ns=rec['after']['epoch_ns'],
                             before=a, after=b, irq_delta=[y-x for x,y in zip(a['irq_cpus'],b['irq_cpus'])],
                             tx_timeout_delta=b['tx_timeouts']-a['tx_timeouts'],fresh_errors=len(errors),
                             bulk_reopens=c['reopened'],delivered_bytes=c['bytes'],mib_s=c['mib_s'],
                             success_p95_ms=c['fresh_p95_us']/1000,success_p99_ms=c['fresh_p99_us']/1000,
                             clean=rec['clean'],pass_delivery_and_tail=rec['clean'] and c['fresh_p95_us']<=75000))
            previous=label
    return dict(id='231.01', tier='offline replay of archived VM measurements',source='b30c57f8c97d112fb57dfd5588b6e8da9601e583',
                archive_sha256=VCPU,readbacks_sha256=READBACK,guest=archive['scopes']['fix-nic']['vm'],
                image=archive['scopes']['fix-nic']['image'],work='Two sequential blocks per arm on same 4-vCPU Reno guest. 32 bulk streams with 240 fresh offers every 25 ms over 6s.',
                rows=rows,limits='One sequential change after earlier watchdogs. No common clean pair or matched throughput interval; successful-request tails exclude failures. IRQ mask request unchanged and raw IRQ counters measure observed delivery.')


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('id',choices=['237.05','231.01'])
    args=parser.parse_args()
    print(json.dumps(steering() if args.id=='237.05' else gso(), indent=2, sort_keys=True))
