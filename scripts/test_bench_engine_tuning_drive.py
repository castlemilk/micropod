"""Check ownership and cleanup for the engine tuning harness."""

from contextlib import redirect_stderr
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import bench_engine_tuning as bench
from sibling_dense_load import (
    CONTAINERS, CPU_GROUP_LABEL, MEMORY_BYTES, NATIVE_GROUP_NETWORK_SCRIPT, SPREAD_AFFINITY_SCRIPT, TRACE_SCRIPT,
    DenseCompileLoad, GuestClock, Sample,
    align_worker, compiler_quota_us, foreground_window, parse_compiler_spread_cpus,
)


BOOT_ID = "11111111-2222-3333-4444-555555555555"


class BenchmarkWorkerDriveTest(unittest.TestCase):
    def test_disk_holder_timeout_retries_and_requires_a_definitive_empty_result(self):
        with tempfile.TemporaryDirectory() as root:
            disk = Path(root) / "worker.ext4"
            disk.touch()
            receipts = {"created": {}}
            drive = SimpleNamespace(disk=disk, receipts=receipts, close=lambda: receipts)
            worker = SimpleNamespace(proc=None, drive=drive, dir=Path(root))
            timeout = subprocess.TimeoutExpired(["lsof"], 5)
            empty = subprocess.CompletedProcess(["lsof"], 1, "", "")
            with patch.object(bench, "run", side_effect=[timeout, empty]) as listing:
                result = bench.stop_worker(worker, 1)
            self.assertEqual(listing.call_count, 2)
            self.assertGreater(listing.call_args_list[1].kwargs["timeout"], listing.call_args_list[0].kwargs["timeout"])
            self.assertEqual(result["shutdown"]["disk_holders"], [])
            self.assertEqual(result["shutdown"]["disk_query_timeouts"], 1)
            del receipts["shutdown"]
            with (patch.object(bench, "run", side_effect=timeout),
                  patch.object(bench.time, "monotonic", side_effect=[0, 46])):
                with self.assertRaisesRegex(RuntimeError, "could not verify disk holders"):
                    bench.stop_worker(worker, 1)
            self.assertNotIn("shutdown", receipts)
            self.assertEqual(receipts["retirement"]["disk_query_timeouts"], 1)

    def test_unexpected_unmounted_home_survives_early_failure(self):
        with tempfile.TemporaryDirectory() as root:
            owned = Path(root) / "owned"
            owned.mkdir()
            drive = bench.BenchmarkWorkerDrive(owned)
            sentinel = drive.home / "existing"
            sentinel.write_bytes(b"preexisting")
            with self.assertRaisesRegex(RuntimeError, "unexpected worker files"):
                drive.close()
            self.assertEqual(sentinel.read_bytes(), b"preexisting")

    def test_both_backends_require_the_drive_before_vm_or_rootfs_setup(self):
        path = Path("/unused")
        workers = [
            bench.WorkerHandle("drive-test", path, path, path, "", path),
            bench.HVFWorkerHandle("drive-test", path, path, path, path, path),
        ]
        for worker in workers:
            self.addCleanup(worker.stop)
            if isinstance(worker, bench.WorkerHandle):
                worker.extra_env = {"MICROPOD_CI_HOME": "/unowned", "MICROPOD_CI_VMM": "hvf"}
                self.assertEqual(worker.env()["MICROPOD_CI_HOME"], str(worker.drive.home))
                self.assertEqual(worker.env()["MICROPOD_CI_VMM"], "vz")
            with self.subTest(backend=type(worker).__name__), \
                    patch.object(worker.drive, "attach", side_effect=RuntimeError("drive unavailable")), \
                    patch.object(bench, "run") as copy, patch.object(bench.subprocess, "Popen") as launch:
                with self.assertRaisesRegex(RuntimeError, "drive unavailable"):
                    worker.start()
                copy.assert_not_called()
                launch.assert_not_called()
                self.assertEqual(worker.home, worker.drive.home)
                self.assertEqual(getattr(worker, "disk", worker.home / "worker.ext4"), worker.drive.disk)

    def test_ordinary_volume_is_rejected_and_detach_failure_preserves_the_disk(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            drive = bench.BenchmarkWorkerDrive(directory)
            drive.disk.write_bytes(b"worker disk")
            drive.receipts["created"] = {}
            with patch.object(drive.apfs, "verify", return_value={"volume": {"dev": directory.stat().st_dev}}):
                with self.assertRaisesRegex(RuntimeError, "dedicated volume"):
                    drive.verify_live(1)
            with patch.object(drive.apfs, "detach", side_effect=RuntimeError("busy image")):
                with self.assertRaisesRegex(RuntimeError, "busy image"):
                    drive.close()
            self.assertEqual(drive.disk.read_bytes(), b"worker disk")


class SiblingBenchmarkCleanupTest(unittest.TestCase):
    def test_cleanup_attempts_both_resource_types_and_rejects_leftovers(self):
        sock = Path("/unused/docker.sock")
        label = "com.micropod.benchmark.scope=test"
        listed = [(["owned-container"], ["owned-network"]), ([], ["owned-network"])]
        responses = [SimpleNamespace(returncode=0), SimpleNamespace(returncode=1, stderr="network still in use")]
        with patch.object(bench, "sibling_resources", side_effect=listed) as read, \
                patch.object(bench, "docker", side_effect=responses) as delete:
            with self.assertRaisesRegex(RuntimeError, "owned-network.*network still in use"):
                bench.cleanup_sibling_resources(sock, label)
        self.assertEqual(read.call_count, 2)
        self.assertEqual([call.args[1:] for call in delete.call_args_list],
                         [("rm", "-f", "owned-container"), ("network", "rm", "owned-network")])


class SiblingBenchmarkComparisonTest(unittest.TestCase):
    def test_live_sibling_cli_forwards_spread_and_rejects_bad_placement_before_docker(self):
        with tempfile.TemporaryDirectory() as directory:
            args = ["--hvf-socket", "hvf.sock", "--orbstack-socket", "orb.sock", "--workspace", directory,
                    "--out", str(Path(directory) / "receipt.json")]
            spread = ["--compiler-spread-cpus", "0,1,2,3"]
            native = "--native-compiler-groups"
            for options in (spread, ["--dense", *spread, "--compiler-cpus", "0-3"],
                            ["--dense", "--compiler-spread-cpus", "0,1,1"], [native, *spread],
                            ["--dense", native], ["--dense", native, "--compiler-spread-cpus", "0,1,2"]):
                with self.subTest(options=options), patch.object(bench, "docker") as docker, \
                        redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
                    bench.live_siblings([*args, *options])
                self.assertEqual(error.exception.code, 2)
                docker.assert_not_called()
            info = [SimpleNamespace(stdout='{"ServerVersion":"micropod"}'),
                    SimpleNamespace(stdout='{"OperatingSystem":"OrbStack"}')]
            with patch.object(bench, "docker", side_effect=info), \
                    patch.object(bench, "bench_live_sibling_pairs", return_value={}) as suite:
                bench.live_siblings([*args, "--dense", *spread, native])
            self.assertEqual(suite.call_args.kwargs["compiler_spread_cpus"], "0,1,2,3")
            self.assertTrue(suite.call_args.kwargs["native_compiler_groups"])

    def test_oci_manifest_links_a_config_id_to_the_same_image_manifest(self):
        config = "sha256:" + "c" * 64
        encoded = json.dumps({"schemaVersion": 2, "config": {"digest": config}, "layers": [{"digest": "sha256:" + "d" * 64}]}).encode()
        digest = "sha256:" + hashlib.sha256(encoded).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "manifest.json"
            manifest.write_bytes(encoded)
            ids = [SimpleNamespace(stdout=value) for value in (config, digest)]
            with patch.object(Path, "is_socket", return_value=True), patch.object(Path, "samefile", return_value=False), \
                    patch.object(bench, "docker", side_effect=ids), patch.object(bench, "_bench_sibling_pairs", return_value={}):
                scored = bench.bench_live_sibling_pairs("hvf.sock", "orb.sock", directory, probe_image="qa:fixture", probe_manifest=manifest)
            self.assertEqual(scored["probe_image_id"], digest)

    def test_different_images_cannot_be_scored_as_the_same_probe(self):
        hashes = [SimpleNamespace(stdout="sha256:" + digit * 64) for digit in ("a", "b")]
        with tempfile.TemporaryDirectory() as directory, patch.object(Path, "is_socket", return_value=True), \
                patch.object(Path, "samefile", return_value=False), patch.object(bench, "docker", side_effect=hashes), \
                patch.object(bench, "_bench_sibling_pairs") as measure:
            with self.assertRaisesRegex(ValueError, "same immutable probe image"):
                bench.bench_live_sibling_pairs("hvf.sock", "orb.sock", directory, probe_image="qa:fixture")
            measure.assert_not_called()

    def test_waits_for_a_valid_ipv4_address_from_the_selected_network(self):
        def inspect(address):
            record = {"State": {"Running": True}, "NetworkSettings": {"Networks": {"selected": {"IPAddress": address}}}}
            return SimpleNamespace(stdout=json.dumps([record]))

        with patch.object(bench, "docker", side_effect=[inspect(""), inspect("10.2.3.4")]), \
                patch.object(bench.time, "sleep"):
            self.assertEqual(bench.sibling_address("/unused.sock", "container", "selected"), "10.2.3.4")

    def test_unknown_reference_still_requires_verified_sockets_and_complete_bulk(self):
        sample = {"mode": "bulk", "streams": 32, "iterations": 24, "bytes": 6 << 30,
                  "reopened_connections": 0, "mib_s": 24000.0, "accepted_tcp_congestion": ["reno"] * 32}
        self.assertTrue(bench.verified_sibling_bulk(sample, None))
        self.assertFalse(bench.verified_sibling_bulk(sample, "cubic"))
        for failed in ({"accepted_tcp_congestion": ["reno"] * 31}, {"bytes": 10}, {"reopened_connections": 1}):
            with self.subTest(failed=failed):
                self.assertFalse(bench.verified_sibling_bulk(sample | failed, None))
        longer = sample | {"iterations": 240, "bytes": 60 << 30}
        self.assertTrue(bench.verified_sibling_bulk(longer, None, bursts=240))
        self.assertFalse(bench.verified_sibling_bulk(longer, None))

    def test_live_comparison_uses_stock_reference_and_swaps_order(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            names = ("netbench-linux", "quiet-http")
            for name in names:
                (workspace / name).write_bytes(name.encode())
            hashes = {name: hashlib.sha256(name.encode()).hexdigest() for name in names}
            result = {"probe_sha256": hashes, "raw": {"sibling_6gib_bulk_mibs": [25000.0]}}
            with patch.object(Path, "is_socket", return_value=True), patch.object(Path, "samefile", return_value=False), \
                    patch.object(bench, "bench_in_guest_suite", return_value=result) as suite:
                pairs = bench.bench_live_sibling_pairs("/unused/hvf.sock", "/unused/orb.sock", workspace, pairs=2)
            self.assertEqual([pair["order"] for pair in pairs["pairs"]], [("orbstack", "cubic"), ("cubic", "orbstack")])
            self.assertEqual([call.kwargs["sibling_cc"] for call in suite.call_args_list], [None, "cubic", "cubic", None])
            self.assertTrue(all(call.kwargs["report_congestion"] for call in suite.call_args_list))

    def test_only_the_verified_micropod_socket_uses_native_compiler_groups(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            for name in ("netbench-linux", "quiet-http", "compile"):
                (workspace / name).write_bytes(name.encode())
            (workspace / "compile").chmod(0o755)
            hashes = {name: hashlib.sha256(name.encode()).hexdigest() for name in ("netbench-linux", "quiet-http")}
            result = {"probe_sha256": hashes, "raw": {"sibling_6gib_bulk_mibs": [25000.0]}}
            hvf, orb = map(Path, ("/unused/hvf.sock", "/unused/orb.sock"))
            observed = []

            def measure(load, sock, benchmark):
                observed.append((sock, load.native_compiler_groups))
                return benchmark()

            with patch.object(Path, "is_socket", return_value=True), patch.object(Path, "samefile", return_value=False), \
                    patch.object(bench, "docker", return_value=SimpleNamespace(stdout="micropod\n")) as docker, \
                    patch.object(bench, "bench_in_guest_suite", return_value=result), \
                    patch.object(DenseCompileLoad, "measure", measure):
                options = {"pairs": 2, "dense_compile": True, "compiler_spread_cpus": "0,1,2,3",
                           "native_compiler_groups": True}
                bench.bench_live_sibling_pairs(hvf, orb, workspace, **options)
                docker.assert_called_once_with(hvf, "info", "--format", "{{.ServerVersion}}", timeout=15)
                docker.return_value = SimpleNamespace(stdout="29.5\n")
                with self.assertRaisesRegex(ValueError, "require a Micropod Docker endpoint"):
                    bench.bench_live_sibling_pairs(hvf, orb, workspace, **options)
            self.assertEqual(observed, [(orb, False), (hvf, True), (hvf, True), (orb, False)])

    def test_sustained_runs_use_size_specific_result_key(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            names = ("netbench-linux", "quiet-http")
            for name in names:
                (workspace / name).write_bytes(name.encode())
            hashes = {name: hashlib.sha256(name.encode()).hexdigest() for name in names}
            result = {"probe_sha256": hashes, "raw": {"sibling_bulk_mibs": [9000.0]}}
            with patch.object(Path, "is_socket", return_value=True), patch.object(Path, "samefile", return_value=False), \
                    patch.object(bench, "bench_in_guest_suite", return_value=result) as suite:
                pairs = bench.bench_live_sibling_pairs(
                    "/unused/hvf.sock", "/unused/orb.sock", workspace, pairs=2, bulk_bursts=240,
                )
            self.assertEqual(pairs["median_bulk_gain_pct"], 0)
            self.assertTrue(all(call.kwargs["bulk_bursts"] == 240 for call in suite.call_args_list))
            self.assertEqual(bench.bulk_rate_key(24), "sibling_6gib_bulk_mibs")


class DenseCompileLoadTest(unittest.TestCase):
    def test_dense_arm_checks_progress_and_cleans_every_owned_id(self):
        for bad_quota, allowed_cpus, memory in (
            (False, "0-1", MEMORY_BYTES), (True, "0-1", MEMORY_BYTES),
            (False, "0-3", MEMORY_BYTES), (False, "0-1", MEMORY_BYTES + 4096),
        ):
            with self.subTest(bad_quota=bad_quota, allowed_cpus=allowed_cpus, memory=memory), \
                    tempfile.TemporaryDirectory() as directory:
                workspace = Path(directory)
                compiler = workspace / "compile"
                compiler.write_bytes(b"test compiler identity")
                compiler.chmod(0o755)
                counts = {}

                def docker(_socket, *args, **_options):
                    if args[0] == "run":
                        index = int(args[args.index("--name") + 1].rsplit("-", 1)[1])
                        identifier = f"{index + 1:064x}"
                        self.assertEqual(args[args.index("--network") + 1], "none")
                        self.assertEqual(args[args.index("--cpuset-cpus") + 1], "0-1")
                        self.assertEqual(args[args.index("--cpu-quota") + 1], "1000")
                        self.assertEqual(args[args.index("--cpu-period") + 1], "16000")
                        self.assertEqual(args[args.index("--memory") + 1], "128m")
                        counts[identifier] = 0
                        return SimpleNamespace(stdout=identifier)
                    if args[0] == "ps":
                        self.assertIn("--no-trunc", args)
                        return SimpleNamespace(stdout="\n".join(counts))
                    if args[0] == "exec":
                        identifier = args[1]
                        counts[identifier] += 1
                        count = counts[identifier]
                        quota = 999 if bad_quota and int(identifier, 16) == 1 else 1000
                        output = (f"limits 2 {quota} 16000 {memory} {allowed_cpus} {BOOT_ID} 0 0\n"
                                  f"{load.compiler_sha256}  /mpw/compile\n"
                                  f"{load.source_sha256}  /tmp/micropod-dense/source.go\n")
                        if args[4] == TRACE_SCRIPT:
                            output += "0 - 10.00 10.00 0 0 0 0\n"
                            for i in range(1, count + 1):
                                output += f"{i} {9 + i}.10 {10 + i}.00 {10 + i}.00 {i * 1000} {i * 10} {i} {i * 300}\n"
                            # cat can capture a partial last record, even if the
                            # last numeric field already has some of its digits.
                            output += "4 13.10 14.00 14.00 4000 40 4 1\n- - 14.50 14.50 4500 45 4 1300\n"
                        else:
                            output += f"{count} {9 + count}.10 {10 + count}.00 {10 + count}.00 {count * 1000} 10 1 300\n"
                        return SimpleNamespace(stdout=output, returncode=0)
                    self.assertEqual(args[:2], ("rm", "-f"))
                    counts.pop(args[2])
                    return SimpleNamespace(returncode=0)

                def measure():
                    self.assertFalse(bad_quota)
                    self.assertEqual(list(counts.values()), [2] * CONTAINERS)
                    window = foreground_window(
                        f"micropod-dense-clock {BOOT_ID} 0 0 12.20 13.30\n", 1.0, 1, 2,
                    )
                    return {"raw": {"bulk_guest_windows": [window]}}

                load = DenseCompileLoad(docker, workspace, compiler_cpus="0-1", compiler_period_us=16_000)
                if bad_quota:
                    with self.assertRaisesRegex(RuntimeError, "quota is 999"):
                        load.measure("test socket", measure)
                elif memory != MEMORY_BYTES:
                    with self.assertRaisesRegex(RuntimeError, "memory limit"):
                        load.measure("test socket", measure)
                elif allowed_cpus != "0-1":
                    with self.assertRaisesRegex(RuntimeError, "can run on CPUs"):
                        load.measure("test socket", measure)
                else:
                    telemetry = load.measure("test socket", measure)["dense_compile"]
                    workers = telemetry["workers"]
                    self.assertEqual(len(workers), CONTAINERS)
                    self.assertTrue(all(worker["tail"] == 4 for worker in workers))
                    self.assertTrue(all(worker["after"] == 3 for worker in workers))
                    self.assertEqual(telemetry["foreground"][0]["workers_with_cpu_brackets"], CONTAINERS)
                    self.assertEqual(telemetry["foreground"][0]["reported_completions_bounds"], [32, 64])
                    self.assertNotIn("requested_compiler_spread_cpus", telemetry)
                    self.assertNotIn("requested_cpu", workers[0])
                self.assertEqual(counts, {})

    def test_spread_checks_live_masks_and_exact_scope_on_both_boundaries(self):
        masks = ("3", "1", "0", "2")
        failures = {
            "moved": "live CPU mask", "scope": "scope does not match", "unbalanced": "groups are unbalanced",
            "eth0": "offline native compiler has eth0", "generation": "identity or process generation changed",
            "label": "did not report its owned offline CPU group", "network": "did not report its owned offline CPU group",
        }
        cases = [(False, fault) for fault in (None, "moved", "scope")]
        cases += [(True, fault) for fault in (None, *failures)]
        for native, failure in cases:
            with self.subTest(native=native, failure=failure), tempfile.TemporaryDirectory() as directory:
                workspace = Path(directory)
                compiler = workspace / "compile"
                compiler.write_bytes(b"test compiler identity")
                compiler.chmod(0o755)
                ids = {}
                observed = []
                measured = False
                assignment_order = masks[::-1] if native else masks

                def docker(_sock, *args, **_options):
                    if args[0] == "run":
                        name = args[args.index("--name") + 1]
                        index = int(name.rsplit("-", 1)[1])
                        identifier = f"{index + 1:064x}"
                        mask = assignment_order[index % len(masks)]
                        labels = dict(args[i + 1].split("=", 1) for i, arg in enumerate(args) if arg == "--label")
                        if native:
                            self.assertNotIn("--cpuset-cpus", args)
                            owner = labels["com.micropod.benchmark.dense"]
                            self.assertEqual(labels[CPU_GROUP_LABEL], f"{owner}-{index:02d}")
                            if failure == "unbalanced" and index == 0:
                                mask = assignment_order[1]
                            if failure == "label" and index == 0:
                                labels[CPU_GROUP_LABEL] = "wrong-job"
                        else:
                            self.assertNotIn(CPU_GROUP_LABEL, labels)
                            self.assertEqual(args[args.index("--cpuset-cpus") + 1], mask)
                        self.assertEqual(args[args.index("--cpu-quota") + 1], "6250")
                        self.assertEqual(args[args.index("--cpu-period") + 1], "100000")
                        self.assertEqual(args[args.index("--network") + 1], "none")
                        ids[identifier] = {
                            "Id": identifier, "Name": f"/{name}", "Config": {"Labels": labels},
                            "HostConfig": {"CpusetCpus": mask,
                                           "NetworkMode": "bridge" if failure == "network" and index == 0 else "none"},
                            "State": {"Running": True, "StartedAt": "2026-11-25T00:00:00Z"},
                        }
                        return SimpleNamespace(stdout=identifier)
                    if args[0] == "ps":
                        self.assertTrue(args[args.index("--filter") + 1].startswith("label=com.micropod.benchmark.dense="))
                        visible = list(ids)
                        if measured:
                            observed.append(len(ids))
                            if failure == "scope" and len(observed) == 1:
                                visible.append(visible[0])
                        return SimpleNamespace(stdout="\n".join(visible))
                    if args[0] == "inspect":
                        self.assertTrue(native)
                        self.assertEqual(args[1:3], ("--type", "container"))
                        self.assertEqual(set(args[3:]), set(ids))
                        rows = [ids[identifier] for identifier in reversed(args[3:])]
                        if failure == "generation" and measured:
                            rows[0]["State"]["StartedAt"] = "2026-11-25T00:00:01Z"
                        return SimpleNamespace(stdout=json.dumps(rows))
                    if args[0] == "exec":
                        self.assertTrue(args[4].startswith(SPREAD_AFFINITY_SCRIPT))
                        self.assertEqual(NATIVE_GROUP_NETWORK_SCRIPT in args[4], native)
                        mask = ids[args[1]]["HostConfig"]["CpusetCpus"]
                        trace = args[4].endswith(TRACE_SCRIPT)
                        first_worker_trace = trace and int(args[1], 16) == 1
                        live = "0-3" if failure == "moved" and first_worker_trace else mask
                        output = f"affinity {live}\n"
                        if native:
                            output += "eth0 present\n" if failure == "eth0" and first_worker_trace else "eth0 absent\n"
                        output += (f"limits 2 6250 100000 {MEMORY_BYTES} {mask} {BOOT_ID} 0 0\n"
                                   f"{load.compiler_sha256}  /mpw/compile\n"
                                   f"{load.source_sha256}  /tmp/micropod-dense/source.go\n")
                        if trace:
                            output += ("0 - 10.00 10.00 0 0 0 0\n1 10.20 11.00 11.00 1000 10 1 300\n"
                                       "2 11.20 12.00 12.00 2000 20 2 600\n"
                                       "3 12.20 13.00 13.00 3000 30 3 900\n\n- - 14.00 14.00 4000 40 3 900\n")
                        else:
                            n = reads.get(args[1], 0) + 1
                            reads[args[1]] = n
                            output += f"{n} {9 + n}.20 {10 + n}.00 {10 + n}.00 {n * 1000} 10 1 300\n"
                        return SimpleNamespace(stdout=output, returncode=0)
                    self.assertEqual(args[:2], ("rm", "-f"))
                    ids.pop(args[2])
                    return SimpleNamespace(returncode=0)

                def measure():
                    nonlocal measured
                    self.assertEqual(list(reads.values()), [2] * CONTAINERS)
                    measured = True
                    return {}

                reads = {}
                load = DenseCompileLoad(docker, workspace, compiler_spread_cpus=",".join(masks), native_compiler_groups=native)
                if failure:
                    with self.assertRaisesRegex(RuntimeError, failures[failure]):
                        load.measure("test socket", measure)
                    self.assertEqual(measured, failure not in ("unbalanced", "label", "network"))
                else:
                    score = load.measure("test socket", measure)["dense_compile"]
                    self.assertEqual(score["requested_compiler_spread_cpus"], [3, 1, 0, 2])
                    self.assertEqual(score["compiler_workers_per_cpu"], dict.fromkeys(masks, 8))
                    self.assertEqual([w["allowed_cpus"] for w in score["workers"]], list(assignment_order) * 8)
                    if native:
                        self.assertEqual(score["compiler_placement"], "native-cpu-group")
                        self.assertEqual(len({w["cpu_group"] for w in score["workers"]}), CONTAINERS)
                        for worker in score["workers"]:
                            self.assertIs(worker["eth0_present"], False)
                            self.assertEqual(str(worker["engine_assigned_cpu"]), worker["live_allowed_cpus"])
                            self.assertNotIn("requested_cpu", worker)
                    else:
                        self.assertEqual(score["compiler_placement"], "explicit-cpuset")
                        self.assertEqual([w["requested_cpu"] for w in score["workers"]], [3, 1, 0, 2] * 8)
                    self.assertEqual(score["compile_count_delta"], CONTAINERS)
                self.assertEqual(ids, {})

    def test_spread_validation_preserves_order_and_rejects_non_unique_cpu_ids(self):
        self.assertEqual(parse_compiler_spread_cpus("3, 1,0,2"), ("3", "1", "0", "2"))
        for bad in ("", "0,0", "0,", "0-3", "-1,0", "01,1", ",".join(map(str, range(CONTAINERS + 1)))):
            with self.subTest(bad=bad), self.assertRaisesRegex(ValueError, "distinct comma-separated CPU IDs"):
                parse_compiler_spread_cpus(bad)
        with self.assertRaisesRegex(ValueError, "mutually exclusive"):
            DenseCompileLoad(None, None, compiler_cpus="0-3", compiler_spread_cpus="0,1,2,3")

    def test_period_keeps_exact_fraction_and_meets_kernel_minimum(self):
        for period, quota in ((16_000, 1000), (32_000, 2000), (100_000, 6250), (1_000_000, 62_500)):
            self.assertEqual(compiler_quota_us(period), quota)
        for bad in (15_984, 16_001, 1_000_016, 100_000.0):
            with self.assertRaisesRegex(ValueError, "compiler period"):
                compiler_quota_us(bad)

    def test_foreground_window_normalizes_guest_offsets_and_checks_duration(self):
        window = foreground_window(
            f"wrapper message\nmicropod-dense-clock {BOOT_ID} 2 150000000 40.25 42.50\n",
            2, 50, 100,
        )
        self.assertEqual(window["guest_outer_window_ns"], [38_100_000_000, 40_360_000_000])
        self.assertEqual(window["guest_inner_window_ns"], [38_360_000_001, 40_099_999_999])
        self.assertEqual(window["host_exec_window_ns"], [50, 100])
        with self.assertRaisesRegex(ValueError, "does not fit"):
            foreground_window(f"micropod-dense-clock {BOOT_ID} 0 0 38.10 40.35\n", 9, 50, 100)
        with self.assertRaisesRegex(ValueError, "expected one"):
            foreground_window("missing bracket", 1, 50, 100)
        short = foreground_window(f"micropod-dense-clock {BOOT_ID} 0 0 40.00 40.10\n", 0.035, 50, 100)
        self.assertIsNone(short["guest_inner_window_ns"])

    def test_unreported_work_is_explicit_for_no_completion_interval(self):
        clock = GuestClock.parse(BOOT_ID, "0", "0")
        samples = [Sample.parse(row, clock, 1) for row in (
            "0 - 1.00 1.00 0 0 0 0",
            "1 1.10 2.00 2.00 1000 1 1 100",
            "2 2.10 9.00 9.00 9000 7 3 800",
            "- - 9.10 9.11 9999 8 3 900",
        )]
        window = foreground_window(f"micropod-dense-clock {BOOT_ID} 0 0 3.00 6.00\n", 2.5, 1, 2)
        alignment = align_worker(samples, window)
        self.assertEqual(alignment["reported_completions_bounds"], [0, 0])
        self.assertEqual(alignment["completed_compiles_bounds"], [0, 1])
        self.assertEqual(alignment["cpu_sample_indices_before_after"], [1, 2])
        self.assertEqual(alignment["cpu_usage_ns_bounds"], [0, 8000])
        self.assertEqual(alignment["throttled_ns_bounds"], [0, 700])
        missing_post = align_worker(samples[:2] + samples[3:], window)
        self.assertEqual(missing_post["reported_completions_bounds"], [0, 1])
        self.assertEqual(missing_post["cpu_sample_indices_before_after"], [1, 2])


if __name__ == "__main__":
    unittest.main()
