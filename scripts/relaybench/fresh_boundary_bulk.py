"""Replay bulk delivery on the same sockets immediately before/after the fresh load changes."""
import hashlib
import json
from pathlib import Path

from chunk_replay import DIRECTORY
from gamma_contrasts import MIB, percentile, read_receipt, stream_rates
from stream_progress_windows import PATHS, PATHS_SHA, scored_points

# The trace fixture records 400-ms bulk-only flanks. Leave 50 ms at the outside
# for ticker jitter. Shorter symmetric windows show sensitivity to the horizon.
HORIZONS_MS = (100, 200, 350)


def window(samples, lower, upper, fresh):
    points = [(at, counts) for at, counts in samples if lower <= at <= upper]
    if len(points) < 2:
        raise ValueError('no complete sample interval inside event window')
    begin, start = points[0]
    end, finish = points[-1]
    elapsed = end - begin
    delivered = [b - a for a, b in zip(start, finish)]
    return {
        'start_us': begin, 'end_us': end, 'sample_intervals': len(points) - 1,
        'covered_fraction': elapsed / (upper - lower),
        'bytes': sum(delivered), 'mib_s': sum(delivered) / MIB * 1e6 / elapsed,
        'streams_observed_delivering': sum(v > 0 for v in delivered),
        'fresh_started': sum(begin <= q['start_us'] < end for q in fresh),
        'fresh_completed': sum(begin < q['done_us'] <= end for q in fresh),
    }


def measure(record, expected_requests):
    tr = record['trace']
    requests = tr['fresh']
    begin, end = tr['overlap_start_us'], tr['overlap_end_us']
    counts = record['overlap_bytes_per_stream']
    stream_rates({'bytes': record['overlap_bytes'], 'per_stream_bytes': counts},
                 record['overlap_s'], record['overlap_mib_s'])
    if (record['streams'] != 32 or record['mode'] != 'mixed' or len(requests) != expected_requests
            or record['fresh']['iterations'] != expected_requests or record['fresh']['incomplete_phase_samples']
            or tr['omitted_samples'] or tr['sample_period_us'] != 5000
            or abs(record['overlap_s'] * 1e6 - (end - begin)) > 1.1):
        raise ValueError('incomplete or unexpected mixed workload')
    samples = [(s['at_us'], s['cumulative_bytes']) for s in tr['samples']]
    scored_points(samples, begin, end, counts)
    for n, q in enumerate(requests):
        if not (begin <= q['start_us'] <= q['written_us'] <= q['first_byte_us'] <= q['done_us'] <= end + 1
                and (n == 0 or requests[n-1]['done_us'] <= q['start_us'])):
            raise ValueError('fresh requests are incomplete, overlapping or unordered')
    on, off = requests[0]['start_us'], requests[-1]['done_us']
    reopens = {p: record[p + '_reopens'] for p in ('warmup', 'overlap', 'drain')}
    if sum(reopens.values()) != record['reopened_connections']:
        raise ValueError('inconsistent reopen attribution')
    spans = {}
    for ms in HORIZONS_MS:
        width = ms * 1000
        if not samples[0][0] <= on - width < on + width < off - width < off + width <= samples[-1][0]:
            raise ValueError('missing or overlapping observation windows')
        spans[ms] = {
            'before_first': window(samples, on - width, on, requests),
            'after_first': window(samples, on, on + width, requests),
            'before_last_completion': window(samples, off - width, off, requests),
            'after_last_completion': window(samples, off, off + width, requests),
        }
        for tag in ('before_first', 'after_last_completion'):
            if spans[ms][tag]['fresh_started'] or spans[ms][tag]['fresh_completed']:
                raise ValueError('fresh load present in bulk-only window')
    durations = [q['done_us'] - q['start_us'] for q in requests]
    return {'clean': not any(reopens.values()), 'reopens': reopens, 'streams': len(counts),
            'fresh_completed': len(requests), 'fresh_load_span_us': off - on,
            'fresh_p95_ms': percentile(durations, .95) / 1000,
            'fresh_p99_ms': percentile(durations, .99) / 1000,
            'whole_mixed_mib_s': record['overlap_mib_s'], 'windows_ms': spans}


def contrasts(left, right):
    # Relative to the same reference route at each edge. Raw rates are retained,
    # including single-engine absolute deltas when the other route is unstable.
    out = {}
    for ms in HORIZONS_MS:
        a, b = left['windows_ms'][ms], right['windows_ms'][ms]
        ratio = {k: a[k]['mib_s'] / b[k]['mib_s'] if b[k]['mib_s'] > 0 else None for k in a}
        def change(lo, hi):
            return None if ratio[lo] is None or ratio[hi] is None else 100 * (ratio[hi] - ratio[lo])
        out[ms] = {'published_over_reference': ratio,
                   'onset_change_percentage_points': change('before_first', 'after_first'),
                   'offset_change_percentage_points': change('before_last_completion', 'after_last_completion')}
    return out


def replay():
    data = read_receipt(DIRECTORY / PATHS, PATHS_SHA)
    if data['baseline_commit'] != '4f887ba5':
        raise ValueError('wrong acquisition revision')
    rows, pairs = {}, []
    for cohort in ('original', 'release'):
        for i in (1, 2, 3):
            if cohort == 'original':
                names = [f'trace/{label}-{i}.json' for label in ('control', 'direct', 'orb')]
            else:
                names = [f'final-trace/{i}-{label}.json' for label in ('candidate', 'direct', 'orb')]
            for name in names:
                rows[name] = measure(data['records'][name], 240 if cohort == 'original' else 160)
            for reference in names[1:]:
                a, b = rows[names[0]], rows[reference]
                pairs.append({'cohort': cohort, 'set': i, 'published': names[0], 'reference': reference,
                              'both_clean': a['clean'] and b['clean'], 'windows_ms': contrasts(a, b)})
    return {
        'date': '2026-11-24', 'issue': 230, 'direction': '230.04',
        'acquisition': {'base': '4f887ba5d28f47fa37d4bd0a2d89cd0914d74754',
                        'archive': PATHS, 'sha256': PATHS_SHA, 'binaries': data['binaries'],
                        'source_sha256': data['source_sha256'], 'platform': data['platform']},
        'analysis_base': '2ccda8507355b8220258db2ce8160f3113d3e1ff',
        'script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'tier': 'Offline raw replay of historical VM diagnostics',
        'hypothesis': 'If fresh admission alone opens the relative throughput deficit, the published-to-reference '
                      'rate ratio should fall across first arrival and recover after last completion.',
        'method': 'Same 32 already-warm sockets. Compare fully contained cumulative-byte sample spans on either '
                  'side of first fresh request start and final fresh response completion. Use 350 ms on each side '
                  'and inspect 100/200 ms. Each invocation runs bulk-only, then 240 (original) or 160 (release) sequential fresh probes, then '
                  'bulk-only. The two paths are observed in separate invocations. Keep each historical cohort separate.',
        'limits': 'The samples within one run are dependent. Small traced sets, fixed phase order, variable '
                  'offered fresh rates and short flanks limit causal interpretation. Interface drops and '
                  'per-process CPU/runnable time for the four subwindows are unavailable. No peer qualification.',
        'rows': rows, 'paired': pairs}


if __name__ == '__main__':
    print(json.dumps(replay(), indent=2, sort_keys=True, allow_nan=False))
