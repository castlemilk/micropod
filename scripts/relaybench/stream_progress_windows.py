"""Reconstruct within-window stream progress from two pinned Gamma diagnostic archives."""
import json
import math
from statistics import median

from chunk_replay import DIRECTORY, MIXED, MIXED_SHA
from gamma_contrasts import MIB, clean_client, read_receipt, stream_rates

PATHS = 'gamma-mixed-path.json.gz'
PATHS_SHA = '09ebe5510401244cd6d299c1d0cf6dd8f88b256bf14b8c2c14f6db3eff61b74a'
GROUPS = (1, 2, 4)


def scored_points(samples, begin, end, counts):
    """Keep full sample intervals inside scoring and record clock/counter boundary skew."""
    if not samples or not samples[0][0] < begin < end < samples[-1][0]:
        raise ValueError('missing warmup or drain samples around the scored window')
    previous = None
    points = []
    for timestamp, counters in samples:
        if (type(timestamp) is not int or len(counters) != 32
                or any(type(x) is not int or x < 0 for x in counters)):
            raise ValueError('malformed stream sample')
        if previous and (timestamp <= previous[0] or any(b < a for a, b in zip(previous[1], counters))):
            raise ValueError('stream counters or sample clock went backwards')
        if timestamp <= begin:
            outer_first = counters
        if timestamp >= end and previous is not None and previous[0] < end:
            outer_last = counters
        if begin <= timestamp <= end:
            points.append((timestamp, counters))
        previous = timestamp, counters
    if len(points) < 2 or len(counts) != 32:
        raise ValueError('incomplete stream observation')
    outer_shortfall = {}
    for i, scored in enumerate(counts):
        inside = points[-1][1][i] - points[0][1][i]
        outside = outer_last[i] - outer_first[i]
        if type(scored) is not int or not 0 <= inside <= scored:
            raise ValueError('interior bytes exceed the scored per-stream total')
        # The original client reads its start counters before the start timestamp and
        # its final counters after the end timestamp. A neighbouring sample can
        # also be stamped before all 32 counters have been read.
        if scored > outside:
            outer_shortfall[str(i)] = scored - outside
    return points, outer_shortfall


def progress(points, group):
    """Factor rate into nonidle duty, advancing stream count, and rate per advancing stream."""
    # Retain any shorter last group so all resolutions cover identical endpoints.
    edges = [*range(0, len(points) - 1, group), len(points) - 1]
    bins = [{'intervals': 0, 'us': 0, 'bytes': 0, 'stream_us': 0} for _ in range(33)]
    longest_idle = idle_run = 0
    for left, right in zip(edges, edges[1:]):
        start, first = points[left]
        end, last = points[right]
        dt = end - start
        moving = sum(a != b for a, b in zip(first, last))
        bucket = bins[moving]
        bucket['intervals'] += 1
        bucket['us'] += dt
        bucket['bytes'] += sum(last) - sum(first)
        bucket['stream_us'] += dt * moving
        idle_run = 0 if moving else idle_run + dt
        longest_idle = max(longest_idle, idle_run)
    elapsed = points[-1][0] - points[0][0]
    active = elapsed - bins[0]['us']
    stream_us = sum(b['stream_us'] for b in bins)
    count = sum(b['bytes'] for b in bins)
    if not active or not count:
        raise ValueError('no observed bulk progress')
    duty = active / elapsed
    breadth = stream_us / active
    rate_per_stream = count / MIB * 1e6 / stream_us
    rate = count / MIB * 1e6 / elapsed
    if not math.isclose(duty * breadth * rate_per_stream, rate, rel_tol=1e-12):
        raise ValueError('decomposed rates do not reconstruct actual delivery')
    ranges = [(0, 0), (1, 4), (5, 16), (17, 31), (32, 32)]
    hist = {f'{lo}-{hi}': {key: sum(b[key] for b in bins[lo:hi+1]) for key in bins[0]}
            for lo, hi in ranges}
    return {'sample_intervals': len(edges) - 1, 'sampled_us': elapsed, 'bytes': count,
            'mib_s': rate, 'progress_fraction': duty, 'moving_streams_during_progress': breadth,
            'mib_s_per_moving_stream': rate_per_stream, 'mib_s_during_progress': rate / duty,
            'longest_consecutive_idle_us': longest_idle,
            'moving_stream_counts': hist}


