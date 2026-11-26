"""Compare fixed work on Micropod's shipping flat and split kqueue implementations."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile

from ready_poll_width import FILES, OFFERS, ROOT

HERE = Path(__file__).resolve().parent
BASE = "dc019c8cc218c2b10a1b9e26abb76c8bf29a33e7"
FIXTURES = "02ef949a0e9a9bdab6201a64d1a9a277117daf3c"
FLAGS = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-DMICROPOD_BENCH_512K_READS=1"]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def collect():
    sources = {}
    with tempfile.TemporaryDirectory(prefix="relay-topology-") as temp:
        stage = Path(temp)
        adapter = HERE / "queue_topology_fixture.h"
        for path in (*FILES, adapter):
            if path == adapter:
                data = path.read_bytes()
            else:
                revision = BASE if path in FILES[2:] else FIXTURES
                data = subprocess.check_output(["git", "show", f"{revision}:{path.relative_to(ROOT)}"], cwd=ROOT)
            (stage / path.name).write_bytes(data)
            sources[str(path.relative_to(ROOT))] = sha(data)
        env = dict(os.environ, MICROPOD_BENCH_RELAY_READ_KIB="512")
        flags = [*FLAGS, '-DRELAY_SOURCE="queue_topology_fixture.h"']
        program = stage / "order"
        subprocess.run(["clang", *flags, "-DCOMPARE_QUEUE_ORDER", "-I", temp, stage / "late_read_size.c",
                        "-o", program], check=True)
        binary_sha = sha(program.read_bytes())
        compact = {}
        order = ["flat", "nested", "nested", "flat"]
        for mode in order:
            raw = subprocess.check_output([program, "24"], env={**env, "RELAYBENCH_OWNER_TOPOLOGY": mode},
                                          text=True, timeout=40)
            rows = [json.loads(line) for line in raw.splitlines()]
            if [(r["offer_per_stream"], r["inject_after"]) for r in rows] != [
                (offer, pos) for offer in OFFERS for pos in range(17)
            ]:
                raise ValueError("missing offer or injection position")
            result = {}
            for offer in OFFERS:
                cases = [r for r in rows if r["offer_per_stream"] == offer]
                calls = 16 * ((offer + 512 * 1024 - 1) // (512 * 1024))
                for row in cases:
                    if (row["bulk_reads"] != calls or row["bulk_writes"] != calls or row["poll_width"] != 128
                            or row["verified_bulk_bytes"] != 16 * offer or row["polls"] < 1
                            or row["bytes_ahead"] != min(offer, 512 * 1024) * row["writes_ahead"]):
                        raise ValueError(f"incomparable fixed work: {row}")
                result[offer] = {k: [r[k] for r in cases] for k in ("bytes_ahead", "writes_ahead", "polls", "empty_polls")}
                result[offer].update(verified_bulk_bytes=16 * offer, data_reads=calls, data_writes=calls)
            if mode in compact and result != compact[mode]:
                raise ValueError(f"service ordering or poll counts varied between replays: {mode}")
            compact[mode] = result

        # Existing revoke/partial-write fixture runs both constructors and
        # validates byte order, reverse FIN, backpressure and revoked leases.
        qualifier = stage / "qualified"
        subprocess.run(["clang", *flags, "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                        "-I", temp, stage / "filter_work.c", "-o", qualifier], check=True)
        qualifications = [json.loads(line) for line in subprocess.check_output([qualifier], env=env, text=True).splitlines()]
        if ({(r["owner"], r["room_bytes"]) for r in qualifications}
                != {(owner, room) for owner in ("dedicated", "split") for room in (0, 16384)}
                or len(qualifications) != 4 or any(r["verified_payload_bytes"] != 131075 for r in qualifications)):
            raise ValueError("incomplete sanitized revocation/half-close cases")
    return {"base": BASE, "fixture_base": FIXTURES, "sources": sources,
            "driver_sha256": sha(Path(__file__).read_bytes()),
            "host": platform.platform(), "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
            "flags": flags, "order_extra_flags": ["-DCOMPARE_QUEUE_ORDER"],
            "qualification_extra_flags": ["-fsanitize=address,undefined", "-fno-sanitize-recover=all"],
            "order_binary_sha256": binary_sha, "run_order": order, "topologies": compact,
            "revocation_qualification": qualifications,
            "method": "One staged data owner and fixed 512 KiB reads in both arms. Flat polls up to 24 events, "
                      "clips to a 128-event callback budget and services fresh first inside each set. Nested "
                      "uses the existing second kqueue: poll up to 128 interactive events, then up to 12 bulk "
                      "events, repolling the interactive queue between batches. Its 128-event callback guard "
                      "is checked between batches; these samples require 33 data/marker events at most. "
                      "Unlike a normal standalone accept owner, data_workers=2 in both arms. This is the "
                      "combined effect of the actual queue topology, classification/migration and drain policies. "
                      "Sixteen bulk streams. Each array index is the arrival position from zero through the "
                      "16th bulk write; zero queues the marker after existing bulk but before the first poll. "
                      "All bytes and both FINs verified at every position. Each topology ran twice in ABBA order. "
                      "The four additional sanitizer cases revoke pressured leases and check end-to-end bytes; "
                      "no service, VM, IP socket or shared worker was used."}


if __name__ == "__main__":
    print(json.dumps(collect(), indent=2))
