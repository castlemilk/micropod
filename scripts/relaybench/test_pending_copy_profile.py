import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "requires Darwin kqueue")
class PendingCopyProfileTests(unittest.TestCase):
    def test_socketpair_counts_and_lease_totals(self):
        here = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as temp:
            binary = Path(temp) / "pending-profile"
            subprocess.run([
                "clang", "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
                "-DCHECK_PENDING_COPY_PROFILE", "-I", str(here.parents[1] / "Sources/CPublishedTCP/include"),
                str(here / "filter_work.c"), "-o", str(binary),
            ], check=True)
            output = subprocess.check_output([str(binary)], text=True, timeout=10)
        rows = [json.loads(line) for line in output.splitlines()]
        self.assertEqual([row["profile"] for row in rows if "profile" in row], [0, 1])
