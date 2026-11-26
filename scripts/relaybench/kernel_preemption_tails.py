"""Replay the archived full/lazy Reno holdout against the published fresh-p95 threshold."""
import hashlib
import json
from statistics import median

from gamma_contrasts import ROOT, clean_client, paired_median_interval, read_receipt
from kernel_candidate import config_options


CONTROL = '4dc985b50bbd1e5942020618df4d8dcc2de47483'
ARCHIVE = ROOT / 'docs/benchmarks/2026-11-21/gamma-direct-macvlan.json.gz'
ARCHIVE_SHA = 'cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976'


def replay():
    record = read_receipt(ARCHIVE, ARCHIVE_SHA)
    sets = record['records']['kernel-holdout']
    arms = ('full-reno', 'lazy-reno')
    if set(sets) != {str(i) for i in range(1, 13)}:
        raise ValueError('expected all twelve kernel-holdout blocks')
    configs, metadata, rows = {}, {}, []
    for arm in arms:
        worker = record['records']['holdout_workers'][arm]
        kernel = record['kernels'][arm.split('-')[0]]
        data = kernel['config'].encode()
        if hashlib.sha256(data).hexdigest() != kernel['config_sha256']:
            raise ValueError('archived effective config digest mismatch')
        configs[arm] = config_options(data)
        state = worker['state']
        if (worker['controller'] != 'reno' or worker['boot.json']['cpus'] != 4
                or state['cpu.max'] != '400000 100000' or state['cpuset.cpus.effective'] != '0-3'
                or state['release'] != kernel['release'].strip()
                or worker['image'] != 'sha256:' + record['image_config_sha256']):
            raise ValueError('kernel-holdout fixture mismatch')
        metadata[arm] = dict(release=state['release'], cpus=4, service_quota=state['cpu.max'],
                             cpuset=state['cpuset.cpus.effective'], service_memory=state['memory.max'],
                             guest_visible_bytes=worker['boot.json']['memoryBytes'],
                             kernel_config=kernel['config_sha256'], image=kernel['image_sha256'])
    a, b = configs.values()
    diffs = {k: [a.get(k), b.get(k)] for k in sorted(a.keys() | b.keys()) if a.get(k) != b.get(k)}
    for index in range(1, 13):
        block = sets[str(index)]
        row = {'block': index}
        for arm in arms:
            observed = block['engines'][arm]
            client = observed['client']
            if not observed['valid'] or not clean_client(client):
                raise ValueError(f'unclean historical observation: {index} {arm}')
            row[arm] = {k: client[k] for k in ('mib_s', 'fresh_p95_us', 'fresh_p99_us', 'arrivals',
                                                 'reopened', 'errors', 'bytes', 'window_s')}
        row['lazy_over_full'] = row['lazy-reno']['mib_s'] / row['full-reno']['mib_s']
        rows.append(row)
    cap = 75000
    passing = {arm: [r['block'] for r in rows if r[arm]['fresh_p95_us'] <= cap] for arm in arms}
    common = sorted(set.intersection(*(set(p) for p in passing.values())))
    def aggregate(selected):
        ratios = [r['lazy_over_full'] for r in selected]
        return dict(pairs=len(selected), lazy_wins=sum(r > 1 for r in ratios),
                    median_lazy_over_full=median(ratios), paired_bootstrap_95=paired_median_interval(ratios),
                    median_round_p95_ms={arm: median(r[arm]['fresh_p95_us'] for r in selected) / 1000 for arm in arms},
                    median_round_p99_ms={arm: median(r[arm]['fresh_p99_us'] for r in selected) / 1000 for arm in arms})
    return dict(direction='235.10', date='2026-11-24', tier='offline replay of archived VM inputs',
                analysis_base=CONTROL, original_source_revision=record['baseline_commit'],
                archive=ARCHIVE.name, archive_sha256=ARCHIVE_SHA, service_sha256=record['service_sha256'],
                image_config_sha256=record['image_config_sha256'], builds=metadata, config_differences=diffs,
                upstream_rcu={'archive_sha256': record['kernels']['source_sha256'],
                              'member': 'linux-7.3.5/kernel/rcu/Kconfig', 'line': 19,
                              'member_sha256': '9ba10667a4129ea56c62ac3bc54f82563b9c9bfc9725cd7b1d93ba94d4bebaaf',
                              'rule': 'default y if (PREEMPT || PREEMPT_RT || PREEMPT_DYNAMIC)'},
                cpu_and_boot='Full and lazy run separate guests. No new boot or matched peer run.',
                method='Full vs lazy Reno. Retain all 12 original blocks; change only the descriptive eligibility '
                       'filter to require fresh p95 <= 75 ms in each arm of the pair. The filtered median is '
                       'conditional on outcomes. It is not the overall treatment effect.',
                interval='Median paired ratio, 10,000 block bootstrap resamples, seed 7317, indices 250 and 9749.',
                threshold_us=cap, passing_blocks=passing, both_pass=common, all_attempts=aggregate(rows),
                conditional=aggregate([r for r in rows if r['block'] in common]), raw=rows)


if __name__ == '__main__':
    print(json.dumps(replay(), indent=2))
