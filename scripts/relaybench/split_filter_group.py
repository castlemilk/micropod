"""Compare same-kqueue coalescing against the existing opt-in batched relay."""
import json
import platform
import subprocess
import tempfile
from pathlib import Path

from compare import C_SOURCE, HEADER, ROOT, git, sha

BASE = "38e4fbca6b10e87835278d3b8bf38622333dad04"
HERE = Path(__file__).resolve().parent
PATCH = HERE / "split_filter_group.patch"
FIXTURE = HERE / "split_filter_group.c"


def run():
    result = dict(direction="230.03", control=BASE, system=platform.platform(),
                  compiler=subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
                  source_fixture="Darwin AF_UNIX pairs and actual kqueue calls; no IP connection or VM",
                  files={p.name: sha(p.read_bytes()) for p in
                         [PATCH, FIXTURE, HERE / "filter_work.c", Path(__file__)]}, arms={})
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp)
        (dest / "PublishedTCP.h").write_bytes(git("show", f"{BASE}:{HEADER}"))
        for patched in [False, True]:
            src = dest / "PublishedTCP.c"
            src.write_bytes(git("show", f"{BASE}:{C_SOURCE}"))
            if patched:
                subprocess.run(["patch", "-s", str(src), "-i", str(PATCH)], check=True)
            arm = dict(c_sha256=sha(src.read_bytes()))
            for sanitized in [False, True]:
                exe = dest / "fixture"
                flags = ["-Wall", "-Wextra", "-Werror", "-fblocks", "-DMICROPOD_BATCH_STREAM_FILTERS=1",
                         '-DRELAY_SOURCE="PublishedTCP.c"', "-I", str(dest), "-O2"]
                if sanitized:
                    flags += ["-fsanitize=address,undefined", "-fno-sanitize-recover=all"]
                subprocess.run(["clang", *flags, str(FIXTURE), "-o", exe], check=True)
                raw = subprocess.check_output([exe], timeout=10, text=True)
                rows = [json.loads(line) for line in raw.splitlines()]
                assert rows[-1] == {"mixed_queue_submissions": 2, "correctly_routed_events": 2}
                assert [(r['owner'],r['room_bytes']) for r in rows[:-1]] == [
                    (owner,room) for owner in ['split','dedicated'] for room in [0,16384]]
                for row in rows[:-1]:
                    assert row["verified_payload_bytes"] == 131075
                    for phase,count in [('connect_complete',3),('pause_reader',2),('resume_reader',2),('unblocked_bulk',0)]:
                        expected = int(count > 0) if patched or row['owner']=='dedicated' else count
                        assert row[phase] == dict(syscalls=expected, filters=count)
                arm["sanitizer" if sanitized else "optimized"] = rows
            result['arms']['coalesced' if patched else 'control'] = arm
    return result


if __name__ == "__main__":
    print(json.dumps(run(), indent=2))
