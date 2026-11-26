"""Compare one negotiated virtio feature at a time on archived publication-NIC trials."""
import argparse
import json
from statistics import median

from gamma_contrasts import GIB, ROOT, clean_client, process_delta, read_receipt

ARCHIVE = ROOT / 'docs/benchmarks/2026-11-21/gamma-vcpu-priority.json.gz'
ARCHIVE_SHA = '066cd4071f3f926a228d87310f6d7b6f361c38f07c7a8240aa09a57f03f201e4'
CONTROL = 'fix-ring-control'
FEATURES = {'event-index': ('fix-ring-event', 29), 'indirect-descriptors': ('fix-ring-direct', 28)}


def read_arm(archive, arm, bit, phase):
    scope = archive['scopes'][arm]
    records = archive['phases'][phase]['runs'][arm]
    bits = archive['kernel'][arm]
    before, after = str(bits['before']), str(bits['after'])
    stock = str(archive['kernel'][CONTROL]['before'])
    if (before != stock or len(before) != len(after) or set(after) != {'0', '1'}
            or bits['filter'] != ('' if bit is None else bit)
            or [i for i, (a, b) in enumerate(zip(before, after)) if a != b] != ([] if bit is None else [bit])
            or (bit is not None and (before[bit], after[bit]) != ('1', '0'))):
        raise ValueError('unexpected negotiated feature bitmap')
    if (scope['controller'] != 'reno' or scope['image'] != archive['binaries']['image_config']
            or scope['boot.json']['cpus'] != 4 or scope['state']['cpu.max'] != '400000 100000'
            or scope['state']['release'] != archive['kernel']['build']['release']
            or scope['state']['cpuset.cpus.effective'] != '0-3' or len(records) != 5):
        raise ValueError('inconsistent setup')
    result = []
    for key, r in sorted(records.items()):
        c = r['client']
        if c['arrivals'] != 240 or c['streams'] != 32 or c['period_us'] != 25000 or r['clean'] != clean_client(c):
            raise ValueError('invalid offered work or clean status')
        errors = c['errors'] or []
        fresh_errors = sum('/id"' in s for s in errors)
        bulk_errors = sum('/data"' in s or s.startswith('stream ') for s in errors)
        if len(errors) != fresh_errors + bulk_errors:
            raise ValueError('unclassified client error')
        tasks = r['before']['tasks']
        if len(tasks) != 2 or f"pid = {tasks[1]['pid']}\n" not in scope['role']:
            raise ValueError('unexpected observer identities')
        costs = {}
        for kind, task in zip(('vmm', 'relay'), tasks):
            d = process_delta(r['before'], r['after'], task['pid'])
            costs[kind] = dict(cpu_s=d['cpu_s'], runnable_s=d['runnable_s'], observer_s=d['sample_seconds'],
                               cpu_s_per_scored_gib=d['cpu_s'] / (c['bytes'] / GIB) if r['clean'] else None)
        result.append(dict(block=int(key), arm=arm, phase=phase, clean=r['clean'], fresh_offers=c['arrivals'],
                           fresh_errors=fresh_errors, bulk_errors=bulk_errors, reopens=c['reopened'],
                           bytes=c['bytes'], mib_s=c['mib_s'], reported_p95_us=c['fresh_p95_us'],
                           reported_p99_us=c['fresh_p99_us'], guardrail_pass=r['clean'] and c['fresh_p95_us'] <= 75000,
                           host_processes=costs))
    return result


def totals(rows):
    clean = [r for r in rows if r['clean']]
    return dict(attempts=len(rows), clean=len(clean), clean_and_p95_pass=sum(r['guardrail_pass'] for r in rows),
                fresh_offers=sum(r['fresh_offers'] for r in rows), fresh_errors=sum(r['fresh_errors'] for r in rows),
                bulk_errors=sum(r['bulk_errors'] for r in rows), bulk_reopens=sum(r['reopens'] for r in rows),
                clean_median_p95_ms=median(r['reported_p95_us']/1000 for r in clean),
                clean_median_p99_ms=median(r['reported_p99_us']/1000 for r in clean))


def replay(feature):
    arm, bit = FEATURES[feature]
    src = read_receipt(ARCHIVE, ARCHIVE_SHA)
    control = read_arm(src, CONTROL, None, 'ring-trials')
    changed = read_arm(src, arm, bit, 'ring-trials')
    common = []
    for a, b in zip(control, changed):
        if a['block'] != b['block']:
            raise ValueError('block mismatch')
        if a['clean'] and b['clean']:
            common.append(dict(block=a['block'], control_mib_s=a['mib_s'], candidate_mib_s=b['mib_s'],
                               ratio=b['mib_s']/a['mib_s'], both_pass=a['guardrail_pass'] and b['guardrail_pass']))
    extra = read_arm(src, arm, bit, 'ring-reliability') if feature == 'event-index' else []
    return dict(date='2026-11-24', id='231.02', tier='offline replay of archived VM first attempts',
                source_base='b30c57f8c97d112fb57dfd5588b6e8da9601e583', archive=ARCHIVE.name,
                archive_sha256=ARCHIVE_SHA, client_sha256=src['binaries']['client'],
                service_image=src['binaries']['image_config'], kernel=src['kernel']['build'],
                changed_feature=feature, changed_bit=bit, control=CONTROL, candidate=arm,
                readbacks={k:{field:str(v) for field,v in src['kernel'][k].items()} for k in (CONTROL,arm)},
                debug_scopes={
                    k:dict(boot=src['scopes'][k]['boot.json']['boot'],vm=src['scopes'][k]['vm'])
                    for k in (CONTROL,arm)}, order=src['phases']['ring-trials']['orders'],
                workload='32 continuing streams with 240 fresh GETs at 25 ms intervals. Separate VMs on the '
                         'same debug kernel. Control also unbound and rebound eth1. Before/after feature masks '
                         'are left-to-right kernel bit strings recorded as digit sequences in the source archive.',
                limits='Dirty-round percentiles include missing request timings. Only clean rounds contribute '
                       'to latency summaries. Host CPU and runnable counters include setup and drain. No '
                       'notification counters. One common clean pair cannot estimate repeatable throughput.',
                summary={'control': totals(control), 'candidate': totals(changed), 'common_clean': common,
                         'unpaired_candidate_followup': totals(extra) if extra else None},
                attempts=control+changed+extra)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('feature', choices=FEATURES)
    print(json.dumps(replay(parser.parse_args().feature), indent=2, allow_nan=False))
