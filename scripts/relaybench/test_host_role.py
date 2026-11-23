"""Offline Phase 0 checks using archived launchd observations and synthetic benchmark windows."""
import gzip
import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from argparse import Namespace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import gamma_contrasts
import gamma_pilot as pilot
import host_role as role


def network_files():
    return {"/proc/sys/kernel/random/boot_id": "148cf479-f9e5-4ac0-b99d-44b3699080f6",
            "/proc/net/dev": "mppub0: 2048 22 0 0 0 0 0 0 4096 24 0 0 0 0 0 0",
            "/proc/net/snmp": "Tcp: ActiveOpens OutRsts EstabResets RetransSegs\nTcp: 13 2 1 3",
            "/proc/interrupts": " CPU0 CPU1\n 31: 3 4 PCI virtio\n 32: 1 2 PCI virtio\n IPI0: 10 100 Reschedule",
            "/proc/stat": "cpu 230 1 3 6 7 1 4 20\nintr 13410 40 13 6 0 0\nctxt 170230",
            "/proc/softirqs": "  NET_RX: 12 20\n  NET_TX: 1 3"}


def measured_row(arm):
    def host(wait):
        return {"wait_s_per_s": wait, "cpu_s_per_gib": 0.5}
    first = role.guest_counters(network_files(), dict.fromkeys(role.LINK_ERRORS, 0))
    last = dict(first, monotonic_ns=first["monotonic_ns"] + 6_000_000_000,
                counters=dict(first["counters"], rx_packets=44, tx_packets=55, tx_bytes=8192))
    return dict(clean=True, fresh_failed=0, reopened=0, fresh_p50_us=11500, fresh_p95_us=45000, fresh_p99_us=68200,
                mib_s=3300 if arm == "B" else 3000, host={"vmm": host(1 if arm == "B" else 2), "relay": host(0.2)},
                guest=role.guest_delta(first, last))


def make_window(root, now, scopes):
    instant = datetime.fromtimestamp(now, timezone.utc)
    def at(seconds):
        return (instant + timedelta(seconds=seconds)).isoformat()
    fleet = {"generatedAt": at(-1), "runners": [
        {"connection": "online", "runner": {"displayName": name, "active": True,
         "activeLeases": 0, "capacity": count, "lastSeenAt": at(-3)}}
        for name, count in (("Gamma-128GB.local", 6), ("Gamma-128GB Linux CI (isolated VM)", 1))]}
    release = {"owner": "fixture-owner", "reservation": "fixture-window", "host": "Gamma-128GB.local",
               "exclusive": True, "starts_at": at(-10), "expires_at": at(180), "modes": ["host-role"],
               "scopes": [str(s.resolve()) for s in scopes],
               "effective_disk_gate": {"passed": True, "checked_at": at(-4), "expires_at": at(120), "source": "fixture"}}
    paths = root / "fleet.json", root / "release.json"
    for path, data in zip(paths, (fleet, release)):
        path.write_text(json.dumps(data))
    return paths


