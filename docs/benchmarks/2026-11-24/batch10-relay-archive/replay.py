"""Score receiver bytes for matched zero-vs-50 us follow-up polls, retaining all first attempts."""
from hashlib import sha256
from itertools import product
import gzip
import json
import math
from pathlib import Path
from statistics import median, quantiles

HERE = Path(__file__).resolve().parent
ARCHIVE = HERE.parents[1] / '2026-11-21/gamma-published-profile.json.gz'

def read_inputs(path, expected):
    encoded = path.read_bytes()
    assert sha256(encoded).hexdigest() == expected
    return json.loads(gzip.decompress(encoded))

def compare(pairs):
    ratios = [100*(b/a - 1) for a,b in pairs]
    resampled = [median(block) for block in product(ratios, repeat=len(ratios))]
    bounds = quantiles(resampled, n=40, method="inclusive")
    return dict(control=median(a for a,b in pairs), candidate=median(b for a,b in pairs),
                paired_pct=median(ratios), descriptive_ci95_pct=[bounds[0],bounds[-1]],
                larger_pairs=sum(b>a for a,b in pairs))

def main():
    original = read_inputs(ARCHIVE, '234f8f89de4462068e31934a8b1fc0ec6ecc93d814dd2da97b13c574481ebe93')
    inputs = read_inputs(HERE/'hot-wait-inputs.json.gz','127e7b6d01864139a7dc7da861f4d7ef463f3e9a7a8288f0e991bf6134f3cfcc')
    for obj in list(inputs['source'].values()) + list(inputs['first'].values()):
        assert sha256(obj['text'].encode()).hexdigest() == obj['sha256']
    script=inputs['source']['fixture/probe-drain.sh']['text']
    assert '2)src=hot.c;ns=0;;3)src=hot.c;ns=50000' in script
    assert 'for i in $order' in script and 'set -euo pipefail' in script
    assert 'target=$(cat results/base/direct)' in script and 'marker=$(cat results/base/name)' in script
    hot = inputs['source']['fixture/hot.c']['text']
    assert hot.count('WAIT_NS')==1 and 'drain_batch(r, WAIT_NS);' in hot
    assert 'count >= 65536' in hot and 'i<4 && r->bulk_ready' in hot and '-start<200000' in hot
    client = inputs['source']['burst/src/scripts/netbench/main.go']['text']
    assert 'const size = 8 << 20' in client and 'if get(batch, "/data", io.Discard) != size' in client
    assert original['sha256']['benchmark_client'] == inputs['binary_sha256']['netbench-shapes']
    assert original['sha256']['profiling_client'] == inputs['binary_sha256']['netbench-fixed']
    orders = ['1 2 3','2 3 1','3 1 2','3 2 1','1 3 2','2 1 3']
    rows=[]
    for i,entry in enumerate(original['hot_drain_trials']):
        r=i+1
        assert entry['round']==r and f'{r}) order="{orders[i]}"' in script.replace(')order=',') order=')
        arms={}
        for arm in ('2','3'):
            stored = entry['variants'][arm]
            bulk = stored['sustained_single']; burst = stored['burst_test']
            for ext,obj in [('json',bulk),('bursts',burst)]:
                assert obj == json.loads(inputs['first'][f'{r}-{arm}.{ext}']['text'])
            assert (bulk['streams'],bulk['bytes'],bulk['iterations'],bulk['reopened_connections'])==(1,768*2**20,96,0)
            assert math.isclose(bulk['mib_s'],768/bulk['elapsed_s'])
            assert burst['parallel_barrier'] and burst['requests']==100 and burst['parallel_streams']==32
            rates=burst['parallel_bursts_mib_s']
            assert len(rates)==3 and min(rates)>0 and median(rates)==burst['parallel_mib_s']
            arms[arm]=dict(single_mib_s=bulk['mib_s'],burst_mib_s=median(rates),
                           idle_fresh_p95_ms=burst['fresh_p95_us']/1000,
                           idle_fresh_p99_ms=burst['fresh_p99_us']/1000)
        order=[x for x in orders[i].split() if x in arms]
        assert inputs['first'][f'{r}-{order[0]}.bursts']['mtime_ns'] < inputs['first'][f'{r}-{order[1]}.json']['mtime_ns']
        rows.append(dict(block=r,order=order,arms=arms))
    assert len(rows)==6 and sum(row['order'][0]=='2' for row in rows)==3
    summaries={k:compare([(row['arms']['2'][k],row['arms']['3'][k]) for row in rows]) for k in rows[0]['arms']['2']}
    print(json.dumps(dict(date='2026-11-24',stable_id='230.03',analysis_base='2e9b37c1e68334c443d71b729f0bd6334d824ddd',
                          archive_commit='56b59864d3545cba23cf102cf46cf119f119da08',
                          study_baseline='52d67399aad63ed5935c8a615727379d3f1a3636',
                          source_sha256=inputs['source']['fixture/hot.c']['sha256'],binary_sha256=inputs['binary_sha256'],
                          replay_sha256=sha256(Path(__file__).read_bytes()).hexdigest(),
                          rows=rows,summaries=summaries),indent=2))
if __name__=='__main__':
    main()
