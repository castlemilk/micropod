"""Exercise the profile from real guest reads through the production Swift lease JSON."""
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
SWIFT = ROOT / "Sources/MicropodRuntime/NativeLoopbackRelay.swift"
OFFERED = [128*1024, 128*1024+1, 256*1024-1, 256*1024, 256*1024+1, 512*1024, 512*1024+1, 17, 32*1024]


def collect():
    with tempfile.TemporaryDirectory() as work:
        directory = Path(work)
        header = RELAY / "include/PublishedTCP.h"
        c_fixture = HERE / "guest_read_profile_fixture.c"
        swift_fixture = HERE / "guest_read_profile_fixture.swift"
        (directory / "module.modulemap").write_text(f'module CPublishedTCP {{ header "{header}" export * }}\n')
        obj, binary = directory / "fixture.o", directory / "fixture"
        subprocess.run(["clang", "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-DMICROPOD_BENCH_512K_READS=1", "-I", header.parent, "-c", c_fixture, "-o", obj], check=True)
        subprocess.run(["swiftc", "-swift-version", "6", "-module-cache-path", directory / "modules", "-I", directory,
                        SWIFT, swift_fixture, obj, "-o", binary], check=True)
        profiles = {}
        for cap in (256, 512):
            output = subprocess.check_output([binary], text=True, timeout=15,
                                             env=dict(os.environ, MICROPOD_BENCH_RELAY_READ_KIB=str(cap)))
            profiles[str(cap)] = [json.loads(line.removeprefix("published TCP profile ")) for line in output.splitlines()
                                  if line.startswith("published TCP profile ")]
        sources = [SWIFT, RELAY / "PublishedTCP.c", header, HERE / "filter_work.c", c_fixture,
                   swift_fixture, Path(__file__).resolve()]
        return {"schema": 1, "darwin": platform.release(), "machine": platform.machine(),
                "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
                "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                "method": "Anonymous socketpairs enter the established-stream path on each actual Swift owner queue "
                          "at release. Real reads, writes, kqueue delivery, backpressure, worker merge and lease JSON. "
                          "A fabricated oversized readiness snapshot also drives a 17-byte read and an empty retry. "
                          "Port 4002 has two workers, 4000 one inline owner, and 4001 disables profiling. "
                          "Port 4003 exercises sparse and dense flat polls, budget-limited returns, unclassified "
                          "reads and a final read with EOF. Fixture counts describe the controlled offers only.",
                "guest_offers_bytes_per_owner": OFFERED, "lease_profiles_by_cap_kib": profiles}


@unittest.skipUnless(sys.platform == "darwin", "requires Darwin kqueue")
class GuestReadProfileTests(unittest.TestCase):
    def test_observed_sizes_advisory_readiness_and_release_merge(self):
        for setting, profiles in collect()["lease_profiles_by_cap_kib"].items():
            cap = int(setting)
            with self.subTest(read_kib=cap):
                self.assertEqual([p["port"] for p in profiles], [4002, 4000, 4003])
                polls = profiles[2]["guest_read_supply"]
                self.assertEqual(polls["full_cap_with_ready_hint_above_cap"], 2*14)
                self.assertEqual(polls["flat_bulk_full_cap_with_ready_hint_above_cap"], 2*(1+1+2+3+3))
                self.assertEqual(polls["sparse_flat_bulk_full_cap_with_ready_hint_above_cap"], 2*(1+2))
                for p, owners in zip(profiles, (2, 1)):
                    bins = (5, 2, 6, 0) if cap == 256 else (4, 2, 1, 3)
                    full, hinted = (6, 4) if cap == 256 else (2, 1)
                    self.assertEqual(p["guest_read_supply"], {
                        "read_cap_bytes": cap*1024, "bytes": owners*sum(OFFERED),
                        "le_128_kib": owners*bins[0], "gt_128_lt_256_kib": owners*bins[1],
                        "eq_256_kib": owners*bins[2], "gt_256_kib": owners*bins[3],
                        "full_cap_reads": owners*full, "full_cap_with_ready_hint_above_cap": owners*hinted,
                        "flat_bulk_full_cap_with_ready_hint_above_cap": owners*hinted if owners == 2 else 0,
                        "sparse_flat_bulk_full_cap_with_ready_hint_above_cap": owners*hinted if owners == 2 else 0,
                    })
                    self.assertEqual(p["download_bytes"], owners*sum(OFFERED))
                    self.assertEqual(p["upload_bytes"], owners*(512*1024+1))
                    self.assertEqual(p["pending_allocations"], owners)


if __name__ == "__main__":
    if sys.argv[1:] == ["--receipt"]:
        print(json.dumps(collect(), indent=2))
    else:
        unittest.main()
