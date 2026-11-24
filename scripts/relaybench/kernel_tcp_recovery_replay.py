"""Compare two retained kernel networking choices, with attempt-level delivery checks."""
import argparse
import hashlib
import json
from statistics import median

from gamma_contrasts import ROOT, clean_client, paired_median_interval, process_work, read_receipt, stream_rates

DIRECTORY = ROOT / 'docs/benchmarks/2026-11-21'
CASES = {
    '231.07': ('gamma-direct-macvlan.json.gz', 'cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976'),
    '231.08': ('gamma-vnic.json.gz', '2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f'),
}


def paired(rows, control, candidate, fields):
    result = {}
    for field in fields:
        a = [r[control][field] for r in rows]
        b = [r[candidate][field] for r in rows]
        ratios = [y / x for x, y in zip(a, b)]
        result[field] = dict(control_median=median(a), candidate_median=median(b),
                             paired_median_ratio=median(ratios), ci95=paired_median_interval(ratios))
    return result


def congestion(source):
    control, candidate = 'full-reno', 'full-bbr'
    attempts = source['records']['tuning']
    assert sorted(map(int, attempts)) == list(range(1, 11))
    scopes = source['records']['workers']
    # The full-Reno scope was rebuilt after tuning. Bind its screen-era PIDs.
    workers = {control: scopes['screen-state-full-reno'], candidate: scopes[candidate]}
    for arm in (control, candidate):
        w = workers[arm]
        cc = arm.split('-')[1]
        assert w['controller'] == cc
        assert any(r['Congctl'] == cc and r['Dst']['Mask'] == '/////w==' for r in w['routes.json']['mppub0'])
        assert w['boot.json']['cpus'] == 4 and w['state']['cpu.max'] == '400000 100000'
        assert w['state']['cpuset.cpus.effective'] == '0-3' and w['image'] == 'sha256:' + source['image_config_sha256']
    assert workers[control]['vm'] == workers[candidate]['vm']
    rows = []
    for i in range(1, 11):
        block = attempts[str(i)]
        row = dict(block=i, order=block['order'])
        for arm in (control, candidate):
            obs = block['engines'][arm]
            c = obs['client']
            assert clean_client(c) and obs['valid']
            metrics = {k: c[k] for k in ('arrivals', 'bytes', 'window_s', 'mib_s', 'fresh_p95_us', 'fresh_p99_us', 'reopened', 'errors')}
            for role in ('relay', 'vmm'):
                work = process_work(obs['before'], obs['after'], int(workers[arm][role]), c['bytes'])
                assert work['sample_seconds'] >= c['window_s'] and work['wait_s'] >= 0
                for k in ('cpu_s_per_gib', 'wait_s_per_s', 'cpu_s', 'runnable_s', 'sample_seconds'):
                    metrics[role+'_'+k] = work[k]
            row[arm] = metrics
        rows.append(row)
    fields = ('mib_s', 'relay_cpu_s_per_gib', 'vmm_cpu_s_per_gib', 'relay_wait_s_per_s',
              'vmm_wait_s_per_s', 'fresh_p95_us', 'fresh_p99_us')
    return dict(original_revision=source['baseline_commit'], kernel_image=source['kernels']['full']['image_sha256'],
                scopes={a: {k: workers[a][k] for k in ('name', 'relay', 'vmm', 'controller', 'vm')} for a in workers},
                service_image=source['image_config_sha256'], fixed_client=source['sha256']['fixed'],
                limits='Separate warm VMs. Whole-invocation process counters divided by scored GiB. '
                       'Wait is runnable off-CPU thread-seconds per second of observer wall time. '
                       'Unknown whole-invocation payload prevents exact aligned CPU/GiB.',
                rows=rows, summary=paired(rows, control, candidate, fields),
                passes_75ms={a:sum(r[a]['fresh_p95_us'] <= 75000 for r in rows) for a in (control,candidate)},
                faster_and_75ms=sum(r[candidate]['mib_s'] > r[control]['mib_s'] and
                                    r[candidate]['fresh_p95_us'] <= 75000 for r in rows))


