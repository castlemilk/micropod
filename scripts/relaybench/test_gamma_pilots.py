"""Offline checks for the Gamma receipts and pilots. No benchmark process or socket is used."""
import gzip
import hashlib
import io
import json
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

import gamma_contrasts as evidence
import gamma_pilot as vm
import gamma_relay_pilot as relay
from test_host_role import make_window


def owner_window(root, scopes, mode):
    fleet, release = make_window(root, time.time(), scopes)
    owner = json.loads(release.read_text())
    owner["modes"] = [mode]
    release.write_text(json.dumps(owner))
    return fleet, release


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
                fixture = dict(address="127.0.0.1:12000", name=arm, pids=roles)
                result = subprocess.CompletedProcess([], int(not ok), json.dumps(old["client"]), "")
                with patch.object(vm, "snapshot", side_effect=[old["before"], old["after"]]), \
                     patch.object(vm.subprocess, "run", return_value=result) as fixed:
                    row = {}
                    vm.attempt(Path("/irrelevant"), fixture, vm.identities(old["before"]), row)
                self.assertEqual(row["client_arguments"], ["http://127.0.0.1:12000", arm])
                self.assertEqual(fixed.call_args.args[0][1:], row["client_arguments"])
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
        cap = {"read_bytes": 256 * 1024}
        def inspect(scope, cpus, orb):
            key = scope.name
            return dict(engine=key, id=key, address=key, name=key, cpus=cpus, cpuset="0-3", relay_workers=2,
                        pids={"vmm": 2 if orb else 1}, callback_events=128, route=vm.DIRECT_ROUTE, **cap)

        def attempt(tools, fixture, birth, row, check):
            self.assertEqual(check()["scopes"], row["admission"]["scopes"])
            row.update(clean=True, mib_s=2500 if row["arm"] == "A" else 3000)
            if row["phase"] == "scored" and row["pair"] == 1 and row["arm"] == "B":
                row.update(clean=False, fresh_failed=1)

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            a, b = root / "micro", root / "orb"
            a.mkdir()
            b.mkdir()
            fleet, release = owner_window(root, (a, b), "peer")
            args = Namespace(a=a, b=b, out=root / "check", seed=34199, mode="peer", tools=root, check=True,
                             fleet=fleet, release=release)
            with patch.object(vm.platform, "node", return_value="Gamma-128GB"), \
                 patch.object(vm, "digest", side_effect=lambda p: vm.HASHES[p.name]), \
                 patch.object(vm, "inspect", side_effect=inspect) as inspected, \
                 patch.object(vm, "snapshot", return_value={"tasks": [{"pid": 1, "birth_ticks": 10}]}), \
                 patch.object(vm, "attempt", side_effect=attempt) as measured:
                with patch.dict(cap, clear=True), self.assertRaisesRegex(ValueError, "verified 256 KiB"):
                    vm.run(args, vm.plan(args.seed))
                measured.assert_not_called()
                args.out = root / "verified-check"
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
                initial = json.loads((args.out / "handoff.json").read_text())
                self.assertEqual(initial["mode"], "peer")
                self.assertEqual(initial["scopes"], [str(a.resolve()), str(b.resolve())])
                for path in list(args.out.glob("warmup-*.json")) + list(args.out.glob("scored-*.json")):
                    row = json.loads(path.read_text())
                    for label in ("admission", "admission_after"):
                        observation = row[label]
                        for key in ("mode", "scopes", "owner", "reservation", "fleet_time", "starts_at", "expires_at",
                                    "effective_disk_gate"):
                            self.assertEqual(observation[key], initial[key])
                    self.assertLessEqual(row["admission"]["observed_at"], row["admission_after"]["observed_at"])

                def withdraw(tools, fixture, birth, row, check):
                    owner = json.loads(release.read_text())
                    owner["reservation"] = "different-owner-window"
                    release.write_text(json.dumps(owner))
                    check()

                args.out = root / "withdrawn"
                measured.side_effect = withdraw
                with self.assertRaisesRegex(ValueError, "handoff changed"):
                    vm.run(args, vm.plan(args.seed))
                aborted = json.loads(next(args.out.glob("warmup-*.json")).read_text())
                self.assertFalse(aborted["clean"])
                self.assertIsNone(aborted["admission_after"])
                self.assertIn("handoff changed", aborted["error"])
                self.assertFalse((args.out / "complete.json").exists())

    def test_live_modes_require_exclusive_release_before_any_fixture_probe(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            a, b = root / "micro", root / "orb"
            a.mkdir()
            b.mkdir()
            fleet, release = make_window(root, time.time(), (a, b))  # Only authorizes host-role.
            for mode, pairs in (("size", 2), ("workers", 2), ("peer", 2), ("peer", 16)):
                for checking in (True, False):
                    args = Namespace(a=a, b=b, out=root / f"denied-{mode}-{pairs}-{checking}", seed=34203, mode=mode,
                                     tools=root, check=checking, fleet=fleet, release=release)
                    with self.subTest(pairs=pairs, checking=checking), \
                            patch.object(vm.platform, "node", return_value="Gamma-128GB"), \
                            patch.object(vm, "digest", side_effect=lambda p: (
                                vm.host_role.CLIENT_SHA256 if mode == "peer" and pairs == 16 and p.name == "fixed"
                                else vm.HASHES[p.name])), \
                            patch.object(vm, "inspect") as inspect, patch.object(vm, "attempt") as attempt:
                        with self.assertRaisesRegex(ValueError, "owner handoff"):
                            vm.run(args, vm.plan(args.seed, pairs))
                        inspect.assert_not_called()
                        attempt.assert_not_called()
                    cmd = [sys.executable, "-B", vm.__file__, "--mode", mode, "--a", str(a), "--b", str(b),
                           "--out", str(root / "cli"), "--check" if checking else "--run"]
                    if pairs == 16:
                        cmd.append("--holdout")
                    cli = subprocess.run(cmd, text=True, capture_output=True)
                    self.assertEqual(cli.returncode, 2)
                    self.assertIn("--fleet and --release", cli.stderr)
                    self.assertFalse((root / "cli").exists())

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
            fleet, release = owner_window(root, (a, b), "size")
            args = Namespace(a=a, b=b, out=root / "out", seed=34199, mode="size", tools=root, check=False,
                             fleet=fleet, release=release)
            with patch.object(vm.platform, "node", return_value="Gamma-128GB"), \
                 patch.object(vm, "digest", side_effect=lambda path: vm.HASHES[path.name]), \
                 patch.object(vm, "inspect", side_effect=fixture), patch.object(vm, "attempt") as timed:
                with self.assertRaisesRegex(ValueError, "pinned to CPUs 0-3"):
                    vm.run(args, vm.plan(args.seed))
                timed.assert_not_called()

    def test_worker_vm_pair_requires_the_observed_fixed_budget_and_same_build(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            a, b = root / "two", root / "four"
            a.mkdir()
            b.mkdir()
            fleet, release = owner_window(root, (a, b), "workers")
            args = Namespace(a=a, b=b, out=root / "out", seed=34202, mode="workers", tools=root, check=False,
                             fleet=fleet, release=release)
            common = dict(cpuset="0-3", kernel_image_sha256=vm.STOCK_KERNEL, release="7.3.5-micropod", engine_version="same",
                          cli_sha256="same-digest", route=vm.DIRECT_ROUTE, service_env_sha256="same-env")
            fixtures = {p: dict(common, engine=p.name, id=p.name, address=p.name, name=p.name, instance=p.name,
                                kernel=str(p / "Image"), worker=p.name, pids={"vmm": n}, relay_workers=n, callback_events=128,
                                read_bytes=256 * 1024)
                        for p, n in ((a, 2), (b, 4))}
            def inspect(path, cpus, orb):
                self.assertEqual((cpus, orb), (4, False))
                return fixtures[path]
            def measure(tools, f, birth, row, check):
                self.assertEqual(check()["mode"], "workers")
                row.update(clean=True, mib_s=2700 if row["arm"] == "A" else 3000)
            with patch.object(vm.platform, "node", return_value="Gamma-128GB"), \
                 patch.object(vm, "digest", side_effect=lambda path: vm.HASHES[path.name]), \
                 patch.object(vm, "inspect", side_effect=inspect), patch.object(vm, "snapshot", return_value={"tasks": []}), \
                 patch.object(vm, "attempt", side_effect=measure) as timed:
                for i, (arm, key, wrong, message) in enumerate((
                    (a, "read_bytes", None, "verified 256 KiB"),
                    (a, "callback_events", None, "verified 128-event"),
                    (b, "callback_events", 24, "verified 128-event"),
                    (b, "relay_workers", 2, "needs 4 relay workers"),
                    (b, "cli_sha256", "other", "differ in cli_sha256"),
                    (b, "kernel_image_sha256", "other", "differ in kernel_image_sha256"),
                )):
                    args.out = root / str(i)
                    with patch.dict(fixtures[arm], {key: wrong}), self.assertRaisesRegex(ValueError, message):
                        vm.run(args, vm.plan(args.seed))
                    timed.assert_not_called()
                args.out = root / "paired"
                vm.run(args, vm.plan(args.seed))
                result = json.loads((args.out / "complete.json").read_text())
                self.assertEqual(timed.call_count, 10)
                self.assertEqual(result["median_paired_mib_s_difference"], 300)
                self.assertEqual(result["clean_scored"], {"A": 2, "B": 2})
                self.assertIsNone(result["bootstrap_ci95"])

    def test_peer_holdout_preserves_resource_parity_and_balanced_blocks(self):
        arms = vm.arm_settings("peer", workers=4, peer_vcpus=6)
        self.assertEqual(arms["A"], dict(engine="Micropod", vcpus=6, relay_workers=4, callback_events=128, read_bytes=262144))
        self.assertEqual(arms["B"], dict(engine="OrbStack", vcpus=6, relay_workers=None, callback_events=None))
        holdout = vm.plan(34203, 16)
        self.assertEqual(len(holdout["warmup"]), 3)
        self.assertEqual(len(holdout["scored"]), 16)
        for i in range(0, 16, 2):
            self.assertEqual(set(holdout["scored"][i:i+2]), {"AB", "BA"})
        with self.assertRaisesRegex(ValueError, "only to the OrbStack"):
            vm.arm_settings("workers", peer_vcpus=6)

    def test_six_vcpu_holdout_reports_dirty_candidate_round(self):
        def inspect(scope, cpus, orb):
            self.assertEqual(cpus, 6)
            return dict(engine=scope.name, id=scope.name, address="127.0.0.1:9002" if orb else "127.0.0.1:9001",
                        name=scope.name, cpuset="0-3",
                        relay_workers=None if orb else 4, callback_events=None if orb else 128,
                        read_bytes=None if orb else 256 * 1024,
                        route=vm.DIRECT_ROUTE, pids={"vmm": 2 if orb else 1})

        def measure(tools, fixture, birth, row, check):
            self.assertEqual(check()["mode"], "peer")
            dirty = row["phase"] == "scored" and row["pair"] == 1 and row["arm"] == "A"
            row.update(clean=not dirty, mib_s=3000 if row["arm"] == "A" else 2700, fresh_failed=int(dirty),
                       client_arguments=["http://" + fixture["address"], fixture["name"]],
                       stdout=json.dumps({"published_ports": 1, "fresh_p50_us": 1200}))

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            a, b = root / "micro", root / "orb"
            a.mkdir()
            b.mkdir()
            fleet, release = owner_window(root, (a, b), "peer")
            args = Namespace(a=a, b=b, out=root / "out", seed=34203, mode="peer", tools=root, check=False,
                             fleet=fleet, release=release)
            with patch.object(vm.platform, "node", return_value="Gamma-128GB"), \
                 patch.object(vm, "digest", side_effect=lambda p: dict(vm.HASHES, fixed=vm.host_role.CLIENT_SHA256)[p.name]), \
                 patch.object(vm, "inspect", side_effect=inspect), patch.object(vm, "snapshot", return_value={"tasks": []}), \
                 patch.object(vm, "attempt", side_effect=measure) as timed:
                vm.run(args, vm.plan(args.seed, 16), workers=4, peer_vcpus=6)
            result = json.loads((args.out / "complete.json").read_text())
            self.assertEqual(json.loads((args.out / "plan.json").read_text())["tools"]["fixed"], vm.host_role.CLIENT_SHA256)
            self.assertEqual(timed.call_count, 38)
            self.assertEqual(result["clean_scored"], {"A": 15, "B": 16})
            self.assertEqual(result["bootstrap_ci95"], [3000 / 2700] * 2)
            self.assertNotIn("1", result["paired_ratios"])
            self.assertEqual(json.loads((args.out / "scored-1-A.json").read_text())["fresh_failed"], 1)

            def multiport(tools, fixture, birth, row, check):
                measure(tools, fixture, birth, row, check)
                row["stdout"] = json.dumps({"published_ports": 32, "fresh_p50_us": 1200})

            args.out = root / "multiport"
            with patch.object(vm.platform, "node", return_value="Gamma-128GB"), \
                 patch.object(vm, "digest", side_effect=lambda p: dict(vm.HASHES, fixed=vm.host_role.CLIENT_SHA256)[p.name]), \
                 patch.object(vm, "inspect", side_effect=inspect), patch.object(vm, "snapshot", return_value={"tasks": []}), \
                 patch.object(vm, "attempt", side_effect=multiport) as timed:
                with self.assertRaisesRegex(ValueError, "one published port"):
                    vm.run(args, vm.plan(args.seed, 16), workers=4, peer_vcpus=6)
            self.assertEqual(timed.call_count, 1)
            rejected = json.loads(next(args.out.glob("warmup-*.json")).read_text())
            self.assertFalse(rejected["clean"])
            self.assertEqual(json.loads(rejected["stdout"])["published_ports"], 32)
            self.assertFalse((args.out / "complete.json").exists())

    def test_replaced_relay_executable_cannot_supply_a_matching_hash(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "micropod"
            path.write_bytes(b"candidate")
            st = path.stat()
            with patch.object(vm, "command", return_value=f"p77\nftxt\nD{hex(st.st_dev)}\ni{st.st_ino}"):
                self.assertEqual(vm.mapped_digest(path, 77), hashlib.sha256(b"candidate").hexdigest())
            with patch.object(vm, "command", return_value=f"p77\nftxt\nD{hex(st.st_dev)}\ni{st.st_ino + 1}"):
                with self.assertRaisesRegex(ValueError, "does not map"):
                    vm.mapped_digest(path, 77)

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