class HostRoleTests(unittest.TestCase):
    def test_schedule_varies_only_the_role_in_balanced_pairs(self):
        result = subprocess.run([sys.executable, "-B", str(Path(pilot.__file__)), "--mode", "host-role",
                                 "--seed", "34205"], check=True, capture_output=True, text=True)
        plan = json.loads(result.stdout)
        a, b = plan["arms"]["A"], plan["arms"]["B"]
        self.assertEqual((a.pop("process_type"), b.pop("process_type")), ("Standard", "Interactive"))
        self.assertEqual(a, b)
        self.assertEqual(plan["order"]["scored"], ["BA", "AB", "AB", "BA"])
        with self.assertRaises(ValueError):
            pilot.arm_settings("host-role", workers=4)

    def test_saved_and_live_roles_must_match_the_same_supervisor(self):
        with gzip.open(gamma_contrasts.VM, "rt") as stream:
            scopes = json.load(stream)["scopes"]
        controls = []
        for expected in ("Standard", "Interactive"):
            home = Path("/example") / expected
            observed = scopes["role-" + expected.lower()]["launch_role"]
            pid = next(int(line.split("=")[1]) for line in observed.splitlines() if line.strip().startswith("pid ="))
            env = {"MICROPOD_CI_HOME": str(home), "MICROPOD_CI_PORT_RELAY": "kqueue-interactive"}
            job = {"Label": expected, "ProcessType": expected, "ProgramArguments": ["/tool", "ci", "serve"],
                   "EnvironmentVariables": env}
            live = observed + "\n" + "\n".join(f"\t\t{k} => {v}" for k, v in env.items())
            def verify(j=job, record=live, owner=pid):
                return role.verify_job(j, record, owner, home, expected)
            controls.append(verify()["job_controls_sha256"])
            self.assertNotEqual(controls[-1], verify(dict(job, Nice=7))["job_controls_sha256"])
            self.assertNotEqual(controls[-1], verify(record=live + "\n\t\tMICROPOD_OTHER => changed")["job_controls_sha256"])
            for wrong in (dict(job, ProcessType="Background"), dict(job, ProgramArguments=["/tool", "ci", "start"])):
                with self.assertRaises(ValueError):
                    verify(wrong)
            for bad_live in (live.replace("spawn type =", "role ="), live + "\n\tpid = 111",
                             live.replace("kqueue-interactive", "kqueue-throughput")):
                with self.assertRaises(ValueError):
                    verify(record=bad_live)
            with self.assertRaises(ValueError):
                verify(owner=pid + 1)
        self.assertEqual(*controls)

    def test_network_and_irq_counters_keep_their_scopes_and_detect_resets(self):
        files = network_files()
        sample = role.guest_counters(files, dict.fromkeys(role.LINK_ERRORS, 0))
        fields = sample["counters"]
        self.assertEqual((fields["tx_packets"], fields["numeric_irqs"], fields["net_rx_softirqs"],
                          fields["tcp_out_resets"]), (24, 10, 32, 2))
        self.assertEqual(fields["total_irqs"], 13410)
        later = dict(sample, monotonic_ns=sample["monotonic_ns"] + 2_000_000_000,
                     counters=dict(fields, rx_packets=30, numeric_irqs=None))
        delta = role.guest_delta(sample, later)
        self.assertEqual(delta["per_second"]["rx_packets"], 4)
        self.assertIsNone(delta["per_second"]["numeric_irqs"])
        for bad in (dict(later, boot="new"), dict(later, counters=dict(fields, tx_packets=1))):
            with self.assertRaises(ValueError):
                role.guest_delta(sample, bad)
        self.assertIsNone(role.numeric_irqs(""))
        with self.assertRaises(ValueError):
            role.numeric_irqs("CPU0 CPU1\n 31: 4 PCI virtio")
        with self.assertRaises(ValueError):
            role.guest_counters(dict(files, **{"/proc/net/dev": ""}), dict.fromkeys(role.LINK_ERRORS, 0))

    def test_preflight_binds_the_role_to_the_vmm_disk_and_the_read_only_probe(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home, scope = root / "standard", root / "data" / "service"
            home.mkdir()
            scope.mkdir(parents=True)
            for key, value in {"base": "standard", "id": "cid", "name": "marker", "addr": "127.0.0.1:8000",
                               "vmm": "101", "relay": "102"}.items():
                (scope / key).write_text(value)
            sock = home / "oci.sock"
            sock.touch()
            config = dict(worker="w", kernel="/same/Image", memoryMiB=4096, publishedPath="macvlan")
            session = dict(instance="boot", nativeOCI=True, started=True, owner={"pid": 102},
                           publishedRelayWorkers=2, publishedRelayCallbackEvents=128,
                           readySocket=dict(worker="w", device=sock.stat().st_dev, inode=sock.stat().st_ino))
            for name, data in (("worker", config), ("session", session)):
                (home / (name + ".json")).write_text(json.dumps(data))
            job = dict(Label="standard-job", ProcessType="Standard", ProgramArguments=["/micropod", "ci", "serve"],
                       EnvironmentVariables={"MICROPOD_CI_HOME": str(home), "MICROPOD_CI_PORT_RELAY": "kqueue-interactive"})
            owner = scope.parent / "standard"
            owner.mkdir()
            (owner / "job.plist").write_bytes(plistlib.dumps(job))
            info = dict(ID="w", NCPU=4, MemTotal=4 << 30, Labels=["io.micropod.instance=boot"], ServerVersion="test")
            state = {"cpu.max": "400000 100000", "cpuset.cpus.effective": "0-3", "memory.max": "1073741824",
                     "pids.max": "512", "release": "7.3.5-micropod", "interfaces": {"mppub0": {}}}
            container = dict(Id="cid", Name="/marker", State={"Running": True}, Image=gamma_contrasts.IMAGE,
                             Config={"Cmd": ["-listen", ":8080", "-marker", "marker"]},
                             Mounts=[{"Destination": "/mpcheck", "RW": False}],
                             NetworkSettings={"Ports": {"8080/tcp": ["binding"]}})
            outputs = {"vmm": "/System/example/com.apple.Virtualization.VirtualMachine", "probe": role.GUEST_PROBE_SHA256}
            def command(*args):
                if args[0] == "docker":
                    operation = args[-1] if args[3] == "exec" else args[3]
                    return {"info": json.dumps(info), "inspect": json.dumps(container), "port": "127.0.0.1:8000",
                            "state": json.dumps(state), "routes": json.dumps({"mppub0": [pilot.DIRECT_ROUTE]}),
                            "-self-sha256": outputs["probe"], "-net-info": json.dumps(network_files())}[operation]
                if args[0] == "ps":
                    return outputs["vmm"]
                if args[0] == "lsof":
                    return "101"
                if args[0] == "launchctl":
                    return ("\tpid = 102\n\tspawn type = daemon (3)\n\t\tMICROPOD_CI_PORT_RELAY => kqueue-interactive"
                            + "\n\t\tMICROPOD_CI_HOME => " + str(home))
                if args[-1].endswith("/id"):
                    return "marker"
                if args[-1].endswith("/metrics"):
                    return json.dumps({"network": {"published_link": dict.fromkeys(role.LINK_ERRORS, 0)}})
                self.fail(f"unexpected command {args}")
            with patch.object(pilot, "command", side_effect=command), \
                    patch.object(pilot, "mapped_digest", return_value="same-mapped-executable"), \
                    patch.object(pilot, "digest", return_value=pilot.STOCK_KERNEL):
                fx = pilot.inspect(scope, 4, False, "Standard")
                self.assertEqual(fx["service_limits"], {"cpu.max": "400000 100000",
                                                       "memory.max": "1073741824", "pids.max": "512"})
                self.assertEqual((fx["process_type"], fx["spawn_type"], fx["pids"]["relay"]),
                                 ("Standard", "daemon (3)", 102))
                with self.assertRaisesRegex(ValueError, "expected live Interactive"):
                    pilot.inspect(scope, 4, False, "Interactive")
                for field, message in (("vmm", "Apple VMM"), ("probe", "guest probe")):
                    with patch.dict(outputs, {field: "wrong"}), self.assertRaisesRegex(ValueError, message):
                        pilot.inspect(scope, 4, False, "Standard")
                container["Mounts"][0]["RW"] = True
                with self.assertRaisesRegex(ValueError, "read-only"):
                    pilot.inspect(scope, 4, False, "Standard")

    def test_decision_rejects_a_faster_dirty_or_slower_to_schedule_candidate(self):
        def series():
            return {(n, arm): measured_row(arm) for n in range(1, 5) for arm in "AB"}
        result = role.decision(series(), 4)
        self.assertEqual(result["verdict"], "eligible for confirmation")
        self.assertAlmostEqual(result["median_paired_throughput_change_pct"], 10)
        self.assertEqual(result["median_paired_change"]["vmm_wait_s_per_s"], -1)
        self.assertEqual(result["arms"]["B"]["cpu_s_per_gib"]["median"], 1)
        for fields in ({"clean": False}, {"fresh_failed": None}, {"reopened": 1},
                       {"fresh_p95_us": 75001, "fresh_p99_us": 77000}):
            rows = series()
            rows[2, "B"].update(fields)
            self.assertEqual(role.decision(rows, 4)["verdict"], "reject")
        for field in ("tx_dropped", "tcp_out_resets", "tcp_established_resets", "parent_tx_queue_timeouts"):
            rows = series()
            rows[1, "B"]["guest"]["delta"][field] += 1
            self.assertEqual(role.decision(rows, 4)["verdict"], "reject")
        for name in ("vmm", "relay"):
            rows = series()
            for n in range(1, 5):
                rows[n, "B"]["host"][name]["wait_s_per_s"] = 3
            self.assertEqual(role.decision(rows, 4)["verdict"], "reject")
        rows = series()
        for n in range(1, 5):
            rows[n, "B"]["mib_s"] = rows[n, "A"]["mib_s"]
        self.assertEqual(role.decision(rows, 4)["verdict"], "reject")
        rows = series()
        rates = rows[1, "A"]["guest"]["per_second"]
        rates["numeric_irqs"] = None
        partial = role.decision(rows, 4)
        self.assertEqual(partial["verdict"], "eligible for confirmation")
        self.assertIn("total_irqs_per_s", partial["arms"]["A"])
        self.assertNotIn("numeric_irqs_per_s", partial["arms"]["A"])
        rates["total_irqs"] = None
        self.assertEqual(role.decision(rows, 4)["verdict"], "inconclusive")
        del rows[4, "A"]
        with self.assertRaises(ValueError):
            role.decision(rows, 4)

    def test_busy_lane_expired_clearance_and_wrong_scope_refuse_live_work(self):
        now = 1_795_385_000
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            scopes = root / "a", root / "b"
            f, r = make_window(root, now, scopes)
            self.assertEqual(role.check_window(f, r, scopes, now)["owner"], "fixture-owner")
            for offset, dest in ((0, [root / "wrong"]), (100, scopes)):
                with self.assertRaises(ValueError):
                    role.check_window(f, r, dest, now + offset)
            data = json.loads(r.read_text())
            data["effective_disk_gate"]["expires_at"] = data["starts_at"]
            r.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, "disk clearance"):
                role.check_window(f, r, scopes, now)
            make_window(root, now, scopes)
            data = json.loads(f.read_text())
            data["runners"][1]["runner"]["activeLeases"] = 1
            f.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, "has a lease"):
                role.check_window(f, r, scopes, now)

    def test_hosted_fleet_keeps_server_time_and_rejects_an_online_leased_runner(self):
        archive = Path(__file__).resolve().parents[2] / "docs/benchmarks/2026-11-23/gamma-fleet-1611-aedt.json"
        hosted = json.loads(archive.read_text())
        now = role.timestamp(hosted["serverTime"])
        self.assertEqual([rig["leasedSlots"] for rig in hosted["rigs"]], [4, 1])
        self.assertEqual(hosted["rigs"][1]["state"], "online")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            scopes = [root / "a", root / "b"]
            fleet, release = make_window(root, now, scopes)
            with self.assertRaisesRegex(ValueError, "has a lease"):
                role.check_window(archive, release, scopes, now)
            hosted["rigs"][0].update(state="online", leasedSlots=0)
            fleet.write_text(json.dumps(hosted))
            with self.assertRaisesRegex(ValueError, "has a lease: Gamma-128GB Linux CI"):
                role.check_window(fleet, release, scopes, now)
            hosted["rigs"][1]["leasedSlots"] = 0
            def observe(data=hosted, at=now):
                fleet.write_text(json.dumps(data))
                return role.check_window(fleet, release, scopes, at)
            admitted = observe()
            self.assertEqual(admitted["fleet_time"], hosted["serverTime"])
            first_heartbeat = min(role.timestamp(r["lastSeenAt"]) for r in hosted["rigs"])
            self.assertEqual(admitted["valid_until_epoch"], first_heartbeat + 90)
            with self.assertRaisesRegex(ValueError, "unavailable"):
                observe(at=first_heartbeat + 91)
            for patch in ({"leasedSlots": None}, {"leasedSlots": False}, {"leasedSlots": -1},
                          {"capacity": 0}, {"acceptingWork": False}, {"state": "draining"},
                          {"snapshotFreshness": "stale"}, {"connectionState": "offline"}):
                with self.subTest(patch=patch), self.assertRaises(ValueError):
                    observe(dict(hosted, rigs=[hosted["rigs"][0], dict(hosted["rigs"][1], **patch)]))
            for bad in (dict(hosted, truncated=True), dict(hosted, runners=[]), dict(hosted, project="other"),
                        dict(hosted, rigs=hosted["rigs"] * 2), dict(hosted, rigs=hosted["rigs"][:1])):
                with self.assertRaises(ValueError):
                    observe(bad)

    def test_mid_attempt_handoff_loss_stops_only_our_child_and_keeps_output(self):
        with patch.object(pilot.time, "time", return_value=100):
            receipt = {}
            def window():
                if receipt:
                    raise ValueError("handoff ended")
                receipt["started"] = True
            with self.assertRaisesRegex(ValueError, "handoff ended"):
                pilot.run_in_window([sys.executable, "-c", "import time; print('ready', flush=True); time.sleep(15)"],
                                    window, receipt)
            self.assertEqual(receipt["stdout"].strip(), "ready")
            self.assertLess(receipt["exit_code"], 0)

    def test_pilot_writes_the_verdict_after_rechecking_both_jobs(self):
        now = 1_795_385_000
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            a, b = root / "a", root / "b"
            a.mkdir()
            b.mkdir()
            f, r = make_window(root, now, (a, b))
            args = Namespace(seed=34205, mode="host-role", tools=root, check=False, a=a, b=b, out=root/"run",
                             fleet=f, release=r)
            def inspect(path, cpus, orb, process_type):
                self.assertEqual((cpus, orb), (4, False))
                return {"engine": path.name, "name": path.name, "address": path.name, "id": path.name,
                        "pids": {"vmm": 1 if path == a else 3, "relay": 2 if path == a else 4},
                        "cpuset": "0-3", "instance": path.name, "worker": path.name, "relay_workers": 2,
                        "kernel_image_sha256": pilot.STOCK_KERNEL, "callback_events": 128, "route": pilot.DIRECT_ROUTE,
                        "release": "7.3.5-micropod", "engine_version": "same", "cli_sha256": "same",
                        "service_env_sha256": "same", "process_type": process_type, "guest_boot": path.name,
                        "job_controls_sha256": "same settings"}
            def attempt(tools, fixture, birth, row, check):
                check()
                row.update(measured_row(row["arm"]))
            sampled_delta = measured_row("A")["guest"]
            with patch.object(pilot.platform, "node", return_value="Gamma-128GB"), \
                    patch.object(pilot.time, "time", return_value=now), \
                    patch.object(pilot, "inspect", side_effect=inspect) as inspecting, \
                    patch.object(pilot, "digest", side_effect=lambda p: dict(pilot.HASHES, fixed=role.CLIENT_SHA256)[p.name]), \
                    patch.object(pilot, "snapshot", return_value={"tasks": []}), \
                    patch.object(role, "guest_sample", side_effect=lambda command, fx: {"boot": fx["guest_boot"]}), \
                    patch.object(role, "guest_delta", return_value=sampled_delta), \
                    patch.object(pilot, "attempt", side_effect=attempt) as timed:
                pilot.run(args, pilot.plan(args.seed, 4))
                result = json.loads((args.out / "complete.json").read_text())
                self.assertEqual(result["host_role"]["verdict"], "eligible for confirmation")
                self.assertEqual((inspecting.call_count, timed.call_count), (4, 14))
                self.assertEqual(result["clean_scored"], {"A": 4, "B": 4})
                self.assertTrue((args.out / "scored-4-B.json").exists())
                args.out = root / "tailed"
                def slow_tail(tools, fixture, birth, row, check):
                    attempt(tools, fixture, birth, row, check)
                    if (row["phase"], row["pair"], row["arm"]) == ("scored", 2, "B"):
                        row.update(fresh_p95_us=75001, fresh_p99_us=80000)
                timed.side_effect = slow_tail
                with self.assertRaisesRegex(ValueError, "Interactive fresh p95 exceeded"):
                    pilot.run(args, pilot.plan(args.seed, 4))
                self.assertEqual(json.loads((args.out / "complete.json").read_text())["host_role"]["verdict"], "reject")
                args.out = root / "mismatched"
                def mismatch(path, *args, **kwargs):
                    fx = inspect(path, *args, **kwargs)
                    if path == b:
                        fx["job_controls_sha256"] = "different Nice setting"
                    return fx
                inspecting.side_effect = mismatch
                timed.reset_mock()
                with self.assertRaisesRegex(ValueError, "beyond ProcessType"):
                    pilot.run(args, pilot.plan(34205, 4))
                timed.assert_not_called()
                self.assertFalse((args.out / "complete.json").exists())


if __name__ == "__main__":
    unittest.main()