def counters(s):
    lines = s.splitlines()
    header, values = [line.split()[1:] for line in lines if line.startswith('TcpExt:')]
    return dict(zip(header, map(int, values), strict=True))


def recovery(source):
    raw = source['raw']
    control, candidate = 'rto200', 'rto20'
    fields = ('burst_max_ms', 'burst_median_ms', 'mib_s', 'fresh_p95_ms', 'fresh_p99_ms')
    rows = []
    for i in range(8):
        row = dict(block=i)
        for arm in (control, candidate):
            p = f'rto/{i}-{arm}'
            state = raw[p+'.state']
            assert 'congctl reno' in state and (('rto_min lock 20ms' in state) if arm == candidate else ('rto_min' not in state))
            assert raw[p+'.burst.status'] == raw[p+'.mixed.status'] == 0
            b, c = raw[p+'.burst'], raw[p+'.mixed']
            assert b['parallel_streams'] == c['streams'] == 32 and b['parallel_barrier']
            assert b['requests'] == 120 and b['bulk_bytes'] == 8*8*1024**2
            assert c['fresh']['iterations'] == 160 and c['fresh']['incomplete_phase_samples'] == c['reopened_connections'] == 0
            stream_rates({'per_stream_bytes': c['overlap_bytes_per_stream'], 'bytes': c['overlap_bytes']},
                         c['overlap_s'], c['overlap_mib_s'])
            times = [1000 * 256 / x for x in b['parallel_bursts_mib_s']]
            assert len(times) == 3
            before, after = (counters(raw[p+suffix]['/proc/net/netstat']) for suffix in ('.before', '.after-burst'))
            delta = {k:after[k]-before[k] for k in ('TCPTimeouts','TCPLossProbes','TCPSynRetrans','TCPSpuriousRTOs')}
            assert min(delta.values()) >= 0
            row[arm] = dict(route=state, burst_elapsed_ms=times, burst_max_ms=max(times), burst_median_ms=median(times),
                            counters=delta, mib_s=c['overlap_mib_s'], fresh_p95_ms=c['fresh']['complete_ns']['p95']/1e6,
                            fresh_p99_ms=c['fresh']['complete_ns']['p99']/1e6, reopens=c['reopened_connections'],
                            fresh_samples=c['fresh']['iterations'], scored_bytes=c['overlap_bytes'])
        rows.append(row)
    # Conditions refer only to the original control. Do not select pairs on the candidate's outcome.
    events = {}
    for label, positive in [('timeout', True), ('no_timeout', False)]:
        group = [r for r in rows if bool(r[control]['counters']['TCPTimeouts']) == positive]
        events[label] = dict(blocks=[r['block'] for r in group],
                             lower_candidate_worst_burst=sum(r[candidate]['burst_max_ms'] < r[control]['burst_max_ms'] for r in group),
                             control_median_max_ms=median(r[control]['burst_max_ms'] for r in group),
                             candidate_median_max_ms=median(r[candidate]['burst_max_ms'] for r in group))
    return dict(original_revision=source['parent_commit'], client=source['binaries_sha256']['netbench-shapes'],
                configuration_driver_sha256=hashlib.sha256(source['experiment_drivers']['rto.sh'].encode()).hexdigest(),
                limits='Default Reno route vs same route with explicit 20 ms RTO floor. A counter interval '
                       'includes the full burst invocation (single/fresh/keepalive and three synchronized '
                       '32-stream bursts), not individual recovery events. Subgroups describe the control, '
                       'not a causal RTO effect. 160 fresh requests were closed-loop in a separate mixed invocation.',
                rows=rows, summary=paired(rows, control, candidate, fields), control_timeout_split=events)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('direction', choices=CASES)
    direction = parser.parse_args().direction
    filename, sha = CASES[direction]
    source = read_receipt(DIRECTORY / filename, sha)
    result = (congestion if direction == '231.07' else recovery)(source)
    print(json.dumps(dict(direction=direction, archive=filename, archive_sha256=sha,
                          interval='Block bootstrap of median paired ratios, 10,000 resamples, seed 7317.',
                          **result), indent=2, allow_nan=False))
