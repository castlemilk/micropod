"""Replay the historical same-primary-gateway VM prototype at two and four data owners."""
import gzip
import hashlib
import itertools
import json
import math
import statistics
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ARCHIVE = HERE.parents[1] / '2026-11-21/gamma-vnic.json.gz'
ARCHIVE_SHA = '2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f'
ARCHIVE_COMMIT = '4f887ba5d28f47fa37d4bd0a2d89cd0914d74754'
ORDER = ['original', 'split1', 'split2', 'split4', 'private1', 'private2', 'private4']
EXPECTED_BYTES = 32 * 8 * 1024**2


def digest(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, context):
    if not condition:
        raise ValueError(context)


def check_round(raw, block, workers, cohort):
    key = f'lane-screen/{block}-split{workers}-{cohort}'
    obs = raw[key + '.json']
    require(raw[key + '.status'] == 0 and raw[key + '.err'] is None, key)
    require(obs['first_response_barrier'] and obs['warm'] == (cohort == 'warm'), key)
    require(obs['streams'] == 32 and obs['transfers_per_stream'] == 1 and obs['bytes'] == EXPECTED_BYTES, key)
    require(obs['unexpected_reconnects'] == 0 and obs['initial_connection_mismatches'] == 0, key)
    phases = obs['stream_phases']
    require(len(phases) == 32, key)
    for phase in phases:
        require(0 < phase['connected_us'] <= phase['request_written_us'] <= phase['first_header_us']
                <= phase['first_body_complete_us'] <= phase['complete_us'], key)
    last_header = max(p['first_header_us'] for p in phases)
    last_body = max(p['complete_us'] for p in phases)
    require(last_body == obs['elapsed_us'] and min(p['first_body_complete_us'] for p in phases) >= last_header, key)
    rate = EXPECTED_BYTES / 1024**2 / (last_body / 1e6)
    require(math.isclose(rate, obs['mib_s'], rel_tol=1e-12), key)
    return dict(key=key, body_bytes=obs['bytes'], elapsed_us=last_body, mib_s=rate,
                last_header_us=last_header, after_last_header_us=last_body - last_header)


def uncertainty(changes):
    # Every ordered bootstrap sample of the six paired block differences.
    samples = sorted(statistics.median(p) for p in itertools.product(changes, repeat=len(changes)))
    return [samples[math.ceil(len(samples) * p) - 1] for p in (.025, .975)]


def summarize(pairs):
    changes = [100 * (row['four']['mib_s'] / row['two']['mib_s'] - 1) for row in pairs]
    medians = {key: statistics.median(row[key]['mib_s'] for row in pairs) for key in ('two', 'four')}
    phase_delta = {key: statistics.median(row['four'][key] - row['two'][key] for row in pairs)
                   for key in ('last_header_us', 'after_last_header_us')}
    return dict(median_arm_mib_s=medians, paired_change_percent=statistics.median(changes),
                paired_interval_percent=uncertainty(changes), four_worker_wins=sum(x > 0 for x in changes),
                paired_phase_delta_us=phase_delta, common_blocks=len(pairs))


def main():
    packed = ARCHIVE.read_bytes()
    require(digest(packed) == ARCHIVE_SHA, 'archive digest')
    archive = json.loads(gzip.decompress(packed))
    raw = archive['raw']
    drivers = archive['experiment_drivers']
    require('keys=(' + ' '.join(ORDER) + ')' in drivers['pilot.sh'], 'driver case order')
    require('key=${keys[$(((i+r)%7))]}' in drivers['pilot.sh'], 'driver rotation')
    source_hashes = {}
    for source in ('scripts/netbench/main.go', 'Sources/CPublishedTCP/PublishedTCP.c'):
        candidate = subprocess.check_output(['git', '-C', HERE, 'show', f'{ARCHIVE_COMMIT}:{source}'])
        source_hashes[source] = digest(candidate)
        require(source_hashes[source] == archive['sources_sha256'][source], source)
    for source in ('lanes.c', 'pilot.sh'):
        source_hashes[source] = digest(drivers[source].encode())
    require(raw['links.boot']['cpus'] == archive['hardware']['worker_vcpus'] == 4, 'vCPUs')
    require(raw['links.boot']['guestAddress'] == raw['links.target'].split()[0], 'guest address')
    result = dict(id='230.02', evidence='archived Gamma VM burst replay', archive_sha256=ARCHIVE_SHA,
                  archive_commit=ARCHIVE_COMMIT, source_sha256=source_hashes,
                  client_sha256=archive['binaries_sha256']['netbench-shapes'], boot=raw['links.boot']['boot'],
                  vcpus=raw['links.boot']['cpus'], instance=raw['links.boot']['instance'],
                  container_id=raw['links.id'], marker=raw['links.name'], target=raw['links.target'], cohorts={})
    for cohort in ('fresh', 'warm'):
        pairs = []
        for block in range(6):
            order = ORDER[block:] + ORDER[:block]
            pairs.append(dict(block=block, first='two' if order.index('split2') < order.index('split4') else 'four',
                              two=check_round(raw, block, 2, cohort), four=check_round(raw, block, 4, cohort)))
        result['cohorts'][cohort] = dict(pairs=pairs, summary=summarize(pairs))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
