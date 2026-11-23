from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "requires Darwin kqueue")
class ReadSizeTests(unittest.TestCase):
    def test_read_cap_on_bulk_and_fresh_flows(self):
        here = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as temp:
            binary = Path(temp) / "read-size"
            for kib, turns, flags in [(256, 4, []), (512, 2, ["-DMICROPOD_BENCH_512K_READS=1"])]:
                with self.subTest(kib=kib):
                    subprocess.run([
                        "clang", "-O2", "-Wall", "-Wextra", "-Werror", *flags,
                        "-I", str(here.parents[1] / "Sources/CPublishedTCP/include"),
                        str(here / "read_size.c"), "-o", str(binary),
                    ], check=True)
                    row = subprocess.check_output([str(binary), str(kib)], text=True, timeout=10)
                    self.assertEqual([int(x) for x in row.split()], [kib * 1024, turns, 786449, 17])
