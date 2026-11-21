import gzip
import json
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
import unittest

from check_worker_cpu_quota import check
from summarize_worker_cpu import summary

ROOT = Path(__file__).resolve().parents[1]


class WorkerPerformanceTests(unittest.TestCase):
    def test_replays_the_gamma_holdout_including_the_failed_peer_round(self):
        receipt = ROOT / "docs/benchmarks/2026-11-21/gamma-vcpu-priority.json.gz"
        with gzip.open(receipt, "rt") as stream:
            holdout = json.load(stream)["phases"]["grace-holdout"]
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            for engine, recorded in (("candidate", "confirm-micropod"), ("baseline", "confirm-micropod"),
                                     ("orbstack", "confirm-orb")):
                (directory / f"{engine}.resources").write_text("4 4294967296")
                for n, row in holdout["runs"][recorded].items():
                    dest = directory / f"offered-scored-{n}-{engine}"
                    dest.with_suffix(".status").write_text("0" if row["clean"] else "1")
                    dest.with_suffix(".json").write_text(json.dumps(row["client"]))
            result = summary(directory, 16)
        reference = holdout["paired"]["confirm-micropod"]
        paired = result["paired"]["candidate_vs_orbstack"]
        self.assertEqual(result["engines"]["orbstack"]["failed_rounds"], [12])
        self.assertEqual(paired["common_clean_rounds"], reference["rounds"])
        self.assertEqual(paired["median_throughput_ratio"], reference["ratio"])
        self.assertEqual(paired["throughput_ratio_ci95"], reference["interval"])

    def test_quota_check_requires_cpu_time_and_active_scheduler_evidence(self):
        row = "\n".join(["ext_task=1", "ext_task=1", "state=enabled", "ops=bpfland", "sequence=2",
                         "start_usec=1000", "start_s=10", "end_usec=2501000", "end_s=15",
                         "cpu_max=50000 100000", "memory_max=1073741824", "pids_max=512"])
        self.assertTrue(check(row, 50000, "bpfland")["pass"])
        for old, new in (("2501000", "9001000"), ("ext_task=1", "ext_task=0"), ("enabled", "disabled"),
                         ("pids_max=512", "pids_max=max")):
            self.assertFalse(check(row.replace(old, new), 50000, "bpfland")["pass"])

    def test_postgres_bridge_scopes_traffic_and_cleans_up_after_sql_failure(self):
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)
            docker = directory / "docker"
            docker.write_text("""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['CALLS'],'a') as log:
    print(json.dumps(args), file=log)
if args[:2] == ['network','create']: print('network-id')
if args[0] == 'create': print('db-id')
if args[0] == 'run': sys.exit(int(os.environ['QUERY_EXIT']))
""")
            docker.chmod(0o755)
            for status in (0, 7):
                log = directory / f"calls-{status}"
                env = {**os.environ, "PATH": tmp + os.pathsep + os.environ["PATH"],
                       "CALLS": str(log), "QUERY_EXIT": str(status), "DOCKER_HOST": "unix:///test"}
                result = subprocess.run(["bash", ROOT / "ci/worker-postgres-bridge.sh"], env=env)
                self.assertEqual(result.returncode, status)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                net = calls[0][-1]
                db = next(args for args in calls if args[0] == "create")
                client = next(args for args in calls if args[0] == "run")
                for args in (db, client):
                    self.assertEqual(args[args.index("--network") + 1], net)
                    self.assertFalse(set(args) & {"-p", "--publish", "--mount", "-v"})
                self.assertEqual(client[-1], db[db.index("--name") + 1])
                self.assertIn(["rm", "-fv", "db-id"], calls)
                self.assertEqual(calls[-1], ["network", "rm", "network-id"])


if __name__ == "__main__":
    unittest.main()
