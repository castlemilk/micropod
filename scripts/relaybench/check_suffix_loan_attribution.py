"""Confirm the scratch-loan mechanism by switching it on and off inside exactly one binary."""
import json
import os
import platform
import random
import statistics
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from check_suffix_loan import ARMS, BLOCKS, FLAGS, HERE, ROOT, REVISION, aggregate, digest, summary


def main():
    revision = subprocess.check_output(['git', 'rev-parse', REVISION + '^{commit}'], cwd=ROOT, text=True).strip()
    original = {'PublishedTCP.c': 'Sources/CPublishedTCP/PublishedTCP.c',
                'PublishedTCP.h': 'Sources/CPublishedTCP/include/PublishedTCP.h', 'filter_work.c': 'scripts/relaybench/filter_work.c'}
    blocks = []
    with tempfile.TemporaryDirectory(prefix='scratch-loan-control-') as work:
        directory = Path(work)
        for name, path in original.items():
            (directory / name).write_bytes(subprocess.check_output(['git', 'show', f'{revision}:{path}'], cwd=ROOT))
        (directory / 'suffix_loan.c').write_bytes((HERE / 'suffix_loan.c').read_bytes())
        subprocess.run(['patch', '-s', '-F', '0', '-i', str(HERE / 'suffix_loan.patch')], cwd=directory, check=True)
        src = directory / 'PublishedTCP.c'
        code = src.read_text()
        decl = 'static void pump(struct endpoint *src, struct endpoint *dst) {'
        test = 'if (remaining >= CHUNK / 4 && !r->loaned) {'
        if code.count(decl) != 1 or code.count(test) != 1:
            raise ValueError('unexpected candidate code')
        code = code.replace(decl, '''static bool fixture_allow_loan;
__attribute__((constructor)) static void fixture_mode(void) {
    const char *mode = getenv("MICROPOD_FIXTURE_LOAN");
    if (!mode || (strcmp(mode, "0") && strcmp(mode, "1"))) abort();
    fixture_allow_loan = !strcmp(mode, "1");
}
''' + decl).replace(test, 'if (remaining >= CHUNK / 4 && !r->loaned && fixture_allow_loan) {')
        src.write_text(code)
        binary = directory / 'fixture'
        subprocess.run(['clang', *FLAGS, '-DLOAN=1', '-DRELAY_SOURCE="PublishedTCP.c"', '-DBENCH_HELPERS="filter_work.c"',
                        '-I', work, str(directory / 'suffix_loan.c'), '-o', str(binary)], check=True)
        binary_sha = digest(binary.read_bytes())

        def run(arm):
            env = dict(os.environ, MICROPOD_FIXTURE_LOAN=str(int(arm == 'loan')))
            raw = subprocess.run([str(binary), 'measure'], env=env, capture_output=True, text=True, check=True, timeout=18)
            rows = [json.loads(line) for line in raw.stdout.splitlines()]
            if (raw.stderr or len(rows) != 2 or any(r['bulk_bytes'] != 96 * 2**20 or len(r['fresh_ns']) != 48 for r in rows)
                    or rows[0]['copy_ops'] != 0 or rows[1]['copy_bytes'] != (70778880 if arm == 'loan' else 94371840)):
                raise ValueError(f'incomplete or incorrectly switched {arm} observation')
            return rows

        for arm in ARMS:
            run(arm)
        for i in range(BLOCKS):
            order = ('stock', 'loan', 'loan', 'stock') if not i % 2 else ('loan', 'stock', 'stock', 'loan')
            blocks.append([{'arm': arm, 'rows': run(arm)} for arm in order])
    normalized = []
    for block in blocks:
        ratios = []
        for i in (0, 1):
            cpu = [aggregate([s['rows'][i] for s in block if s['arm'] == a])['owner_cpu_s_per_gib'] for a in ARMS]
            ratios.append(cpu[1] / cpu[0])
        normalized.append(100 * (ratios[1] / ratios[0] - 1))
    rng = random.Random(23007)
    boot = sorted(statistics.median(rng.choices(normalized, k=BLOCKS)) for _ in range(10000))
    files = [Path(__file__).resolve(), HERE / 'check_suffix_loan.py', HERE / 'suffix_loan.c', HERE / 'suffix_loan.patch']
    print(json.dumps({'schema': 1, 'completed_utc': datetime.now(timezone.utc).isoformat(), 'darwin': platform.release(),
                      'base_revision': revision, 'single_binary_sha256': binary_sha, 'compiled_relay_sha256': digest(code.encode()),
                      'diagnostic_sha256': {p.name: digest(p.read_bytes()) for p in files},
                      'method': 'Independent follow-up to relay-suffix-loan-offline.json. Both arms use the same candidate binary '
                                'and owner layout. The stock label disables lending through a process-start switch, retaining exact '
                                'malloc/memcpy on initial short writes. The loan label enables lending. All other workloads, clocks, '
                                'phasings, sixteen matched ABBA/BAAB blocks and bootstrap methods match the original. Same-size '
                                'environment values; the roomy control performs zero loans and zero first copies.',
                      'summary': {name: summary(blocks, i) for i, name in enumerate(('roomy', 'pressured'))},
                      'pressure_over_roomy_cpu_ratio_paired_change_percent': {'median': round(statistics.median(normalized), 2),
                             'bootstrap_95_percent_interval': [round(boot[249], 2), round(boot[9749], 2)]},
                      'raw': blocks}, separators=(',', ':')))


if __name__ == '__main__':
    main()
