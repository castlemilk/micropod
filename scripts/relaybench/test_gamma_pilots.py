"""Offline checks for the Gamma receipts and pilots. No benchmark process or socket is used."""
import gzip
import hashlib
import io
import json
import struct
import subprocess
import tarfile
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

import gamma_contrasts as evidence
import gamma_pilot as vm
import gamma_relay_pilot as relay


class GammaPilots(unittest.TestCase):
    def test_offline_plan_balances_the_scored_orders(self):
        orders = vm.plan(34199)
        self.assertEqual(orders, {"warmup": ["AB", "BA", "BA"], "scored": ["BA", "AB"]})
        self.assertEqual({tuple(vm.plan(seed)["scored"]) for seed in range(16)}, {("AB", "BA"), ("BA", "AB")})
        self.assertEqual(relay.configurations("distribution"), {"A": (2, True), "B": (2, False)})
        self.assertEqual(relay.configurations("workers"), {"A": (2, False), "B": (4, False)})
        self.assertEqual(relay.configurations("filters"), {"A": (2, False), "B": (2, False)})

    def test_replay_preserves_dirty_rounds_and_separates_callback_change(self):
        c = evidence.replay()["contrasts"]
        self.assertEqual(c["distribution_32"]["arms"]["baseline2"]["rounds_missing_request_count"], [5])
        self.assertEqual(c["distribution_32"]["arms"]["candidate2"]["verified_fresh_in_clean"], 2880)
        self.assertEqual(len(c["workers_32"]["paired_rounds"]), 3)
        self.assertIsNone(c["workers_32"]["arms"]["balanced4"]["cpu_s_per_gib"])
        self.assertAlmostEqual(c["workers_1"]["median_ratio"], 1.6392, places=4)
        self.assertAlmostEqual(c["workers_and_callback_1"]["median_ratio"], 1.6556, places=4)
        self.assertEqual(c["vm_peer_4"]["arms"]["confirm-orb"]["known_failed_requests"], 1)
        self.assertNotIn(12, c["vm_peer_4"]["paired_rounds"])
        self.assertIsNone(c["vcpu_4_vs_6"])

    def test_pinned_client_and_counters_replay(self):
        with gzip.open(evidence.VM, "rt") as f:
            archive = json.load(f)
        for arm, n, ok, drops in [("confirm-micropod", "1", True, 0), ("confirm-orb", "12", False, 1)]:
            with self.subTest(arm=arm):
                old = archive["phases"]["grace-holdout"]["runs"][arm][n]
                scope = archive["scopes"][arm]
                roles = {k: int(scope[k]) for k in ("vmm", "relay") if k in scope}
                fixture = dict(address="unused", name="unused", pids=roles)
                result = subprocess.CompletedProcess([], int(not ok), json.dumps(old["client"]), "")
                with patch.object(vm, "snapshot", side_effect=[old["before"], old["after"]]), \
                     patch.object(vm.subprocess, "run", return_value=result):
                    row = {}
                    vm.attempt(Path("/irrelevant"), fixture, vm.identities(old["before"]), row)
                self.assertEqual((row["clean"], row["fresh_failed"], row["reopened"]), (ok, drops, 0))
                self.assertGreater(row["host"]["vmm"]["runnable_s_per_s"], row["host"]["vmm"]["wait_s_per_s"])
                self.assertEqual(row["fresh_p99_us"], old["client"]["fresh_p99_us"])
                with patch.object(vm, "snapshot", return_value=old["before"]), patch.object(vm.subprocess, "run") as fixed:
                    with self.assertRaisesRegex(ValueError, "replaced"):
                        vm.attempt(Path("/irrelevant"), fixture, {}, {})
                    fixed.assert_not_called()

    def test_a_retired_scope_does_not_open_a_socket(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(vm, "command") as command:
            path = Path(temp)
            (path / "removed").touch()
            with self.assertRaisesRegex(ValueError, "retired"):
                vm.inspect(path, 4, False)
            command.assert_not_called()

    def test_manifest_reporting_engine_hashes_the_containers_config(self):
        container = {"Image": "manifest-id", "Config": {"Image": "image:bench"}}
        raw_config = b'{"architecture":"arm64"}'

        def export(args, stdout, **kwargs):
            self.assertEqual(args[-3:], ["image", "save", "image:bench"])
            with tarfile.open(mode="w", fileobj=stdout) as saved:
                for name, data in [("manifest.json", b'[{"Config":"config.json"}]'), ("config.json", raw_config)]:
                    header = tarfile.TarInfo(name)
                    header.size = len(data)
                    saved.addfile(header, io.BytesIO(data))

        with patch.object(vm.subprocess, "run", side_effect=export), \
             patch.object(vm, "command", side_effect=["manifest-id", "manifest-id", "changed"]):
            self.assertEqual(vm.image_config(["docker"], container), "sha256:" + hashlib.sha256(raw_config).hexdigest())
            with self.assertRaisesRegex(ValueError, "changed"):
                vm.image_config(["docker"], container)

    def test_peer_preflight_checks_orbstack_first_and_timing_preserves_ratio_direction(self):
        def inspect(scope, cpus, orb):
            key = scope.name
            return dict(engine=key, id=key, address=key, name=key, cpus=cpus, cpuset="0-3",
                        pids={"vmm": 2 if orb else 1})

        def attempt(tools, fixture, birth, row):
            row.update(clean=True, mib_s=2500 if row["arm"] == "A" else 3000)
            if row["phase"] == "scored" and row["pair"] == 1 and row["arm"] == "B":
                row.update(clean=False, fresh_failed=1)

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            a, b = root / "micro", root / "orb"
            a.mkdir()
            b.mkdir()
            args = Namespace(a=a, b=b, out=root / "check", seed=34199, mode="peer", tools=root, check=True)
            with patch.object(vm.platform, "node", return_value="Gamma-128GB"), \
                 patch.object(vm, "digest", side_effect=lambda p: vm.HASHES[p.name]), \
                 patch.object(vm, "inspect", side_effect=inspect) as inspected, \
                 patch.object(vm, "snapshot", return_value={"tasks": [{"pid": 1, "birth_ticks": 10}]}), \
                 patch.object(vm, "attempt", side_effect=attempt) as measured:
                vm.run(args, vm.plan(args.seed))
                self.assertEqual(inspected.call_args_list[0].args, (b, 4, True))
                measured.assert_not_called()
                args.out, args.check = root / "timing", False
                vm.run(args, vm.plan(args.seed))
                self.assertEqual(measured.call_count, 10)
                summary = json.loads((args.out / "complete.json").read_text())
                self.assertEqual(summary["ratio_direction"], "Micropod/OrbStack")
                self.assertEqual(summary["paired_ratios"], {"2": 2500 / 3000})
                self.assertEqual(json.loads((args.out / "scored-1-B.json").read_text())["fresh_failed"], 1)

    def test_relay_timeout_retains_its_pair_and_partial_counts(self):
        def measure(exe, seconds, ports, workers, kib, profile, legacy, progress):
            if progress.stem == "scored-1-B":
                progress.write_bytes(struct.pack("=II", 240, 237))
                raise RuntimeError("watchdog waiting for final probes")
            progress.write_bytes(struct.pack("=II", 240, 240))
            return dict(mib_s=100 * workers, p95_ms=1, cpu_seconds_per_gib=.5,
                        sample=dict(fresh_ns=[1_000_000] * 240, callback_events=128, tick_numer=1,
                                    tick_denom=1, elapsed_ns=6_000_000_000, cpu_ticks=9_000_000_000,
                                    runnable_ticks=12_000_000_000))

        with tempfile.TemporaryDirectory() as temp, patch.object(relay.platform, "node", return_value="Gamma-128GB"), \
             patch.object(relay, "build", return_value=(Path("/unused"), {})) as build, \
             patch.object(relay, "measure", side_effect=measure) as measured:
            args = Namespace(out=Path(temp) / "new", factor="workers", ports=32, seed=34199)
            relay.run(args, vm.plan(args.seed))
            self.assertEqual((build.call_count, measured.call_count), (1, 10))
            row = json.loads((args.out / "scored-1-B.json").read_text())
            self.assertFalse(row["clean"])
            self.assertEqual((row["submitted_without_reply"], row["never_submitted"]), (3, 0))
            self.assertEqual(json.loads((args.out / "complete.json").read_text())["candidate_over_control"], {"2": 2.0})

    def test_size_rejects_a_six_cpu_service_cpuset_before_timing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            a, b = root / "four", root / "six"
            a.mkdir()
            b.mkdir()
            def fixture(path, cpus, orb):
                return dict(engine=path.name, id=path.name, address=path.name, name=path.name,
                            cpuset=f"0-{cpus - 1}", pids={"vmm": cpus})
            args = Namespace(a=a, b=b, out=root / "out", seed=34199, mode="size", tools=root, check=False)
            with patch.object(vm.platform, "node", return_value="Gamma-128GB"), \
                 patch.object(vm, "digest", side_effect=lambda path: vm.HASHES[path.name]), \
                 patch.object(vm, "inspect", side_effect=fixture), patch.object(vm, "attempt") as timed:
                with self.assertRaisesRegex(ValueError, "pinned to CPUs 0-3"):
                    vm.run(args, vm.plan(args.seed))
                timed.assert_not_called()

    def test_filter_pilot_changes_only_the_build_flag(self):
        def fake_build(directory, revision, legacy, sanitize, *, batch_filters, stage_connect):
            self.assertTrue(stage_connect)
            return directory / "relay", {"batched": batch_filters}

        def measure(exe, seconds, ports, workers, kib, profile, legacy, progress):
            self.assertEqual((seconds, ports, workers, kib, profile, legacy), (6, 1, 2, 512, False, False))
            self.assertEqual(exe.parent.name, progress.stem.rsplit("-", 1)[1])
            progress.write_bytes(struct.pack("=II", 240, 240))
            return dict(mib_s=100, p95_ms=1, cpu_seconds_per_gib=.5,
                        sample=dict(fresh_ns=[1_000_000] * 240, callback_events=128, tick_numer=1,
                                    tick_denom=1, elapsed_ns=6_000_000_000, cpu_ticks=9, runnable_ticks=12))

        with tempfile.TemporaryDirectory() as temp, patch.object(relay.platform, "node", return_value="Gamma-128GB"), \
             patch.object(relay, "git", return_value=b"same-commit\n"), \
             patch.object(relay, "build", side_effect=fake_build) as build, patch.object(relay, "measure", side_effect=measure):
            args = Namespace(out=Path(temp) / "out", factor="filters", ports=1, seed=34201)
            relay.run(args, vm.plan(args.seed))
            self.assertEqual([(call.args[1:], call.kwargs) for call in build.call_args_list],
                             [(("same-commit", False, False), {"batch_filters": b, "stage_connect": True})
                              for b in (False, True)])
            receipt = json.loads((args.out / "plan.json").read_text())
            self.assertEqual(receipt["arm_binaries"], {"A": "False", "B": "batched"})
            self.assertEqual(receipt["binaries"], {"False": {"batched": False}, "batched": {"batched": True}})


if __name__ == "__main__":
    unittest.main()
