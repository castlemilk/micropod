"""Compare two flat kqueue poll widths on one archived forwarding binary."""
import hashlib
import json
import random
import sys
from pathlib import Path
from statistics import median

root = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(root / "scripts/relaybench"))
from gamma_contrasts import clean_client, read_receipt

archive = root / "docs/benchmarks/2026-11-21/gamma-mixed-scheduler.json.gz"
digest = "9e3b184de862aafacff47312878441e940d030e8cfc8342c0e479d064f4724c8"
data = read_receipt(archive, digest)
records = data["records"]
assert data["platform"]["guest_kernel"] == "6.18.35"
assert data["platform"]["vm_vcpus"] == 4 and data["platform"]["service_cpus"] == "0-3"
fixture_hashes = {
    "fixtures/flat.c": "56033c9d20af65c55f7539ef8ff088f1d959c72e95be371e2af0f877026712ef",
    "fixtures/flat-screen.sh": "fcc060eef5640468d54d13e82751d2dfcde86364b036e1e1355f499591c04c5d",
}
for filename, sha in fixture_hashes.items():
    assert hashlib.sha256(records[filename].encode()).hexdigest() == sha

arms = ("24", "64")
modes = ("stock", "8", "24", "64", "orb")
positions = (0, 1, 4, 2, 3)
rows = []
for i in range(6):
    order = [modes[(pos+i)%5] for pos in positions]
    row = {"round": i, "order": order}
    for arm in arms:
        key = f"flat/{i}-{arm}"
        client = records[key+".json"]
        assert records[key+".err"] == "" and clean_client(client)
        row[arm] = {k: client[k] for k in ("bytes","mib_s","window_s","arrivals","errors",
                                            "reopened","fresh_p95_us","fresh_p99_us")}
    rows.append(row)

summary = {}
for arm in arms:
    values = [r[arm] for r in rows]
    summary[arm] = {k: median(r[k] for r in values) for k in ("mib_s","fresh_p95_us","fresh_p99_us")}
    summary[arm]["p95_below_75ms"] = sum(r["fresh_p95_us"] <= 75000 for r in values)
ratios = [r["64"]["mib_s"]/r["24"]["mib_s"] for r in rows]
rng = random.Random(2300364)
boot = sorted(median(rng.choices(ratios,k=len(ratios))) for _ in range(20000))
print(json.dumps(dict(archive_sha256=digest, fixture_hashes=fixture_hashes, summary=summary,
                      ratios=ratios, median_ratio=median(ratios), interval=[boot[499],boot[19499]],
                      wider_wins=sum(r>1 for r in ratios), rows=rows),sort_keys=True,indent=2))
