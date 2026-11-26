"""Read-only replay of adjacent guest IRQ affinity requests on the same publication NIC."""
import json
import math
import re
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
root = here.parents[3]
sys.path.insert(0, str(root / 'scripts/relaybench'))
from gamma_contrasts import read_receipt
from nic_steering_replay import READBACK, VCPU, snapshot

archive = read_receipt(root/'docs/benchmarks/2026-11-21/gamma-vcpu-priority.json.gz', VCPU)
supp = read_receipt(here.parent/'nic-gso-readbacks.json.gz', READBACK)
supp.update(read_receipt(here/'first-cpu-readbacks.json.gz',
    '9871a79f7245bbf356f73af0d3cec9c50db2d0c93e07aa6b8c02d49939edf4f6'))
assert "('irq-0','first-cpu'),('irq-all','all-cpus')" in supp['nic-trials.py']
for action, mask in [('irq-0','0'),('irq-all','0-3')]:
    assert f'{action}) echo {mask} >"/proc/irq/$irq/smp_affinity_list"' in supp['observe-nic.sh']
assert archive['scopes']['fix-nic']['controller'] == 'reno'
rows = []
for arm in ('first-cpu','all-cpus'):
    runs = archive['phases']['nic-trials']['runs'][arm]
    assert set(runs) == {'1','2'}
    for i in (1,2):
        names = ('set-'+arm if i==1 else arm+'1', arm+str(i))
        counters = []
        for name in names:
            assert supp[name+'.status'].strip() == '0'
            s = snapshot(supp[name])
            assert s['tso']=='on' and s['gso_max_size']==s['gso_ipv4_max_size']==65536
            for side in ('RX','TX'):
                m=re.search(r'^\s*'+side+r':\s+bytes packets errors dropped[^\n]*\n\s*([\d ]+)',supp[name],re.M)
                s[side+'_drops'] = int(m[1].split()[3])
            counters.append(s)
        a,b=counters
        irq = [end-start for start,end in zip(a['irq_cpus'],b['irq_cpus'])]
        obs=runs[str(i)]
        c=obs['client']
        assert not obs['clean'] and c['streams']==32 and c['arrivals']==240 and c['period_us']==25000
        assert len(c['per_stream_bytes'])==32 and sum(c['per_stream_bytes'])==c['bytes']
        assert math.isclose(c['bytes']/2**20/c['window_s'], c['mib_s'])
        assert not rows or rows[-1]['end_ns'] <= obs['before']['epoch_ns']
        errors=c['errors']
        assert all('/id"' in e or '/data"' in e or e.startswith('stream ') for e in errors)
        rows.append(dict(arm=arm,attempt=i,irq_deltas=irq,timeout_delta=b['tx_timeouts']-a['tx_timeouts'],
                         rx_drops=b['RX_drops']-a['RX_drops'],tx_drops=b['TX_drops']-a['TX_drops'],
                         bytes=c['bytes'],mib_s=c['mib_s'],fresh_get_errors=sum('/id"' in e for e in errors),
                         bulk_reopens=c['reopened'],raw_p95_us=c['fresh_p95_us'],raw_p99_us=c['fresh_p99_us'],
                         start_ns=obs['before']['epoch_ns'],end_ns=obs['after']['epoch_ns']))
print(json.dumps(dict(direction='237.05',archive_sha256=VCPU,rows=rows),indent=2))
