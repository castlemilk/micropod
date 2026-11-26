"""Check how much of each bulk transfer could overlap the archived fresh-request train."""
import gzip
import hashlib
import itertools
import json
import math
from pathlib import Path
from statistics import median

archive = Path(__file__).resolve().parents[2] / '2026-11-21/gamma-published-profile.json.gz'
payload = archive.read_bytes()
digest = hashlib.sha256(payload).hexdigest()
assert digest == '234f8f89de4462068e31934a8b1fc0ec6ecc93d814dd2da97b13c574481ebe93'
source = json.loads(gzip.decompress(payload))['mixed_fresh_route']
assert source['bulk_route'] == 'published' and source['relay_profile_enabled']
routes = ('published', 'direct')
rows = []
for i, block in enumerate(source['rounds']):
    expected_order = list(routes) if i % 2 == 0 else list(reversed(routes))
    assert block['round'] == i + 1 and block['order'] == expected_order
    row = {}
    for route in routes:
        trial = block['routes'][route]
        bulk, fresh = trial['bulk'], trial['fresh']
        assert trial['exit_code'] == 0 and bulk['reopened_connections'] == 0
        assert bulk['bytes'] == 6 * 2**30 and bulk['streams'] == 32
        assert fresh['iterations'] == 240 and fresh['incomplete_phase_samples'] == 0
        rate = bulk['bytes'] / 2**20 / bulk['elapsed_s']
        assert math.isclose(rate, bulk['mib_s'])
        # Even without absolute timestamps the intersection is bounded by the shorter interval.
        overlap_bound = min(1.0, fresh['elapsed_s'] / bulk['elapsed_s'])
        row[route] = dict(mib_s=rate, bytes=bulk['bytes'], fresh_s=fresh['elapsed_s'],
                          bulk_s=bulk['elapsed_s'], fresh_p95_ms=fresh['complete_ns']['p95']/1e6,
                          fresh_p99_ms=fresh['complete_ns']['p99']/1e6, overlap_upper=overlap_bound)
    rows.append(row)
assert len(rows) == 6
ratios = [r['direct']['mib_s']/r['published']['mib_s'] for r in rows]
bootstrap = sorted(median(s) for s in itertools.product(ratios, repeat=6))
out = dict(archive_sha256=digest, archived_binary_sha256=source['binary_sha256'],
           rows=rows, summary={k:{m:median(r[k][m] for r in rows) for m in rows[0][k]} for k in routes},
           paired_ratio=median(ratios), wins=sum(x > 1 for x in ratios),
           paired_bootstrap_interval=[bootstrap[math.ceil(len(bootstrap)*p)-1] for p in (.025,.975)])
print(json.dumps(out, indent=2, sort_keys=True))
