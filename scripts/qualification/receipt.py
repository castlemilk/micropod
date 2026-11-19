"""First-attempt qualification receipts. Timings use a monotonic clock in milliseconds."""
import hashlib
import json
import os
import platform
import statistics
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def run(argv, *, timeout=60, cwd=None, env=None, expected=0):
    proc = subprocess.run([str(arg) for arg in argv], cwd=cwd, env=env, capture_output=True,
                          text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    if proc.returncode != expected:
        raise RuntimeError(f"{Path(argv[0]).name} returned {proc.returncode}, expected {expected}: "
                           f"{(proc.stderr or proc.stdout).strip()[-1200:]}")
    return proc


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def require(value, message):
    if not value:
        raise ValueError(message)


class Receipt:
    def __init__(self, path, lane):
        self.path = Path(path)
        self.data = {'schema': 1, 'lane': lane, 'host_os': platform.system(),
                     'host_release': platform.release(), 'host_arch': platform.machine(),
                     'checkout': os.environ.get('GITHUB_SHA') or run(['git', 'rev-parse', 'HEAD'], cwd=ROOT).stdout.strip(),
                     'samples': []}

    def record(self, name, fn, **dimensions):
        sample = dict(case=name, **dimensions)
        start = time.perf_counter()
        try:
            result = fn()
            sample.update(result or {})
            sample['outcome'] = 'pass'
        except Exception as error:
            sample.update(outcome='fail', error=str(error))
        sample['validated_ms'] = round(1000 * (time.perf_counter() - start), 3)
        self.data['samples'].append(sample)
        self.save()
        if sample['outcome'] != 'pass':
            print(f"FAIL {name} {dimensions}: {sample['error']}", flush=True)
        return sample

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(self.path.suffix + '.tmp')
        tmp.write_text(json.dumps(self.data, indent=2, sort_keys=True) + '\n')
        tmp.replace(self.path)

    def finish(self):
        rows = self.data['samples']
        groups = {}
        for row in rows:
            if row.get('warmup') or row['outcome'] != 'pass':
                continue
            key = (row['case'], row.get('solution', ''), row.get('shape', ''), row.get('clients', 1))
            groups.setdefault(key, []).append(row['validated_ms'])
        for key, values in groups.items():
            print(f"{key}: n={len(values)} validated median={statistics.median(values):.1f} ms "
                  f"range={min(values):.1f}..{max(values):.1f}")
        self.save()
        return 0 if rows and all(row['outcome'] == 'pass' for row in rows) else 1
