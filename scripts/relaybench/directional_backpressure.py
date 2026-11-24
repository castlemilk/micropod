"""Compare aggregate and directional backpressure counts on real, private Darwin sockets."""
import json
import platform
import subprocess
import tempfile
from pathlib import Path
from compare import C_SOURCE, HEADER, SWIFT_SOURCE, git, sha

HERE = Path(__file__).resolve().parent
BASE = '2ccda8507355b8220258db2ce8160f3113d3e1ff'


def replay():
    fixture = HERE / 'directional_backpressure.c'
    patch = HERE / 'directional_backpressure.patch'
    result = dict(direction='230.07', base=BASE, scope='Darwin AF_UNIX streams and real kqueue; untimed',
                  platform=platform.platform(), compiler=subprocess.check_output(['clang','--version'], text=True).splitlines()[0],
                  file_sha256={p.name:sha(p.read_bytes()) for p in [fixture, patch, HERE/'filter_work.c', Path(__file__)]},
                  verified='Both half-closes and all bytes in both directions. Target and merged lease counters checked. '
                           'One deliberately forced blocked retry per pressured send.', arms={})
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for p in [C_SOURCE, HEADER, SWIFT_SOURCE]:
            src = root/p
            src.parent.mkdir(parents=True, exist_ok=True)
            src.write_bytes(git('show',f'{BASE}:{p}'))
        for patched in [False, True]:
            if patched:
                subprocess.run(['patch', '-s', '-p1', '-i', patch], cwd=root, check=True)
            arm = dict(source_sha256={p:sha((root/p).read_bytes()) for p in [C_SOURCE,HEADER,SWIFT_SOURCE]})
            for sanitized in [False,True]:
                exe = root/'check'
                flags = ['-Wall','-Wextra','-Werror','-fblocks','-O2','-I',str((root/HEADER).parent),
                         '-I',str((root/C_SOURCE).parent),'-DRELAY_SOURCE="PublishedTCP.c"']
                if patched:
                    flags.append('-DDIRECTIONAL_STATS')
                if sanitized:
                    flags.extend(['-fsanitize=address,undefined','-fno-sanitize-recover=all'])
                subprocess.run(['clang',*flags,fixture,'-o',exe],check=True)
                rows = [json.loads(line) for line in subprocess.check_output([exe],text=True,timeout=10).splitlines()]
                assert len(rows)==8
                arm['sanitized' if sanitized else 'optimized'] = rows
            result['arms']['directional' if patched else 'aggregate'] = arm
    return result


if __name__ == '__main__':
    print(json.dumps(replay(),indent=2))
