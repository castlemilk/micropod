"""Check whether the page-size verifier can detect a cross-wired native build config."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

import kernel_candidate
from gamma_contrasts import ROOT, read_receipt


CONTROL = '4dc985b50bbd1e5942020618df4d8dcc2de47483'
ARCHIVE = ROOT / 'docs/benchmarks/2026-11-21/gamma-direct-macvlan.json.gz'
ARCHIVE_SHA = 'cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976'


def observe(module, directory):
    try:
        result, _ = module.inspect(directory, 4)
        return {'accepted': True, 'embedded_config_verified': result.get('embedded_config_verified')}
    except ValueError as exc:
        return {'accepted': False, 'error': str(exc)}


def replay(full, lazy):
    kernels = read_receipt(ARCHIVE, ARCHIVE_SHA)['kernels']
    inputs = {}
    for name, directory in [('full', full), ('lazy', lazy)]:
        inputs[name] = {}
        for file, key in [('Image', 'image_sha256'), ('config', 'config_sha256')]:
            sha = hashlib.sha256((directory / file).read_bytes()).hexdigest()
            if kernels[name][key] != sha:
                raise ValueError(f'unexpected {name} {file}')
            inputs[name][file] = sha
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        path = 'scripts/relaybench/kernel_candidate.py'
        stock = subprocess.check_output(['git', 'show', f'{CONTROL}:{path}'], cwd=ROOT)
        module_file = work / 'baseline.py'
        module_file.write_bytes(stock)
        spec = importlib.util.spec_from_file_location('baseline', module_file)
        before = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(before)
        for image_name, image_dir in [('full', full), ('lazy', lazy)]:
            for config_name, config_dir in [('full', full), ('lazy', lazy)]:
                directory = work / f'{image_name}-{config_name}'
                directory.mkdir()
                (directory / 'Image').symlink_to((image_dir / 'Image').resolve())
                (directory / 'config').symlink_to((config_dir / 'config').resolve())
                (directory / 'SHA256SUMS').write_text(
                    f"{inputs[image_name]['Image']}  Image\n{inputs[config_name]['config']}  config\n")
                stock_result = observe(before, directory)
                candidate = observe(kernel_candidate, directory)
                if not stock_result['accepted'] or candidate['accepted'] != (image_name == config_name):
                    raise ValueError('unexpected verification result')
                if candidate['accepted'] and not candidate['embedded_config_verified']:
                    raise ValueError('missing in-image evidence')
                rows.append(dict(image=image_name, config=config_name, control=stock_result, candidate=candidate))
    return dict(direction='236.01', date='2026-11-24', tier='source/fixture; archived native Images',
                control_revision=CONTROL, archive_sha256=ARCHIVE_SHA, inputs=inputs,
                control_verifier_sha256=hashlib.sha256(stock).hexdigest(),
                candidate_verifier_sha256=hashlib.sha256(Path(kernel_candidate.__file__).read_bytes()).hexdigest(),
                changed_variable='Require an available in-image compressed kernel config to match its sidecar.',
                workload='All four pairings of two genuine 4 KiB AArch64 Linux 7.3.5 Image/config builds. '
                         'Fresh content-valid manifests identify the exact supplied files in every pairing.',
                observations=rows, vm_boots=0,
                limitation='No 16 KiB candidate Image or running guest was tested. Images built without an '
                           'embedded config can establish page-header and digest identity only.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('full', type=Path)
    parser.add_argument('lazy', type=Path)
    args = parser.parse_args()
    print(json.dumps(replay(args.full, args.lazy), indent=2))
