import os
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
            for switchable in (False, True):
                flags = ["-DMICROPOD_BENCH_512K_READS=1"] if switchable else []
                subprocess.run([
                    "clang", "-O2", "-Wall", "-Wextra", "-Werror", *flags,
                    "-I", str(here.parents[1] / "Sources/CPublishedTCP/include"),
                    str(here / "read_size.c"), "-o", str(binary),
                ], check=True)
                for setting in (None, "256", "512", "", "0256", "256 ", "1024"):
                    with self.subTest(switchable=switchable, setting=setting):
                        env = os.environ.copy()
                        env.pop("MICROPOD_BENCH_RELAY_READ_KIB", None)
                        if setting is not None:
                            env["MICROPOD_BENCH_RELAY_READ_KIB"] = setting
                        if switchable and setting not in (None, "256", "512"):
                            subprocess.run([binary, "invalid"], env=env, check=True, timeout=10)
                            continue
                        kib = int(setting or "512") if switchable else 256
                        row = subprocess.check_output([binary, str(kib)], env=env, text=True, timeout=10)
                        self.assertEqual([int(x) for x in row.split()], [
                            kib * 1024, 2 if kib == 512 else 4, 786449, 17, (512 if switchable else 256) * 1024,
                        ])
