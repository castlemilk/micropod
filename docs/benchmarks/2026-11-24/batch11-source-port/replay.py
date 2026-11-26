"""Replay the two historical source-port policies. No sockets or benchmark launches."""
from hashlib import sha256
from pathlib import Path
from random import Random
from statistics import median, quantiles
import gzip
import json
import re

HERE = Path(__file__).resolve().parent
ARMS = ['serial', 'random']

def verified(path, sha):
    b = path.read_bytes()
    assert sha256(b).hexdigest() == sha
    return json.loads(gzip.decompress(b))

def compare(pairs):
    groups = [[row for row in pairs if row[0]==first] for first in ARMS]
    ratios = [100*(b/a-1) for _,a,b in pairs]
    rng = Random(23012)
    samples = []
    for _ in range(10000):
        draws = [v for group in groups for v in rng.choices(group,k=len(group))]
        samples.append(median(100*(b/a-1) for _,a,b in draws))
    q = quantiles(samples,n=40,method='inclusive')
    return dict(common_control=median(a for _,a,b in pairs),common_candidate=median(b for _,a,b in pairs),
                median_paired_pct=median(ratios),descriptive_ci95_pct=[q[0],q[-1]],
                higher_pairs=sum(b>a for _,a,b in pairs))

def main():
    archive=verified(HERE.parents[1]/'2026-11-21/gamma-published-profile.json.gz',
                     '234f8f89de4462068e31934a8b1fc0ec6ecc93d814dd2da97b13c574481ebe93')
    inputs=verified(HERE/'first-attempt-inputs.json.gz','d0e3e555bfdaa8e6f12087a67451070dd4ef53dfa28b9e825f00b0511b1dad7f')
    for name in ('sources','first','events'):
        assert all(sha256(obj['text'].encode()).hexdigest()==obj['sha256'] for obj in inputs[name].values())
    src=inputs['sources']
    option='    int one=1;\n    if (setsockopt(guest,SOL_SOCKET,SO_RANDOMPORT,&one,sizeof(one))!=0) goto fail;\n'
    candidate=src['probe-random.c']['text']
    assert candidate.count(option)==1 and candidate.replace(option,'').replace('#include <net/if.h>\n','')==src['diagnostic.c']['text']
    driver=src['port-selection.sh']['text']
    assert 'micropod-qa/netbench:local -listen :8080 -marker "$name"' in driver
    assert '-requests 380 -streams 32 -bursts 1 -stream-barrier' in driver and 'for r in {1..18}' in driver
    staged=src['stages.go']['text']
    assert 'const size = 8 << 20' in staged and 'log.Fatal("short parallel response")' in staged
    records=archive['source_port_trials']; rows=[]; counts={}
    for a in ARMS:
        assert len(records[a]['attempts'])==18
        assert records[a]['local_address_errors']==[s for s in inputs['events'][a]['text'].splitlines() if 'errno=49' in s]
        counts[a]=dict(finished=0,initial_identity_failures=0,fresh_failures=0,
                       fresh_completed=0,synchronized_burst_bytes=0,
                       relay_errno49_log_lines=len(records[a]['local_address_errors']))
    orders=['pinned random serial','serial pinned random','random serial pinned']
    for i in range(1,19):
        order=orders[i%3]
        assert f'order="{order}"' in driver
        pair=[k for k in order.split() if k in ARMS]
        arms={}
        end={}
        for a in ARMS:
            key=f'{i}-{a}'; out=inputs['first'][key+'.json']; err=inputs['first'][key+'.err']
            end[a]=max(out['mtime_ns'],err['mtime_ns'])
            item=records[a]['attempts'][i-1]; count=counts[a]
            if 'work' in item:
                raw=item['work']
                assert err['text']=='' and json.loads(out['text'])==raw
                assert raw['parallel_barrier'] and raw['parallel_streams']==32 and raw['requests']==380
                assert raw['parallel_bursts_mib_s']==[raw['parallel_mib_s']] and raw['bulk_bytes']==64*2**20
                arms[a]=dict(finished=True,burst_mib_s=raw['parallel_mib_s'],fresh_p95_ms=raw['fresh_p95_us']/1000,
                             fresh_p99_ms=raw['fresh_p99_us']/1000)
                count['finished']+=1; count['fresh_completed']+=raw['requests']; count['synchronized_burst_bytes']+=32*8*2**20
            else:
                assert not out['text'] and err['text'].strip()==item['error']
                failure=re.search(r'phase=(initial|fresh) sample=(\d+)',item['error'])
                assert failure
                stage, ordinal = failure.group(1), int(failure.group(2))
                if stage=='fresh':
                    count['fresh_failures']+=1; count['fresh_completed']+=ordinal
                else:
                    assert ordinal==0; count['initial_identity_failures']+=1
                arms[a]=dict(finished=False,stage=stage,ordinal=ordinal,
                             error='connect_address_unavailable' if "can't assign requested address" in item['error'] else 'connection_reset')
                assert "can't assign requested address" in item['error'] or 'reset by peer' in item['error']
        assert end[pair[0]]<=end[pair[1]]
        rows.append(dict(block=i,first=pair[0],arms=arms))
    complete=[r for r in rows if all(r['arms'][a]['finished'] for a in ARMS)]
    summaries={k:compare([(r['first'],r['arms']['serial'][k],r['arms']['random'][k]) for r in complete])
               for k in ['burst_mib_s','fresh_p95_ms','fresh_p99_ms']}
    print(json.dumps(dict(date='2026-11-24',stable_id='230.12',analysis_revision='2e9b37c1e68334c443d71b729f0bd6334d824ddd',
                          historical_base='52d67399aad63ed5935c8a615727379d3f1a3636',
                          archive_commit='56b59864d3545cba23cf102cf46cf119f119da08',
                          binary_sha256=inputs['binary_sha256'],source_sha256={k:v['sha256'] for k,v in src.items()},
                          replay_sha256=sha256(Path(__file__).read_bytes()).hexdigest(),counts=counts,blocks=rows,
                          jointly_completed=len(complete),summaries=summaries),indent=2))
if __name__=='__main__':
    main()