def analyze(record, kind):
    trace = record['trace']
    if kind == 'paths':
        counts, count = record['overlap_bytes_per_stream'], record['overlap_bytes']
        seconds, rate = record['overlap_s'], record['overlap_mib_s']
        begin, end = trace['overlap_start_us'], trace['overlap_end_us']
        if (trace['omitted_samples'] or trace['sample_period_us'] != 5000 or record['streams'] != 32
                or record['fresh']['iterations'] != 160 or len(trace['fresh']) != 160
                or record['fresh']['incomplete_phase_samples']):
            raise ValueError('incomplete release path workload')
        raw = [(s['at_us'], s['cumulative_bytes']) for s in trace['samples']]
    else:
        counts, count = record['per_stream_bytes'], record['bytes']
        seconds, rate = record['window_s'], record['mib_s']
        begin, end = trace['begin_us'], trace['end_us']
        if (trace['mode'] != kind or record['errors'] not in (None, []) or record['reopened']
                or record['streams'] != 32 or len(trace['fresh']) != 240 or seconds < 6
                or record['period_us'] != 25000 or record['arrivals'] != 240):
            raise ValueError('unexpected fixed-arrival diagnostic offer')
        if kind == 'mixed' and (not clean_client(record) or any(p['Error'] or not p['Done'] for p in trace['fresh'])):
            raise ValueError('dirty mixed workload')
        if kind == 'bulk' and any(p['Done'] or p['Kick'] or p['Error'] for p in trace['fresh']):
            raise ValueError('unexpected fresh request on bulk control')
        raw = [(s['At'], s['Bytes']) for s in trace['samples']]
    stream_rates({'per_stream_bytes': counts, 'bytes': count}, seconds, rate)
    if abs(seconds * 1e6 - (end - begin)) > 1.1:
        raise ValueError('scored interval endpoints disagree with client wall time')
    points, outer_shortfall = scored_points(raw, begin, end, counts)
    groups = {str(n): progress(points, n) for n in GROUPS}
    return {'reported_mib_s': rate, 'scored_us': end - begin, 'scored_bytes': count,
            'bulk_reopens': record['reopened_connections'] if kind == 'paths' else record['reopened'],
            'uncovered_boundary_us': points[0][0] - begin + end - points[-1][0],
            'reported_bytes_above_outer_sample_delta_by_stream': outer_shortfall,
            'interior_byte_coverage': groups['1']['bytes'] / count,
            'median_native_sample_us': median(b[0] - a[0] for a, b in zip(points, points[1:])),
            'max_native_sample_us': max(b[0] - a[0] for a, b in zip(points, points[1:])),
            'groups_of_native_samples': groups}


def replay():
    p = read_receipt(DIRECTORY / PATHS, PATHS_SHA)['records']
    s = read_receipt(DIRECTORY / MIXED, MIXED_SHA)['records']
    rows = {}
    factors = []
    for i in range(1, 4):
        for mode in ('baseline', 'candidate', 'direct', 'orb'):
            k = f'final-trace/{i}-{mode}.json'
            rows[k] = analyze(p[k], 'paths')
        if any(rows[f'final-trace/{i}-{arm}.json']['bulk_reopens'] for arm in ('candidate', 'direct')):
            raise ValueError('reopened bulk stream in release path contrast')
        for n in GROUPS:
            a, b = [rows[f'final-trace/{i}-{arm}.json']['groups_of_native_samples'][str(n)]
                    for arm in ('candidate', 'direct')]
            factors.append({'set': i, 'group': n, 'direct_over_published_mib_s': b['mib_s'] / a['mib_s'],
                            'direct_over_published_duty': b['progress_fraction'] / a['progress_fraction'],
                            'direct_over_published_breadth': b['moving_streams_during_progress'] / a['moving_streams_during_progress'],
                            'direct_over_published_active_stream_rate': b['mib_s_per_moving_stream'] / a['mib_s_per_moving_stream'],
                            'direct_minus_published_nonidle_mib_s': b['mib_s'] - a['mib_s_during_progress']})
    for i in range(1, 5):
        for kind in ('bulk', 'mixed'):
            k = f'sched/{i}-{kind}.json'
            rows[k] = analyze(s[k], kind)
    return {'id': '230.02-stream-progress-windows', 'archives': {PATHS: PATHS_SHA, MIXED: MIXED_SHA},
            'method': 'Fully contained intervals only; time-weight sample spans. For each span, count streams '
                      'whose cumulative application body bytes increased. Rate equals the fraction of time '
                      'with progress times the mean progressing stream count during that time times delivered '
                      'MiB per progressing stream-second. Grouping 2 or 4 consecutive native spans also '
                      'counts streams which advanced in different parts of that longer span. Retain the '
                      'last partial group; bytes and endpoints are identical at each resolution.',
            'population': 'All 3 release diagnostic sets across all 4 arms with 160 sequential fresh requests '
                          'per arm. Candidate is the published release path; direct is guest DNAT. The third OrbStack '
                          'context run retains one reopened bulk stream. All '
                          '4 fixed-duration diagnostic sets retain bulk and mixed runs. The fourth mixed run '
                          'overlapped profiler attachment and is outside the three clean-set interpretation.',
            'limitations': 'Observed application delivery does not identify kqueue readiness, worker assignment, '
                           'simultaneous CPU service, network packet timing or cause. Replacing idle spans at '
                           'observed nonidle rate is a conditional arithmetic comparison. The paths are '
                           'sequential observations and have different achieved fresh arrival rates. Older '
                           '6.18.35 guest path traces cannot establish throughput on the current four-vCPU holdout.',
            'release_path_factors': factors, 'windows': rows}


if __name__ == '__main__':
    print(json.dumps(replay(), indent=2, allow_nan=False))
