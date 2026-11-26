"""Local controls for historical replay, admission, path selection and the bounded client. No sockets."""

import copy
import io
import json
import os
import plistlib
import sys
import tempfile
import unittest
from argparse import Namespace
from contextlib import ExitStack, nullcontext, redirect_stderr
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch
from zipfile import ZipFile

import gamma_path_pilot as pilot
import gamma_path_study as study
from kernel_path.verify_quota import SOURCE as POLICY_SOURCE
from kernel_path.verify_quota import verify as verify_quota

DATA = study.DATA
RELAY = Path(os.environ["MICROPOD_RELAY_SOURCE"])


def utc(at):
    return datetime.fromtimestamp(at, timezone.utc).isoformat()


def clearance(start, end):
    return dict(passed=True, source="synthetic owner disk observation", checked_at=utc(start), expires_at=utc(end))


def guest_inventory(boot):
    return "\n".join(
        (
            f"boot={boot}",
            "release=7.3.5-micropod",
            "machine=aarch64",
            "config_sha256=" + pilot.CONFIG,
            "# CONFIG_SCHED_CLASS_EXT is not set",
            "virtio_nic=eth1",
            "/sys/class/net/eth1/queues/rx-0",
            "/sys/class/net/eth1/queues/tx-0",
            "tcp-segmentation-offload: on",
            "generic-receive-offload: on",
            "",
        )
    )


def stock_counter_fixture(root):
    """Build a version 3 control with one cumulative synthetic service-interface counter."""
    def read(name):
        return json.loads((root / name).read_bytes())

    def save(name, obj):
        (root / name).write_text(json.dumps(obj))

    plan, fixtures = read("plan.json"), read("fixtures.json")
    warm, scored = read("warmup-1-A.json"), read("scored-1-A.json")
    plan["stock_window_version"] = 3
    fixtures["A"]["scope"] = str(root)
    start = warm["before"]["epoch_ns"] / 1e9 - 1
    end = scored["after"]["epoch_ns"] / 1e9 + 1
    handoff = dict(owner="fixture", reservation="test", mode="baseline", scopes=[str(root)],
                   observed_at_epoch=start, starts_at=utc(start), expires_at=utc(end),
                   effective_disk_gate=clearance(start, end))
    save("admission.json", handoff)
    save("plan.json", plan)
    save("fixtures.json", fixtures)
    tx = warm["link_before"]["mppub0"]["tx_bytes"]
    for row, name in ((warm, "warmup"), (scored, "scored")):
        row["admission"] = dict(handoff, observed_at_epoch=row["before"]["epoch_ns"] / 1e9)
        row["admission_after"] = dict(handoff, observed_at_epoch=row["after"]["epoch_ns"] / 1e9)
        row["link_before"]["mppub0"]["tx_bytes"] = tx
        tx += row["client"]["bytes"]
        row["link_after"]["mppub0"]["tx_bytes"] = tx
        row["link_delta"]["mppub0"]["tx_bytes"] = row["client"]["bytes"]
        save(f"{name}-1-A.json", row)
    return plan, fixtures["A"], warm, scored, handoff


class GammaPathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.recorded = study.replay(DATA)
        cls.rows = [json.loads(s) for s in (DATA / "rounds.jsonl").read_text().splitlines()]

    def test_replay_all_six_series_preserves_pair_direction_and_peer_eof(self):
        self.assertEqual(self.recorded, json.loads((DATA / "summary.json").read_text()))
        result = self.recorded["path-confirmation"]
        self.assertEqual(len(result["paired_blocks"]), 12)
        self.assertAlmostEqual(result["paired_change_pct"], 25.16794537)
        self.assertAlmostEqual(result["arms"]["full-reno"]["vmm"]["cpu_ns_per_byte"], 0.4428613)
        self.assertIsNone(result["arms"]["full-bridge"]["link_drops"])
        old = self.recorded["older-relay-vm-holdout"]
        self.assertEqual(old["arms"]["confirm-orb"]["dirty_blocks"], [12])
        self.assertEqual(old["arms"]["confirm-orb"]["fresh_failed"], 1)
        self.assertAlmostEqual(old["paired_change_pct"], -14.6, places=1)
        self.assertIsNone(self.recorded["rps-rfs"]["arms"]["rfs"]["fresh_failed"])

    def test_mismatched_counters_and_bytes_cannot_score(self):
        row = copy.deepcopy(self.rows[0])
        row["cpu"]["after"]["vmm"]["birth_ticks"] += 1
        with self.assertRaisesRegex(ValueError, "identity"):
            study.measure(row)
        row = copy.deepcopy(self.rows[0])
        row["client"]["per_stream_bytes"][0] -= 1
        with self.assertRaisesRegex(ValueError, "assertions"):
            study.measure(row)

    def test_paired_host_cpu_cost_and_occupancy_from_saved_ticks(self):
        full = study.archived_cpu(DATA, "path-confirmation")
        self.assertEqual(full, json.loads((DATA / "cpu-attribution.json").read_text()))
        costs = full["summary"]["cpu_ns_per_payload_byte"]
        cores = full["summary"]["mean_host_cores"]
        self.assertEqual(full["operation"], "direct minus bridge")
        self.assertEqual(len(full["blocks"]), 12)
        self.assertAlmostEqual(costs["vmm_plus_relay"]["median"], -0.08618242927)
        self.assertEqual(costs["vmm_plus_relay"]["direct_lower_blocks"], 11)
        self.assertAlmostEqual(cores["vmm_plus_relay"]["median"], 0.27644278084)
        self.assertEqual(cores["vmm_plus_relay"]["direct_lower_blocks"], 3)
        self.assertNotAlmostEqual(
            costs["vmm_plus_relay"]["median"], costs["vmm"]["median"] + costs["relay"]["median"]
        )
        self.assertIsNone(full["blocks"][0]["arms"]["full-bridge"]["link_drops"])

    def test_held_out_cpu_and_unavailable_counters(self):
        holdout = study.archived_cpu(DATA, "path-holdout-lazy")["summary"]
        self.assertAlmostEqual(holdout["mean_host_cores"]["vmm_plus_relay"]["median"], -0.01889, places=5)
        self.assertEqual(holdout["cpu_ns_per_payload_byte"]["vmm_plus_relay"]["direct_lower_blocks"], 11)
        first = study.archived_cpu(DATA, "path-first")
        missing = first["summary"]["cpu_ns_per_payload_byte"]["vmm_plus_relay"]
        self.assertEqual(missing["observed_blocks"], 0)
        self.assertIsNone(missing["direct_lower_blocks"])
        self.assertIsNone(missing["median"])
        self.assertIsNone(first["blocks"][0]["mean_host_cores"]["vmm"])

    def test_separate_plans_carry_no_measured_cost(self):
        for directory, label, total in (
            ("dry-stock-relay", "absolute stock baseline", 2),
            ("dry-bridge-direct", "direct minus bridge", 10),
        ):
            with self.subTest(directory=directory):
                report = study.pilot_cpu(DATA / directory)
                self.assertEqual((report["status"], report["operation"]), ("plan only", label))
                self.assertEqual(report["attempts"], {"planned": total, "recorded": 0, "failed_or_stopped": {}})
                self.assertIsNone(report["summary"])

    def test_fleet_and_owner_are_independent(self):
        fleet = json.loads((DATA / "admission.json").read_text())
        now = pilot.stamp(fleet["generatedAt"])
        leaf = Path("/tmp/dedicated")
        release = dict(
            owner="test-owner",
            reservation="synthetic",
            host=pilot.HOST,
            exclusive=True,
            starts_at="2026-11-22T07:00:00Z",
            expires_at="2026-11-22T07:30:00Z",
            scopes=[str(leaf.resolve())],
            modes=["baseline"],
            effective_disk_gate=clearance(now-1, now+30),
        )
        with self.assertRaisesRegex(ValueError, "1/1"):
            pilot.admit(fleet, release, [leaf], now, "baseline")
        fleet["runners"][1]["runner"]["activeLeases"] = 0
        self.assertEqual(pilot.admit(fleet, release, [leaf], now, "baseline")["reservation"], "synthetic")
        for metadata, scope, at, mode in [
            (dict(release, exclusive=False), leaf, now, "baseline"),
            (release, Path("/tmp/elsewhere"), now, "baseline"),
            (release, leaf, now + 91, "baseline"),
            (release, leaf, now, "path"),
            (dict(release, expires_at=fleet["generatedAt"]), leaf, now, "baseline"),
        ]:
            with self.assertRaises(ValueError):
                pilot.admit(fleet, metadata, [scope], at, mode)

    def test_occupied_lane_never_opens_an_endpoint(self):
        fleet = json.loads((DATA / "admission.json").read_text())
        with tempfile.TemporaryDirectory() as td, pilot.helpers(RELAY) as p:
            directory = Path(td)
            a = directory / "absent"
            release = directory / "owner.json"
            release.write_text("{}")
            args = Namespace(
                out=directory / "receipts", a=a, mode="baseline", fleet=DATA / "admission.json", release=release
            )
            with (
                patch.object(p, "command", side_effect=AssertionError("endpoint contacted")),
                patch.object(pilot.time, "time", return_value=pilot.stamp(fleet["generatedAt"])),
            ):
                with self.assertRaisesRegex(ValueError, "1/1"):
                    pilot.run(args, p, pilot.schedule(p, "baseline", "macvlan", 34199))
            self.assertEqual([x.name for x in args.out.iterdir()], ["plan.json"])

    def test_stock_clearance_is_required_before_any_endpoint(self):
        fleet = json.loads((DATA / "admission.json").read_text())
        now = pilot.stamp(fleet["generatedAt"])
        fleet["runners"][1]["runner"]["activeLeases"] = 0
        with tempfile.TemporaryDirectory() as td, pilot.helpers(RELAY) as p:
            root = Path(td)
            a = root / "scope"
            release = dict(owner="owner", reservation="r", host=pilot.HOST, exclusive=True, modes=["baseline"],
                           scopes=[str(a.resolve())], starts_at=utc(now-10), expires_at=utc(now+100))
            (root/"fleet").write_text(json.dumps(fleet))
            with patch.object(p, "command", side_effect=AssertionError("endpoint contacted")), \
                 patch.object(pilot.time, "time", return_value=now):
                for i, gate in enumerate((None, clearance(now-20, now), clearance(now+1, now+10),
                                          dict(clearance(now-1, now+10), source=" "), dict(clearance(now-1, now+10), passed=False))):
                    rec = dict(release)
                    if gate is not None:
                        rec["effective_disk_gate"] = gate
                    (root/"owner").write_text(json.dumps(rec))
                    args = Namespace(out=root/f"out{i}", a=a, mode="baseline", fleet=root/"fleet", release=root/"owner")
                    with self.subTest(gate=gate), self.assertRaisesRegex(ValueError, "disk clearance"):
                        pilot.run(args, p, pilot.schedule(p, "baseline", "macvlan", 34199))
                    self.assertEqual([x.name for x in args.out.iterdir()], ["plan.json"])

    def test_dry_plans_and_interface_counters(self):
        with pilot.helpers(RELAY) as p:
            baseline = pilot.schedule(p, "baseline", "macvlan", 34199)
            paths = pilot.schedule(p, "path", "macvlan", 34199)
            self.assertEqual((baseline["offered_seconds"], paths["offered_seconds"]), (12, 60))
            self.assertEqual(paths["order"]["scored"], ["BA", "AB"])
        before = {nic: dict(rx_bytes=0, tx_bytes=0, rx_dropped=0, tx_dropped=0) for nic in ["eth0", "mppub0"]}
        after = copy.deepcopy(before)
        after["mppub0"]["tx_bytes"] = 100
        self.assertEqual(pilot.change(before, after, "macvlan")["mppub0"]["tx_bytes"], 100)
        with self.assertRaisesRegex(ValueError, "egress"):
            pilot.change(before, after, "bridge")

    def test_readback_on_archived_bridge_and_direct(self):
        raw = study.archived(RELAY, "gamma-direct-macvlan")["records"]["workers"]
        with tempfile.TemporaryDirectory() as td, pilot.helpers(RELAY) as p:
            root = Path(td)
            (root / "data").mkdir()
            for arm, path in (("full-bridge", "bridge"), ("full-reno", "macvlan")):
                old = raw[arm]
                home = root / arm
                home.mkdir()
                scope = root / "data" / arm
                scope.mkdir()
                for k, v in dict(
                    base=arm, id="abc", name="mark", addr="127.0.0.1:14003", vmm="100", relay="101"
                ).items():
                    (scope / k).write_text(v)
                exe = scope / "worker"
                exe.write_bytes(b"fixture")
                cfg = {"worker": arm, "memoryMiB": 4096, "kernel": "/test/Image"}
                if path == "macvlan":
                    cfg["publishedPath"] = path
                (home / "worker.json").write_text(json.dumps(cfg))
                (home / "oci.sock").touch()
                st = (home / "oci.sock").stat()
                (home / "session.json").write_text(
                    json.dumps(
                        dict(
                            nativeOCI=True,
                            instance="boot",
                            started=True,
                            owner={"pid": 101},
                            publishedRelayWorkers=2,
                            readySocket=dict(worker=arm, inode=st.st_ino, device=st.st_dev),
                        )
                    )
                )
                (scope / "job.plist").write_bytes(
                    plistlib.dumps(
                        {
                            "EnvironmentVariables": {"MICROPOD_CI_PORT_RELAY": "kqueue-interactive"},
                            "ProgramArguments": [str(exe)],
                            "Label": "test",
                        }
                    )
                )

                def query(*s):
                    if s[0] == "launchctl":
                        return "pid = 101\nspawn type = interactive"
                    if s[0] == "lsof":
                        return "100"
                    if s[0] == "curl":
                        return "mark"
                    if "info" in s:
                        return json.dumps(
                            dict(
                                ID=arm,
                                NCPU=4,
                                MemTotal=4 * 2**30,
                                ServerVersion="test",
                                Labels=["io.micropod.instance=boot"],
                            )
                        )
                    if "inspect" in s:
                        return json.dumps(
                            dict(
                                Id="abc",
                                Name="/mark",
                                State={"Running": True},
                                Image=study.IMAGE,
                                Config={"Cmd": ["-listen", ":8080", "-marker", "mark"]},
                                NetworkSettings={"Ports": {"8080/tcp": [{}]}},
                            )
                        )
                    if "port" in s:
                        return "127.0.0.1:14003"
                    if "state" in s:
                        return json.dumps(old["state"])
                    if "routes" in s:
                        return json.dumps(old["routes.json"])
                    self.fail(s)

                with patch.object(p, "command", side_effect=query):
                    self.assertEqual(p.inspect(scope, 4, False, path)["route"], pilot.POLICY)
                    with self.assertRaises(ValueError):
                        p.inspect(scope, 4, False, "bridge" if path == "macvlan" else "macvlan")

    def test_accepted_socket_proof_rejects_a_second_connection_or_wrong_controller(self):
        fixture = dict(address="127.0.0.1:14003", name="job", id="abc")
        with patch.object(pilot.http.client, "HTTPConnection") as ctor, tempfile.TemporaryDirectory() as tmp:
            response = ctor.return_value.getresponse.return_value
            response.status = 200
            response.read.return_value = b"job"
            readback = "0 0 10.0.0.2:8080 10.0.0.1:50000\n\treno wscale:7,7"
            for value, error in (
                (readback, None),
                (readback.replace("reno", "ts usec_ts sack ecn ecnseen fastopen reno"), None),
                (readback.replace("reno", "ts sack cubic").replace("7,7", "7,7 reno"), "uses cubic"),
                (readback + "\n" + readback, "one socket row"),
                (readback.splitlines()[0], "one socket row"),
                (readback.replace("reno ", "ts sack "), "no congestion-controller"),
                (readback.replace(":8080", ":8081"), "service port"),
            ):
                with self.subTest(value=value):
                    p = SimpleNamespace(command=Mock(return_value=value))
                    path = Path(tmp) / "accepted.ss.txt"
                    if error:
                        with self.assertRaisesRegex(ValueError, error):
                            pilot.socket_proof(p, [], fixture, "ss", evidence_path=path)
                    else:
                        self.assertEqual(pilot.socket_proof(p, [], fixture, "ss", evidence_path=path), value)
                    self.assertEqual(path.read_text(), value)

    def test_accepted_socket_endpoints_and_flags(self):
        result = pilot.parse_service_ss(
            "tcp ESTAB 0 0 [::ffff:172.18.0.2]:8080 [::ffff:192.168.128.1]:52001\n"
            "\tts sack reno wscale:7,7 cwnd:10"
        )
        self.assertEqual(result, {"local": ("172.18.0.2", 8080), "peer": ("192.168.128.1", 52001),
                                  "controller": "reno"})

    def test_quota_gate_recomputes_throttling_and_checks_fallback_on_the_same_boot(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)

            def put(path, value):
                (root / path).write_text(json.dumps(value))

            h = "1" * 64
            put(
                "policy-build.json",
                dict(program="scx_bpfland", source_revision=POLICY_SOURCE, ops="bpfland", executable_sha256=h),
            )
            for phase, state, seq in (
                ("before", "disabled", 0),
                ("active", "enabled", 1),
                ("fallback", "disabled", 1),
                ("current-a", "disabled", 0),
                ("current-b", "enabled", 2),
            ):
                (root / phase).mkdir()
                ops = "bpfland" if state == "enabled" else "-"
                kernel = {
                    "boot": "control" if phase == "current-a" else "synthetic",
                    "sched_ext": {"state": state, "ops": ops, "enable_seq": seq},
                }
                put(phase + "/kernel-before.json", kernel)
                put(phase + "/kernel-after.json", kernel)
                rows = []
                for cap, usage in ((200000, 9500000), (50000, 2500000), (200000, 9500000)):
                    rows.append(
                        dict(
                            start_s="0",
                            end_s="5",
                            start_usec="0",
                            end_usec=str(usage),
                            state=state,
                            sequence=str(seq),
                            ops=ops,
                            task_sched_ext=["1", "1"] if state == "enabled" else ["0", "0"],
                            cpu_max=f"{cap} 100000",
                            memory_max=str(1 << 30),
                            pids_max="512",
                            **{"pass": True},
                        )
                    )
                put(
                    phase + "/quota.json",
                    {
                        "scheduler": ops if state == "enabled" else "fair",
                        "pass": True,
                        "rounds": rows,
                        "cgroup_layout": {
                            "paths": ["/bench/a", "/bench/b"],
                            "common_parent": "/bench",
                            "pass": True,
                        },
                    },
                )
            (root / "active/executable.sha256").write_text(h)
            self.assertTrue(verify_quota(root)["eligible_for_separate_timing"])
            (root / "current-b/executable.sha256").write_text(h)
            self.assertEqual(verify_quota(root, current=True)["states"]["current-b"]["enable_seq"], 2)
            (root / "current-b/executable.sha256").write_text("0" * 64)
            with self.assertRaisesRegex(ValueError, "executable"):
                verify_quota(root, current=True)
            dirty = json.loads((root / "active/quota.json").read_text())
            dirty["rounds"][1]["end_usec"] = "9000000"
            put("active/quota.json", dirty)
            with self.assertRaisesRegex(ValueError, "measured CPU"):
                verify_quota(root)

    def test_guest_inventory_requires_booted_config_and_effective_offloads(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            text = guest_inventory("test")
            p = SimpleNamespace(command=Mock(return_value='{"boot":"test","sched_ext":null}'))
            self.assertEqual(pilot.kernel_facts(p, root, text)["boot"], "test")
            p.command.return_value = '{"boot":"test"}'
            self.assertEqual(pilot.kernel_facts(p, root, text), {"boot": "test"})
            for old, new in (
                ("boot=test", "boot=retired"),
                (pilot.CONFIG, "0" * 64),
                ("tcp-segmentation-offload: on", "unavailable"),
                ("# CONFIG_SCHED_CLASS_EXT is not set", "CONFIG_SCHED_CLASS_EXT=y"),
            ):
                with self.assertRaises(ValueError):
                    pilot.kernel_facts(p, root, text.replace(old, new))

    def test_full_dry_crossover_writes_each_attempt_and_stops_on_first_dirty_arm(self):
        saved = {
            (r["block"], "A" if r["arm"] == "full-bridge" else "B"): r
            for r in self.rows
            if r["series"] == "path-confirmation"
        }
        with tempfile.TemporaryDirectory() as td, pilot.helpers(RELAY) as p, ExitStack() as ctx:
            root = Path(td)
            a = root / "data" / "A"
            b = root / "data" / "B"
            raw = root / "raw.json"
            for scope in (a, b):
                scope.mkdir(parents=True)
                for name in ("base", "id"):
                    (scope / name).write_text(scope.name)
                home = root / scope.name
                home.mkdir()
                (root / f"facts-{scope.name}").write_text(guest_inventory(scope.name))
                (home / "session.json").write_text(
                    json.dumps(
                        {
                            "started": True,
                            "nativeOCI": True,
                            "instance": scope.name,
                            "publishedRelayWorkers": 2,
                            "readySocket": {"worker": scope.name},
                            "owner": {"pid": saved[1, scope.name]["cpu"]["before"]["relay"]["pid"]},
                        }
                    )
                )
            raw.write_text("{}")
            args = Namespace(
                a=a,
                b=b,
                out=root / "success",
                mode="path",
                release=raw,
                fleet=raw,
                tools=root,
                build=raw,
                facts_a=root / "facts-A",
                facts_b=root / "facts-B",
                ss="ss",
            )

            def inspected(scope, cpus, orb, path, release):
                n = scope.name
                processes = saved[1, n]["cpu"]["before"]
                return dict(
                    engine=n,
                    id=n,
                    name=n,
                    address=n,
                    instance=n,
                    worker=n,
                    pids={role: processes[role]["pid"] for role in ("relay", "vmm")},
                    cpus=cpus,
                    relay_workers=2,
                    release=release,
                    kernel="/Image",
                    route=pilot.POLICY,
                    cpuset="0-3",
                    cli_sha256=study.sha(b"offline fixture executable"),
                    engine_version="v",
                    service_env_sha256="environment",
                    image_config=study.IMAGE,
                )

            def command(*argv):
                if argv[0] == "curl":
                    socket = Path(argv[argv.index("--unix-socket") + 1])
                    return json.dumps({"boot": socket.parent.name, "sched_ext": None})
                return "docker"

            def fake_build(p, fixture, build, kernel):
                return {
                    "source_revision": study.RELAY_REV,
                    "worker_executable_sha256": fixture["cli_sha256"],
                    "kernel_image_sha256": kernel["image_sha256"],
                    "mapped_device": 1,
                    "mapped_inode": 11,
                }

            def snapshot(tools, f):
                raw = saved[1, f["id"]]["cpu"]["before"]
                return {"tasks": [raw["relay"], raw["vmm"]]}

            clock = {}
            early = saved[1, "B"]["cpu"]["before"]["epoch_ns"]/1e9 - 5
            late = saved[2, "B"]["cpu"]["after"]["epoch_ns"]/1e9 + 5
            def fake_admit(fleet, release, scopes, now, mode):
                if mode != "baseline":
                    return {}
                return dict(owner="owner", reservation="stock", scope_note="simulated", mode=mode,
                            scopes=[str(p.resolve()) for p in scopes], starts_at=utc(early), expires_at=utc(late),
                            effective_disk_gate=clearance(early, late), observed_at_epoch=clock.get(args.out, early))

            for owner, name, call in [
                (pilot, "admit", fake_admit),
                (pilot.platform, "system", lambda: "Darwin"),
                (pilot.platform, "node", lambda: "Gamma-128GB.local"),
                (pilot, "cpu_idle", lambda: 98.0),
                (pilot, "single_service", lambda p, docker, cid: cid),
                (pilot, "socket_proof", lambda *x, **kw: "reno"),
                (pilot, "live_attestation", fake_build),
                (p, "inspect", inspected),
                (p, "command", command),
                (p, "digest", lambda v: p.HASHES[v.name]),
                (p, "snapshot", snapshot),
            ]:
                ctx.enter_context(patch.object(owner, name, side_effect=call))
            sent = {"A": 0, "B": 0}

            def netstate(p, d, cid):
                return {
                    ("eth0" if cid == "A" else "mppub0"): dict(
                        tx_bytes=sent[cid], rx_bytes=0, rx_dropped=0, tx_dropped=0
                    ),
                    **(
                        {} if cid == "A" else {"eth0": dict(tx_bytes=0, rx_bytes=0, rx_dropped=0, tx_dropped=0)}
                    ),
                }

            ctx.enter_context(patch.object(pilot, "state", side_effect=netstate))

            def sample(p, tools, f, birth, guard, row, *, stock=False):
                block = row["block"]
                # The copied-warmup fixture intentionally reuses BOTH raw host samples and stdout.
                if stock and row["phase"] == "scored" and args.out.name != "reused-warmup":
                    block = 2
                archive = saved[block, f["id"]]
                if stock:
                    clock[args.out] = archive["cpu"]["after"]["epoch_ns"]/1e9
                client = archive["client"]
                transmitted = client["bytes"]
                if args.out.name == "one-byte-egress" and row["phase"] == "scored":
                    transmitted = 1
                sent[f["id"]] += transmitted
                row.update(
                    client=client,
                    stdout=json.dumps(client),
                    exit_code=0,
                    host={"vmm": {"cpu_ns_per_byte": -999}},
                )
                for bound, raw in archive["cpu"].items():
                    row[bound] = {**raw, "tasks": [raw["vmm"], raw["relay"]]}
                if stock:
                    start = row["before"]["epoch_ns"] + 1_000_000
                    end = row["after"]["epoch_ns"] - 1_000_000
                    row.update(client_epoch_ns=[start, end], client_wall_s=(end - start) / 1e9, fresh_failed=0)
                if args.out.name == "dirty" and row["phase"] == "scored" and row["arm"] == "B":
                    row["fresh_failed"] = 1
                    raise ValueError("first attempted request failed")

            client = ctx.enter_context(patch.object(pilot, "checked_client", side_effect=sample))
            plan = pilot.schedule(p, "path", "macvlan", 34199)
            pilot.run(args, p, plan)
            ratios = [saved[n, "B"]["client"]["mib_s"] / saved[n, "A"]["client"]["mib_s"] for n in (1, 2)]
            self.assertEqual(json.loads((args.out / "complete.json").read_text())["paired_ratios"], ratios)
            self.assertEqual(len(list(args.out.glob("scored-*.json"))), 4)
            report = study.pilot_cpu(args.out)
            self.assertEqual(report["attempts"], {"planned": 10, "recorded": 10, "failed_or_stopped": {}})
            reference = study.archived_cpu(DATA, "path-confirmation")["blocks"]
            for block in report["blocks"]:
                for metric in ("mean_host_cores", "cpu_ns_per_payload_byte"):
                    self.assertEqual(block[metric], reference[block["block"] - 1][metric])
                self.assertEqual(block["arms"]["A"]["link_drops"], 0)
            # A failed final identity check also withholds the summary, even with all samples present.
            (args.out / "complete.json").unlink()
            self.assertIsNone(study.pilot_cpu(args.out)["summary"])
            fixtures = json.loads((args.out / "fixtures.json").read_text())
            fixtures["B"]["kernel_sha256"] = "another-kernel"
            p.save(args.out / "fixtures.json", fixtures)
            with self.assertRaisesRegex(ValueError, "wrong stock fixture"):
                study.pilot_cpu(args.out)
            args.out = root / "dirty"
            with self.assertRaisesRegex(ValueError, "first attempted"):
                pilot.run(args, p, plan)
            self.assertEqual(len(list(args.out.glob("scored-*.json"))), 1)
            self.assertTrue(json.loads((args.out / "scored-1-B.json").read_text())["started"])
            self.assertFalse((args.out / "complete.json").exists())
            p.save(args.out / "stop.json", {"error": "first attempted request failed", "complete": False})
            stopped = study.pilot_cpu(args.out)
            self.assertIsNone(stopped["summary"])
            self.assertEqual(stopped["status"], "stopped")
            self.assertEqual(stopped["attempts"]["recorded"], 7)
            self.assertEqual(stopped["blocks"][0]["arms"]["B"]["fresh_failed"], 1)
            self.assertEqual(stopped["blocks"][0]["arms"]["A"], {"state": "no receipt"})

            args.mode, args.out, args.a, args.facts_a = "baseline", root / "baseline", b, args.facts_b
            baseline_plan = {
                **pilot.schedule(p, "baseline", "macvlan", 34199),
                "fixture_origin": "offline regression only",
            }
            original = guest_inventory("B").replace("\n", "\r\n").encode()
            args.facts_a.write_bytes(original)

            def rotate_owner_export(*argv):
                if argv[0] == "curl":
                    args.facts_a.unlink(missing_ok=True)
                return command(*argv)

            with patch.object(p, "command", side_effect=rotate_owner_export):
                pilot.run(args, p, baseline_plan)
            self.assertFalse(args.facts_a.exists())
            self.assertEqual((args.out / "guest-A.txt").read_bytes(), original)
            args.facts_a.write_bytes(original)
            baseline = study.pilot_cpu(args.out)
            self.assertEqual(baseline["status"], "complete")
            self.assertEqual(baseline["stock_window"]["guest_inventory_sha256"], study.sha(original))
            self.assertEqual(baseline["input_sha256"]["guest-A.txt"], study.sha(original))
            gate = baseline["stock_window"]["admission"]["opening"]["effective_disk_gate"]
            self.assertTrue(gate["passed"])
            self.assertIn("admission.json", baseline["input_sha256"])
            scored_path = args.out / "scored-1-A.json"
            recorded = scored_path.read_bytes()
            # A producer can seal an internally consistent receipt even if the bytes
            # did not traverse the selected interface. Recompute from its raw counters.
            completion_path = args.out / "complete.json"
            completion = completion_path.read_bytes()
            row = json.loads(recorded)
            dev = "mppub0"
            short = row["client"]["bytes"] - 1
            row["link_after"][dev]["tx_bytes"] = row["link_before"][dev]["tx_bytes"] + short
            row["link_after"]["eth0"]["tx_bytes"] += 1
            final = json.loads(completion)
            final["stock_window"]["attempt_sha256"] = study.sha(study.encoded(row).encode())
            p.save(scored_path, row)
            p.save(completion_path, final)
            try:
                with self.assertRaisesRegex(ValueError, "mppub0 TX does not cover"):
                    study.pilot_cpu(args.out)
            finally:
                scored_path.write_bytes(recorded)
                completion_path.write_bytes(completion)
            for fault, message in (("missing", "disk clearance"), ("renewed", "cover the stock client window"),
                                   ("owner", "handoff changed")):
                row = json.loads(recorded)
                if fault == "missing":
                    del row["admission"]["effective_disk_gate"]
                elif fault == "renewed":
                    row["admission"]["effective_disk_gate"]["expires_at"] = utc(row["client_epoch_ns"][0]/1e9 + 1)
                else:
                    row["admission_after"]["owner"] = "different owner"
                scored_path.write_text(json.dumps(row))
                try:
                    with self.subTest(fault=fault), self.assertRaisesRegex(ValueError, message):
                        study.pilot_cpu(args.out)
                finally:
                    scored_path.write_bytes(recorded)
            self.assertEqual(baseline["operation"], "absolute stock baseline")
            observed = baseline["summary"]["cpu_ns_per_payload_byte"]["vmm"]
            self.assertNotIn("direct_lower_blocks", observed)
            self.assertGreater(observed["median"], 0)
            self.assertEqual(observed["median"], study.measure(saved[2, "B"])["vmm"]["cpu_ns_per_byte"])
            self.assertEqual(
                baseline["stock_window"]["fresh"]["p99_us"], saved[2, "B"]["client"]["fresh_p99_us"]
            )
            argv = [
                "gamma_path_pilot.py",
                "baseline",
                "--run",
                "--relay-checkout",
                str(RELAY),
                "--a",
                str(b),
                "--release",
                str(raw),
                "--fleet",
                str(raw),
                "--build",
                str(raw),
                "--tools",
                str(root),
            ]
            for case, inventory, message, attempts in (
                ("mixed-guest", DATA / "stock-guest-mixed.txt", "exactly one matching boot", 0),
                ("one-byte-egress", args.facts_a, "mppub0 TX does not cover", 2),
                ("reused-warmup", args.facts_a, "overlaps or precedes warmup", 2),
            ):
                args.out = root / case
                error = io.StringIO()
                calls_before = client.call_count
                with (
                    self.subTest(case=case),
                    patch.object(sys, "argv", argv + ["--facts-a", str(inventory), "--out", str(args.out)]),
                    patch.object(pilot, "helpers", return_value=nullcontext(p)),
                    redirect_stderr(error),
                    self.assertRaises(SystemExit) as stopped_cli,
                ):
                    pilot.main()
                self.assertEqual(stopped_cli.exception.code, 1)
                self.assertIn(message, error.getvalue())
                self.assertEqual(client.call_count - calls_before, attempts)
                self.assertEqual((args.out / "guest-A.txt").read_bytes(), inventory.read_bytes())
                self.assertFalse((args.out / "complete.json").exists())
                stopped = study.pilot_cpu(args.out)
                self.assertEqual(stopped["status"], "stopped")
                self.assertEqual(stopped["attempts"]["recorded"], attempts)
                self.assertEqual(stopped["input_sha256"]["guest-A.txt"], study.sha(inventory.read_bytes()))
                self.assertIsNone(stopped["summary"])
            rejected = json.loads((args.out / "scored-1-A.json").read_text())
            self.assertTrue(rejected["started"])
            self.assertFalse(rejected["clean"])

    def test_stock_client_stops_at_the_opening_disk_deadline(self):
        from subprocess import TimeoutExpired

        now = [1_795_385_000.]
        expiry = now[0] + .25
        row = {"admission": {"effective_disk_gate": clearance(now[0]-1, expiry),
                             "expires_at": utc(expiry+100)}}
        child = Mock()
        child.poll.side_effect = lambda: child.returncode
        child.returncode = None
        child.kill.side_effect = lambda: setattr(child, "returncode", -9)
        def communicate(timeout=None):
            if timeout is None:
                return "saved partial client output", ""
            self.assertAlmostEqual(timeout, .25)
            now[0] += timeout
            raise TimeoutExpired("fixed", timeout)
        child.communicate.side_effect = communicate
        p = SimpleNamespace(snapshot=lambda *args: {}, identities=lambda snap: {})
        with patch.object(pilot.time, "time", side_effect=lambda: now[0]), \
             patch.object(pilot.subprocess, "Popen", return_value=nullcontext(child)), \
             self.assertRaisesRegex(ValueError, "disk clearance expired during client"):
            pilot.checked_client(p, Path("/unused"), dict(address="unused", name="unused"), {},
                                 lambda: row["admission"], row, stock=True)
        child.kill.assert_called_once()
        self.assertEqual(row["stdout"], "saved partial client output")
        self.assertEqual(row["exit_code"], -9)

    def test_client_boundaries_capture_real_subprocess_output_without_network(self):
        good = self.rows[0]
        with tempfile.TemporaryDirectory() as td, pilot.helpers(RELAY) as p:
            tools = Path(td)
            exe = tools / "fixed"
            fixture = {
                "address": "127.0.0.1:1",
                "name": "synthetic",
                "pids": {k: good["cpu"]["before"][k]["pid"] for k in ("vmm", "relay")},
            }

            def snap(key):
                raw = good["cpu"][key]
                return {**raw, "tasks": [raw["vmm"], raw["relay"]]}

            for case, changes, exit_code, fresh_failed in (
                ("clean", {}, 0, 0),
                ("reconnect", {"reopened": 1}, 1, 0),
                ("fresh EOF", {"errors": ['Get "http://127.0.0.1:1/id": EOF']}, 1, 1),
                ("ambiguous error", {"errors": ["wrong service identity"]}, 1, None),
            ):
                client = copy.deepcopy(good["client"])
                client.update(changes)
                payload = tools / "client.json"
                payload.write_text(json.dumps(client))
                exe.write_text('#!/bin/sh\ncat "' + str(payload) + f'"\nexit {exit_code}\n')
                exe.chmod(0o700)
                now = pilot.time.time()
                row = {"fresh_failed": None, "admission": {"effective_disk_gate": clearance(now-1, now+90),
                                                            "expires_at": utc(now+90)}}
                with (
                    self.subTest(case=case),
                    patch.object(p, "snapshot", side_effect=[snap("before"), snap("after")]),
                ):
                    if exit_code:
                        with self.assertRaisesRegex(ValueError, "assertions"):
                            pilot.checked_client(
                                p, tools, fixture, p.identities(snap("before")), lambda: row["admission"], row, stock=True
                            )
                    else:
                        pilot.checked_client(
                            p, tools, fixture, p.identities(snap("before")), lambda: row["admission"], row, stock=True
                        )
                        start, end = row["client_epoch_ns"]
                        self.assertLess(start, end)
                self.assertEqual(row["exit_code"], exit_code)
                self.assertEqual(row["fresh_failed"], fresh_failed)
                self.assertGreater(row["host"]["vmm"]["cpu_ns_per_byte"], 0)

    def test_baseline_replays_the_mapped_build_observation(self):
        with tempfile.TemporaryDirectory() as td:
            exe, kernel = Path(td) / "worker", Path(td) / "Image"
            exe.write_bytes(b"offline test executable")
            kernel.write_bytes(b"offline kernel image")
            st = exe.stat()

            def pidpath(pid, buf, length):
                self.assertEqual(pid, 41)
                buf.value = os.fsencode(exe)
                return len(buf.value)

            def digest(path):
                return study.sha(path.read_bytes())

            p = SimpleNamespace(
                command=Mock(return_value=f"ftxt\nD{st.st_dev:#x}\ni{st.st_ino}"), digest=digest
            )
            f = {"pids": {"relay": 41}, "cli_sha256": digest(exe), "kernel": str(kernel)}
            build = {"source_revision": study.RELAY_REV, "worker_executable_sha256": digest(exe)}
            image = {"image_sha256": digest(kernel)}
            with patch.object(pilot.ctypes, "CDLL", return_value=SimpleNamespace(proc_pidpath=pidpath)):
                result = pilot.live_attestation(p, f, build, image)
                self.assertEqual(
                    result,
                    {
                        **build,
                        "kernel_image_sha256": digest(kernel),
                        "mapped_device": st.st_dev,
                        "mapped_inode": st.st_ino,
                    },
                )
                with self.assertRaisesRegex(ValueError, "unverified revised relay"):
                    pilot.live_attestation(p, f, {**build, "worker_executable_sha256": "f" * 64}, image)
                p.command.return_value = f"ftxt\nD{st.st_dev:#x}\ni{st.st_ino + 1}"
                with self.assertRaisesRegex(ValueError, "vnode differs"):
                    pilot.live_attestation(p, f, build, image)

    def test_baseline_rejects_relabelled_warmup_and_detached_evidence(self):
        with tempfile.TemporaryDirectory() as td, ZipFile(DATA / "stock-baseline-fixtures.zip") as archive:
            archive.extractall(td)
            root = Path(td) / "control"
            with self.assertRaisesRegex(ValueError, "overlaps or precedes warmup"):
                study.pilot_cpu(Path(td) / "reused")
            legacy = study.pilot_cpu(root)
            self.assertEqual(legacy["status"], "unqualified legacy baseline")
            self.assertEqual(legacy["stock_window"]["phase"], "scored")
            self.assertIsNone(legacy["summary"])
            mutations = [
                (
                    "fixtures.json",
                    ("A", "mapped_relay_build", "source_revision"),
                    "0" * 40,
                    "unbound stock relay build",
                ),
                ("fixtures.json", ("A", "cli_sha256"), "0" * 64, "unbound stock relay build"),
                ("fixtures.json", ("A", "image_config"), "another image", "wrong stock fixture"),
                ("fixtures.json", ("A", "kernel_sha256"), "another kernel", "wrong stock fixture"),
                ("fixtures.json", ("A", "birth_ticks", "relay"), 13, "stock process birth changed"),
                ("scored-1-A.json", ("relay_after", "workers"), 4, "worker, boot or service changed"),
                (
                    "scored-1-A.json",
                    ("kernel_after", "boot"),
                    "different boot",
                    "worker, boot or service changed",
                ),
                ("scored-1-A.json", ("service_before",), "another service", "worker, boot or service changed"),
                ("scored-1-A.json", ("fresh_failed",), None, "fresh-request outcome"),
                ("scored-1-A.json", ("client", "fresh_p99_us"), 90_000_000, "timing outside client invocation"),
                ("scored-1-A.json", ("client", "fresh_p99_us"), 500_000, "completion differs"),
            ]
            for name, keys, replacement, error in mutations:
                with self.subTest(file=name, keys=keys, value=replacement):
                    path = root / name
                    original = path.read_bytes()
                    obj = json.loads(original)
                    target = obj
                    for k in keys[:-1]:
                        target = target[k]
                    target[keys[-1]] = replacement
                    if keys[0] == "client":
                        obj["stdout"] = json.dumps(obj["client"])
                    path.write_text(json.dumps(obj))
                    try:
                        with self.assertRaisesRegex(ValueError, error):
                            study.pilot_cpu(root)
                    finally:
                        path.write_bytes(original)

    def test_stock_replay_requires_the_exact_inventory_from_one_boot(self):
        with tempfile.TemporaryDirectory() as td, ZipFile(DATA / "stock-baseline-fixtures.zip") as archive:
            archive.extractall(td)
            root = Path(td) / "control"

            def read(name):
                return json.loads((root / name).read_bytes())

            plan = read("plan.json")
            plan["stock_window_version"] = 2
            (root / "plan.json").write_text(json.dumps(plan))
            fixtures, final = read("fixtures.json"), read("complete.json")
            warm, scored = read("warmup-1-A.json"), read("scored-1-A.json")
            guest = root / "guest-A.txt"

            def seal(data):
                # Simulate a producer that hashes everything it received, even a mixed capture.
                guest.write_bytes(data)
                fixtures["A"]["guest_inventory_sha256"] = study.sha(data)
                (root / "fixtures.json").write_text(json.dumps(fixtures))
                final["stock_window"] = study.stock_window(plan, fixtures["A"], scored, warm)
                (root / "complete.json").write_text(json.dumps(final))

            good = guest_inventory("B").encode()
            seal(good)
            self.assertEqual(study.pilot_cpu(root)["status"], "unqualified legacy baseline")
            self.assertIsNone(study.pilot_cpu(root)["summary"])
            guest.write_bytes(good.replace(b"\n", b"\r\n"))
            with self.assertRaisesRegex(ValueError, "stock guest inventory digest differs"):
                study.pilot_cpu(root)
            guest.unlink()
            with self.assertRaises(FileNotFoundError):
                study.pilot_cpu(root)
            for field, data in (
                ("boot", (DATA / "stock-guest-mixed.txt").read_bytes()),
                ("boot", good.replace(b"boot=B\n", b"boot=retired\n")),
                ("release", good + b"release=7.3.5-micropod\n"),
                ("machine", good.replace(b"machine=aarch64\n", b"")),
                ("config_sha256", good + b"config_sha256=" + b"f" * 64 + b"\n"),
            ):
                with self.subTest(field=field):
                    seal(data)
                    with self.assertRaisesRegex(ValueError, "exactly one matching " + field):
                        study.pilot_cpu(root)

    def test_stock_cumulative_counters_across_distinct_windows(self):
        with tempfile.TemporaryDirectory() as td, ZipFile(DATA / "stock-guest-inventory-fixtures.zip") as archive:
            archive.extractall(td)
            root = Path(td) / "v2-control"
            plan, fixture, warm, scored, handoff = stock_counter_fixture(root)
            final = json.loads((root / "complete.json").read_bytes())
            dev = "mppub0"

            # Exercise equality at the seam, including a different task enumeration order.
            prior = {task["pid"]: task for task in warm["after"]["tasks"]}
            ticks = ("user_ticks", "system_ticks", "runnable_ticks")
            scored["before"]["tasks"].reverse()
            for task in scored["before"]["tasks"]:
                for counter in ticks:
                    task[counter] = prior[task["pid"]][counter]
            final["stock_window"] = study.stock_window(plan, fixture, scored, warm, handoff)

            def seal(row):
                final["stock_window"]["attempt_sha256"] = study.sha(study.encoded(row).encode())
                (root / "scored-1-A.json").write_text(json.dumps(row))
                (root / "complete.json").write_text(json.dumps(final))

            seal(scored)
            self.assertEqual(study.pilot_cpu(root)["status"], "complete")
            for field in ("tx_bytes", *ticks):
                roles = ("service",) if field == "tx_bytes" else ("relay", "vmm")
                for role in roles:
                    with self.subTest(field=field, role=role):
                        row = copy.deepcopy(scored)
                        if field == "tx_bytes":
                            # Restore the warmup opening count and preserve scored egress.
                            for bound in ("before", "after"):
                                row["link_" + bound][dev][field] -= warm["link_delta"][dev][field]
                        else:
                            # Reuse both of this process's warmup readings in the later window.
                            pid = fixture["pids"][role]
                            for bound in ("before", "after"):
                                task = next(t for t in row[bound]["tasks"] if t["pid"] == pid)
                                task[field] = next(t[field] for t in warm[bound]["tasks"] if t["pid"] == pid)
                        seal(row)
                        with self.assertRaisesRegex(ValueError, field):
                            study.pilot_cpu(root)
                        with self.assertRaisesRegex(ValueError, field):
                            study.stock_window(plan, fixture, row, warm, handoff)

    def test_stock_warmup_requires_integer_stream_bytes_and_matching_rate(self):
        with tempfile.TemporaryDirectory() as td, ZipFile(DATA / "stock-guest-inventory-fixtures.zip") as archive:
            archive.extractall(td)
            root = Path(td) / "v2-control"
            plan, fixture, warm, scored, handoff = stock_counter_fixture(root)
            final = json.loads((root / "complete.json").read_bytes())
            final["stock_window"] = study.stock_window(plan, fixture, scored, warm, handoff)
            (root / "complete.json").write_text(json.dumps(final))
            self.assertEqual(study.pilot_cpu(root)["status"], "complete")

            client = warm["client"]
            first, *middle, last = client["per_stream_bytes"]
            # Preserve the sum even for fractional and boolean counts. Seal the
            # edited stdout and warmup so the check must use the raw client data.
            cases = (
                ("idle stream", {"per_stream_bytes": [first + last, *middle, 0]}),
                ("fractional bytes", {"per_stream_bytes": [first + 0.5, *middle, last - 0.5]}),
                ("boolean byte", {"per_stream_bytes": [first + last - 1, *middle, True]}),
                ("fractional type stream count", {"streams": 32.0}),
                ("fractional type byte total", {"bytes": float(client["bytes"])}),
                ("wrong throughput", {"mib_s": client["mib_s"] * 2}),
            )
            for name, changes in cases:
                with self.subTest(name=name):
                    altered = {**client, **changes}
                    row = {**warm, "client": altered, "stdout": json.dumps(altered)}
                    (root / "warmup-1-A.json").write_text(json.dumps(row))
                    final["stock_window"]["warmup_sha256"] = study.sha(study.encoded(row).encode())
                    (root / "complete.json").write_text(json.dumps(final))
                    with self.assertRaisesRegex(ValueError, "bulk (workload|rate)"):
                        study.pilot_cpu(root)
                    with self.assertRaisesRegex(ValueError, "bulk (workload|rate)"):
                        study.stock_window(plan, fixture, row, handoff=handoff)

    def test_stock_percentiles_fit_the_number_of_scheduled_arrivals(self):
        with tempfile.TemporaryDirectory() as td, ZipFile(DATA / "stock-guest-inventory-fixtures.zip") as archive:
            archive.extractall(td)
            root = Path(td) / "v2-control"

            def read(name):
                return json.loads((root / name).read_bytes())

            def save(name, obj):
                (root / name).write_text(json.dumps(obj))

            plan, fixture, warm, scored, handoff = stock_counter_fixture(root)

            # At the pinned client's sorted offsets 227 and 237 of 240, at least
            # 13 and 3 requests respectively must attain the reported latency.
            bound_us = min(round(scored["client_wall_s"] * 1e9),
                           scored["client_epoch_ns"][1] - scored["client_epoch_ns"][0]) // 1000
            p95, p99 = bound_us - 12 * 25_000, bound_us - 2 * 25_000
            self.assertGreater(p99, scored["client"]["window_s"] * 1e6)
            scored["client"].update(fresh_p95_us=p95, fresh_p99_us=p99, dispatch_p95_us=p95, dispatch_max_us=p95)
            scored["stdout"] = json.dumps(scored["client"])
            save("scored-1-A.json", scored)
            final = read("complete.json")
            final["stock_window"] = study.stock_window(plan, fixture, scored, warm, handoff)
            save("complete.json", final)
            self.assertEqual(study.pilot_cpu(root)["status"], "complete")

            for key in ("fresh_p95_us", "fresh_p99_us"):
                with self.subTest(metric=key):
                    invalid = copy.deepcopy(scored)
                    invalid["client"][key] += 1
                    invalid["stdout"] = json.dumps(invalid["client"])
                    save("scored-1-A.json", invalid)
                    # Seal the altered observation as the old producer did. Replay
                    # must reject the timings even when all receipt hashes match.
                    sealed = copy.deepcopy(final)
                    proof = sealed["stock_window"]
                    proof["fresh"][key.removeprefix("fresh_")] = invalid["client"][key]
                    proof["attempt_sha256"] = study.sha(study.encoded(invalid).encode())
                    proof["stdout_sha256"] = study.sha(invalid["stdout"].encode())
                    save("complete.json", sealed)
                    with self.assertRaisesRegex(ValueError, "fixed-arrival percentile"):
                        study.stock_window(plan, fixture, invalid, warm, handoff)
                    with self.assertRaisesRegex(ValueError, "fixed-arrival percentile"):
                        study.pilot_cpu(root)

    def test_stock_tail_can_drain_and_old_completion_stays_diagnostic(self):
        with tempfile.TemporaryDirectory() as td, ZipFile(DATA / "stock-baseline-fixtures.zip") as archive:
            archive.extractall(td)
            control = Path(td) / "control"

            def read(name):
                return json.loads((control / name).read_text())

            plan, fixture = read("plan.json"), read("fixtures.json")["A"]
            warm, scored = read("warmup-1-A.json"), read("scored-1-A.json")
            c = scored["client"]
            c["fresh_p99_us"] = int(1e6 * (c["window_s"] + scored["client_wall_s"]) / 2)
            self.assertGreater(c["fresh_p99_us"], c["window_s"] * 1e6)
            scored["stdout"] = json.dumps(c)
            self.assertEqual(
                study.stock_window(plan, fixture, scored, warm)["fresh"]["p99_us"], c["fresh_p99_us"]
            )
            complete = read("complete.json")
            del complete["stock_window"]
            (control / "complete.json").write_text(json.dumps(complete))
            with self.assertRaisesRegex(ValueError, "missing or unsupported"):
                study.pilot_cpu(control)
            old = study.pilot_cpu(Path(td) / "legacy-ed8bb626")
            self.assertEqual(old["status"], "unqualified legacy baseline")
            self.assertIsNone(old["summary"])


if __name__ == "__main__":
    unittest.main()
