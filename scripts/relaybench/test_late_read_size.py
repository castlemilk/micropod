"""Measure how much of a bulk ready set precedes a fresh reply arriving mid-batch."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
RELAY = ROOT / "Sources/CPublishedTCP"
FILES = (HERE / "late_read_size.c", HERE / "filter_work.c", RELAY / "PublishedTCP.c", RELAY / "include/PublishedTCP.h")
FLAGS = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-DMICROPOD_BENCH_512K_READS=1"]


def collect():
    with tempfile.TemporaryDirectory() as temp:
        binary = Path(temp) / "late-reply"
        subprocess.run(["clang", *FLAGS, "-I", str(RELAY / "include"), str(FILES[0]), "-o", str(binary)], check=True)
        result = {}
        for kib in (256, 512):
            env = dict(os.environ, MICROPOD_BENCH_RELAY_READ_KIB=str(kib))
            output = subprocess.check_output([binary], env=env, text=True, timeout=20)
            result[str(kib)] = [json.loads(line) for line in output.splitlines()]
        return {
            "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in FILES},
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "flags": FLAGS,
            "darwin": platform.release(), "machine": platform.machine(),
            "method": "One binary, 16 established bulk downloads and one first reply on the same dedicated owner. "
                      "Each bulk destination drains freely. Inject one fresh byte into its guest socket immediately "
                      "after the first or sixteenth bulk write returns. Count actual subsequent bulk writes and "
                      "bytes before the first fresh write; verify every stream byte. The fixture uses Darwin kqueue "
                      "and anonymous stream sockets and measures work ordering, without timing or a VM.",
            "rows_by_read_kib": result,
        }


@unittest.skipUnless(sys.platform == "darwin", "requires Darwin kqueue")
class LateReadSizeTests(unittest.TestCase):
    def test_bytes_ahead_of_late_fresh_reply(self):
        for kib, rows in collect()["rows_by_read_kib"].items():
            expected = []
            cap = int(kib) * 1024
            for offered in (128 * 1024, 512 * 1024):
                for position in (1, 16):
                    expected.append(dict(offer_per_stream=offered, inject_after=position, writes_ahead=16-position,
                                         bytes_ahead=(16-position)*min(cap, offered),
                                         bulk_writes=16*((offered + cap - 1)//cap), verified_bulk_bytes=16*offered))
            self.assertEqual(rows, expected)


if __name__ == "__main__":
    print(json.dumps(collect(), indent=2))
