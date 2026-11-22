"""Fast, local contracts for the optional PostgreSQL storage experiment. No daemon required."""
from collections import Counter
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

from bench_postgres_fixture import measure_matrix, mode_order, timed_result
from postgres_fixture_storage import (CASES, CHECK_SQL, OVERLAY, STOCK, added_image_history,
                                      disk_delta, effective_mount, io_counters, pinned_base)

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "ci/fixtures/postgres-profile"
ROOT_MOUNT = "3 1 0:3 / / rw - overlay overlay rw\n"
VOLUME = {"Type": "volume", "RW": True, "Name": "owned-volume", "Destination": STOCK}
VOL_MOUNT = f"8 3 253:0 /volume/data {STOCK} rw - ext4 /dev/vda rw\n"


class StorageContracts(unittest.TestCase):
    def test_targets_inherit_one_base_and_one_overlay_directory(self):
        stages, parents = {}, {}
        for line in (FIXTURE / "Dockerfile").read_text().splitlines():
            if line.startswith("FROM "):
                _, parent, _, stage = line.split()
                parents[stage] = parent
                stages[stage] = stages.get(parent, {"PGDATA": STOCK}).copy()
            if line.startswith("ENV "):
                stages[stage].update(pair.split("=", 1) for pair in shlex.split(line)[1:])
        self.assertEqual(parents, {"fresh": "${BASE}", "fresh-overlay": "fresh", "prepared": "fresh-overlay"})
        self.assertEqual({k: e["PGDATA"] for k, e in stages.items()}, CASES)
        self.assertTrue(all(v["MICROPOD_PG_FIXTURE_MODE"] == k for k, v in stages.items()))

    def test_real_entrypoint_selects_mode_on_the_same_path(self):
        # Replace external executables and system paths only. Execute the actual POSIX dispatch.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "clock").write_text("1.25 3.00\n")
            for name in ("stock", "overlay", "shm"):
                (root / name).mkdir()
            for name in ("gosu", "docker-entrypoint.sh"):
                f = root / name
                f.write_text('#!/bin/sh\nprintf "%s %s\\n" "${0##*/}" "$*"\n')
                f.chmod(0o755)
            text = (FIXTURE / "fixture.sh").read_text()
            for source, local in {"/proc/uptime": "clock", "/dev/shm": "shm", STOCK: "stock", OVERLAY: "overlay",
                                  "/usr/local/bin/docker-entrypoint.sh": "docker-entrypoint.sh"}.items():
                text = text.replace(source, str(root / local))
            script = root / "fixture.sh"
            script.write_text(text)

            def start(mode, pgdata):
                env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                           MICROPOD_PG_FIXTURE_MODE=mode, PGDATA=str(root / pgdata))
                return subprocess.run(["sh", str(script), "postgres"], env=env, capture_output=True, text=True)
            for mode, directory, action in (("fresh", "stock", "docker-entrypoint.sh postgres"),
                                            ("fresh-overlay", "overlay", "docker-entrypoint.sh postgres"),
                                            ("prepared", "overlay", "gosu postgres micropod-pg-fixture open")):
                result = start(mode, directory)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines()[-1], action)
            for mode, directory in (("fresh", "overlay"), ("prepared", "stock"), ("typo", "overlay")):
                self.assertNotEqual(start(mode, directory).returncode, 0)

    def test_effective_mount_and_counter_boundaries(self):
        # An inherited anonymous volume exists in all three containers, even when it does not cover PGDATA.
        for mode, path in CASES.items():
            m = effective_mount(mode, path, [VOLUME], ROOT_MOUNT + VOL_MOUNT, "overlayfs")
            self.assertEqual(m["volume"], "owned-volume" if mode == "fresh" else None)
            self.assertEqual(m["linux_mount"]["fs"], "ext4" if mode == "fresh" else "overlay")
        for path in (OVERLAY, str(Path(OVERLAY).parent)):
            with self.assertRaises(ValueError):
                effective_mount("fresh-overlay", OVERLAY, [dict(VOLUME, Destination=path)], ROOT_MOUNT, "overlay2")
        with self.assertRaises(ValueError):
            effective_mount("fresh", STOCK, [], ROOT_MOUNT, "overlayfs")
        with self.assertRaises(ValueError):
            effective_mount("prepared", OVERLAY, [], ROOT_MOUNT.replace(" - overlay", " - ext4"), "overlayfs")
        self.assertEqual(disk_delta({"vda": 2}, {"vda": 5}), {"vda": 1536})
        with self.assertRaises(ValueError):
            disk_delta({"vda": 5}, {"vda": 4})
        self.assertIsNone(io_counters("[io.stat]\n")["write_bytes_by_device"])
        self.assertEqual(io_counters("[io.stat]\n8:0 rbytes=50 wbytes=0\n")["write_bytes_by_device"], {"8:0": 0})

    def test_digest_and_image_layer_accounting(self):
        pin = "postgres@sha256:" + "a" * 64
        self.assertEqual(pinned_base("postgres:16", [pin]), "docker.io/library/" + pin)
        self.assertEqual(pinned_base("docker.io/library/" + pin, [pin]), "docker.io/library/" + pin)
        with self.assertRaises(ValueError):
            pinned_base("postgres@sha256:" + "b" * 64, [pin])
        base = [("old layer", 999)]
        self.assertEqual(added_image_history(base, [("env", 0), ("run", 32)] + base)["added_layer_bytes"], 32)
        with self.assertRaises(ValueError):
            added_image_history(base, [("different parent", 999)])

    def test_smoke_gates_all_widths_and_each_case_changes_order(self):
        calls, smoke = [], {"passed": False}
        def audit():
            self.assertEqual(len(calls), 6)
            return {"unique_containers": 6}
        measure_matrix(lambda *v: calls.append(v), [1, 4, 16], 1, smoke, audit)
        self.assertTrue(smoke["passed"])
        self.assertEqual(calls[:6], [(mode, 1, 0, w) for mode in CASES for w in ("application", "postgres")])
        self.assertEqual({v[0] for v in calls if v[1] == 16}, set(CASES))
        for pos in range(3):
            self.assertEqual(Counter(mode_order(i)[pos] for i in range(1, 7)), Counter(dict.fromkeys(CASES, 2)))
        def fail(mode, n, rnd, work):
            self.assertEqual((n, rnd), (1, 0))
            if mode == "fresh-overlay":
                raise ValueError("smoke failed")
        smoke = {"passed": False}
        with self.assertRaises(ValueError):
            measure_matrix(fail, [16], 5, smoke, audit)
        self.assertFalse(smoke["passed"])

    def test_timed_output_proves_case_and_canonical_sql(self):
        source = (ROOT / "ci/samples/go-app/integration/postgres_test.go").read_text()
        self.assertIn('const sql = "' + CHECK_SQL + '"', source)
        self.assertIn('"psql", "-XqAt", "-w", "-h", "127.0.0.1"', source)
        pg = dict(passed=True, container="example", fixture_mode="fresh-overlay", pgdata=OVERLAY,
                  fixture_restore_us=10, materialized_to_tcp_ready_us=20,
                  spans_us=dict.fromkeys(("create_to_ready", "readiness", "sql", "teardown"), [10, 20]))
        out = "verified SQL round trip on the final TCP server example\nMP_PG_RESULT " + json.dumps(pg)
        with patch("bench_postgres_fixture.command", return_value=subprocess.CompletedProcess([], 0, out, "")):
            for mode, passed in (("fresh-overlay", True), ("prepared", False), ("fresh", False)):
                job = timed_result([], {}, {"workload": "postgres", "mode": mode}, time.monotonic_ns())
                self.assertEqual(job["passed"], passed)


if __name__ == "__main__":
    unittest.main()
