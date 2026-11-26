"""Move the tagged short reply through every position in an established batch."""
import json
import platform
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from test_final_read_fin import FLAGS, HERE, RELAY, ROOT, digest, run
from test_short_reused_ready import FIXTURE, PATCH

POSITION_PATCH = HERE / 'short_reused_position_fixture.patch'


def patched(original, change, work):
    output = work / original.name
    shutil.copyfile(original, output)
    subprocess.run(['patch', '-s', '-F', '0', str(output), '-i', str(change)], check=True)
    return output


def collect():
    stock = RELAY / 'PublishedTCP.c'
    rows, binaries = {}, {}
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        fixture = patched(FIXTURE, POSITION_PATCH, work)
        candidate = patched(stock, PATCH, work)
        for arm, source in [('stock', stock), ('candidate', candidate)]:
            binary = work / arm
            subprocess.run(['clang', *FLAGS, '-I', str(RELAY / 'include'), '-I', str(HERE),
                            f'-DRELAY_SOURCE="{source}"', str(fixture), '-o', str(binary)], check=True)
            binaries[arm] = digest(binary)
            samples = run(binary)
            if [r['bulk_enqueued_before_tag'] for r in samples] != list(range(17)):
                raise ValueError('missing or reordered sensitivity case')
            for position, row in enumerate(samples):
                tag_position = position if arm == 'stock' else 0
                order = list(range(16))
                order.insert(tag_position, 16)
                if (row['verified_bytes'], row['nonempty_polls'], row['fresh_ahead_bytes'],
                    row['tagged_ahead_bytes'], row['write_order']) != (
                        1048594, 1, 0, 1 + tag_position * 65536, [17, *order]):
                    raise ValueError(f'unexpected schedule, payload, or callback: {arm} {row}')
            rows[arm] = samples
    paths = [stock, RELAY / 'include/PublishedTCP.h', HERE / 'filter_work.c', FIXTURE, POSITION_PATCH, PATCH,
             HERE / 'test_final_read_fin.py', HERE / 'test_short_reused_ready.py', Path(__file__).resolve()]
    return {
        'method': 'Hold socket identities, payloads, byte totals and native kqueue width fixed. Sixteen '
                  'bulk directions each contribute 65536 bytes. Move the 17-byte tagged offer through all 17 '
                  'possible positions, always enqueue the one-byte unclassified offer last, then service one '
                  'ready set of 18. Stream IDs 0–15 are bulk, 16 is tagged and 17 unclassified. Both arms '
                  'verify ordered writes, data contents, reverse payloads, two FINs and retirement.',
        'scope': 'Service order and exact preceding write volume. Latency at intermediate positions is unmeasured.',
        'base': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip(),
        'collected_utc': datetime.now(timezone.utc).isoformat(), 'arch': platform.machine(),
        'darwin': platform.release(), 'flags': FLAGS,
        'compiler': subprocess.check_output(['clang', '--version'], text=True).splitlines()[0],
        'source_sha256': {str(p.relative_to(ROOT)): digest(p) for p in paths},
        'binary_sha256': binaries, 'rows': rows,
    }


@unittest.skipUnless(platform.system() == 'Darwin', 'requires Darwin kqueue')
class ShortReusedPositionTests(unittest.TestCase):
    def test_every_enqueue_position(self):
        collect()


if __name__ == '__main__':
    print(json.dumps(collect(), indent=2))
