import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

import peer_verdict as peer


CLI_SHA = "a" * 64


def iso(seconds):
    return datetime.fromtimestamp(seconds, timezone.utc).isoformat()


def admission(t):
    return dict(owner="benchmark owner", reservation="peer slot", mode="peer", scopes=["/fixture/A", "/fixture/B"],
                observed_at=iso(t), fleet_time=iso(t-3), starts_at=iso(990), expires_at=iso(1500),
                valid_until_epoch=t+87,
                effective_disk_gate=dict(checked_at=iso(980), expires_at=iso(1500), source="disk check", passed=True))


def write(root, name, data):
    (root / name).write_text(json.dumps(data))


def completed_run(root):
    order = peer.plan(34203, 16)
    write(root, "plan.json", dict(seed=34203, mode="peer", host="Gamma-128GB.local", macos="26.5.1",
                                  arms=peer.arm_settings("peer", 4, 6), order=order,
                                  tools=dict(peer.HASHES, fixed=peer.LEGACY_P50_CLIENT_SHA256)))
    fixtures = {}
    clock = 1000
    write(root, "handoff.json", admission(clock-2))
    for arm in "AB":
        fixtures[arm] = dict(engine=arm, id=arm, address="127.0.0.1:9001" if arm == "A" else "127.0.0.1:9002",
                             name=arm, scope="/fixture/"+arm,
                             cpus=6, cpuset="0-3", memory_bytes=4*2**30,
                             image_config=peer.IMAGE, service_limits=peer.LIMITS, release=arm, engine_version=arm,
                             pids={"vmm": 10, "relay": 20} if arm == "A" else {"vmm": 30})
    fixtures["A"].update(cli_sha256=CLI_SHA, relay_workers=4, callback_events=128, read_bytes=262144, route=peer.DIRECT_ROUTE,
                         kernel_image_sha256=peer.STOCK_KERNEL)
    for phase, slots in order.items():
        for n, pair in enumerate(slots, 1):
            for arm in pair:
                def snapshot(t):
                    return dict(epoch_ns=t * 10**9, tick_numer=1, tick_denom=1,
                                tasks=[dict(pid=p, birth_ticks=p, user_ticks=t*200, system_ticks=t*100,
                                            runnable_ticks=t*500) for p in fixtures[arm]["pids"].values()])
                stream = (6 if arm == "A" else 3) * 2**20
                total = 32 * stream
                client = dict(published_ports=1, streams=32, arrivals=240, period_us=25000, bytes=total, per_stream_bytes=[stream]*32,
                              window_s=6, mib_s=total/2**20/6, fresh_p50_us=900, fresh_p95_us=75000, fresh_p99_us=80000,
                              errors=None, reopened=0)
                row = dict(phase=phase, pair=n, arm=arm, before=snapshot(clock), after=snapshot(clock+7),
                           admission=admission(clock-.1), admission_after=admission(clock+7.1),
                           client_arguments=["http://" + fixtures[arm]["address"], arm],
                           stdout=json.dumps(client), exit_code=0, clean=True)
                write(root, f"{phase}-{n}-{arm}.json", row)
                clock += 8
    write(root, "fixtures.json", fixtures)
    write(root, "complete.json", dict(identity_rechecked=True, ratio_direction="Micropod/OrbStack",
                                      median_ratio=-99, bootstrap_ci95=[-100, 500]))
    return fixtures


def change_client(root, number, arm, *, is_clean, **updates):
    name = f"scored-{number}-{arm}.json"
    r = json.loads((root/name).read_text())
    client = json.loads(r["stdout"])
    client.update(updates)
    r.update(stdout=json.dumps(client), clean=is_clean)
    write(root, name, r)


class PeerVerdictTests(unittest.TestCase):
    def test_current_pin_requires_full_body_counts_and_recomputes_cost(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            completed_run(root)
            legacy = peer.directory(root, CLI_SHA)
            self.assertIsNone(legacy["pairs"][0]["A"]["invocation_cpu_s_per_bulk_gib"])
            self.assertIsNone(legacy["pairs"][0]["A"]["processes"]["vmm"]["invocation_cpu_s_per_bulk_gib"])
            schedule = json.loads((root/"plan.json").read_text())
            schedule["tools"]["fixed"] = peer.CLIENT_SHA256
            write(root, "plan.json", schedule)
            with self.assertRaisesRegex(ValueError, "attempt load-client hash"):
                peer.directory(root, CLI_SHA)
            body = 8 * 2**20
            for file in [*root.glob("warmup-*.json"), *root.glob("scored-*.json")]:
                row = json.loads(file.read_text())
                for snapshot in (row["before"], row["after"]):
                    for task in snapshot["tasks"]:
                        if task["pid"] == 20:
                            for field in ("user_ticks", "system_ticks", "runnable_ticks"):
                                task[field] *= 3
                client = json.loads(row["stdout"])
                count = client["per_stream_bytes"][0]
                client["bulk_body_bytes"] = {name: dict(bytes=n*32, per_stream_bytes=[n]*32)
                                             for name, n in (("warmup", body), ("scored", count),
                                                             ("drain", body-count), ("invocation", 2*body))}
                row.update(stdout=json.dumps(client), fixed_sha256=peer.CLIENT_SHA256,
                           host={"vmm": {"invocation_cpu_s_per_bulk_gib": 99}})
                write(root, file.name, row)
            report = peer.directory(root, CLI_SHA)
            a = report["pairs"][0]["A"]
            self.assertEqual(a["invocation_bulk_bytes"], 512 * 2**20)
            self.assertAlmostEqual(a["invocation_cpu_s_per_bulk_gib"], 4*7*300*1e-9/.5, delta=1e-15)
            self.assertEqual(a["processes"].keys(), {"vmm", "relay"})
            self.assertEqual(report["pairs"][0]["B"]["processes"].keys(), {"vmm"})
            for role, multiplier in (("vmm", 1), ("relay", 3)):
                proc = a["processes"][role]
                self.assertAlmostEqual(proc["cpu_s_per_gib"], multiplier * 7 * 300e-9 / (192/1024), delta=1e-15)
                self.assertAlmostEqual(proc["invocation_cpu_s_per_bulk_gib"], multiplier * 7 * 300e-9 / .5, delta=1e-15)
                self.assertAlmostEqual(proc["runnable_s"], multiplier * 7 * 500e-9, delta=1e-15)
                self.assertAlmostEqual(proc["wait_s_per_s"], multiplier * 200e-9, delta=1e-15)
            self.assertEqual(report["median_ratio"], legacy["median_ratio"])
            row = json.loads((root/"scored-16-B.json").read_text())
            client = json.loads(row["stdout"])
            del client["bulk_body_bytes"]["drain"]
            row["stdout"] = json.dumps(client)
            write(root, "scored-16-B.json", row)
            with self.assertRaisesRegex(ValueError, "missing drain"):
                peer.directory(root, CLI_SHA)
            schedule["tools"]["fixed"] = peer.LEGACY_P50_CLIENT_SHA256
            write(root, "plan.json", schedule)
            with self.assertRaisesRegex(ValueError, "attempt load-client hash"):
                peer.directory(root, CLI_SHA)

    def test_historical_archive_replays_including_failed_peer_and_unknown_p50(self):
        r = peer.archived()
        self.assertEqual((r["verdict"], r["common_clean_pairs"], r["micropod_pair_wins"]), ("did not qualify", 15, 7))
        self.assertAlmostEqual(r["median_ratio"], .8540445809525004)
        self.assertEqual(r["bootstrap_ci95"], [.7090052427711508, 1.2586594205448958])
        self.assertEqual(r["pairs"][11]["B"]["fresh_failed"], 1)
        self.assertFalse(r["pairs"][11]["B"]["clean"])
        s = r["arm_clean_medians_and_all_attempt_counts"]["Micropod"]
        self.assertAlmostEqual(s["cpu_s_per_gib"], .9559387517431498)
        self.assertIsNone(s["p50_ms"])

    def test_peer_failures_and_candidate_latency_or_loss_cannot_create_a_win(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            completed_run(root)
            change_client(root, 1, "B", is_clean=False, reopened=1)
            r = peer.directory(root, CLI_SHA)
            self.assertEqual(r["verdict"], "qualified on this workload")
            self.assertEqual(r["common_clean_pairs"], 15)
            self.assertEqual(r["bootstrap_ci95"], [2, 2])
            self.assertEqual(r["pairs"][0]["B"]["bulk_reopens"], 1)
            change_client(root, 2, "B", is_clean=False, reopened=1)
            r = peer.directory(root, CLI_SHA)
            self.assertIn("fewer than 15 common clean pairs", r["reasons"])
            change_client(root, 2, "B", is_clean=True, reopened=0)
            change_client(root, 1, "A", is_clean=False, errors=['Get "http://127.0.0.1/id": EOF'])
            change_client(root, 2, "A", is_clean=True, fresh_p95_us=75001)
            r = peer.directory(root, CLI_SHA)
            self.assertEqual(r["verdict"], "did not qualify")
            self.assertEqual(r["common_clean_pairs"], 15)
            self.assertEqual(r["bootstrap_ci95"], [2, 2])
            self.assertEqual(r["pairs"][0]["A"]["fresh_failed"], 1)
            self.assertIn("Micropod round 2 exceeded 75 ms fresh p95", r["reasons"])

    def test_new_holdout_requires_one_port_and_the_exact_arm_endpoint_on_every_attempt(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            fixtures = completed_run(root)
            for name in ("warmup-2-B.json", "scored-16-A.json"):
                original = json.loads((root/name).read_text())
                for count in (None, True, 32):
                    client = json.loads(original["stdout"])
                    if count is None:
                        del client["published_ports"]
                    else:
                        client["published_ports"] = count
                    write(root, name, dict(original, stdout=json.dumps(client)))
                    with self.subTest(name=name, count=count), self.assertRaisesRegex(ValueError, "one published port"):
                        peer.directory(root, CLI_SHA)
                other = "B" if original["arm"] == "A" else "A"
                url, marker = original["client_arguments"]
                for args in (None, ["--targets", "32-port.tsv"], ["http://" + fixtures[other]["address"], marker], [url, other]):
                    row = original.copy()
                    if args is None:
                        del row["client_arguments"]
                    else:
                        row["client_arguments"] = args
                    write(root, name, row)
                    with self.subTest(name=name, args=args), self.assertRaisesRegex(ValueError, "client arguments"):
                        peer.directory(root, CLI_SHA)
                write(root, name, original)
            for address in ("192.0.2.1:9001", "127.0.0.1:65536"):
                fixtures["A"]["address"] = address
                write(root, "fixtures.json", fixtures)
                with self.subTest(address=address), self.assertRaisesRegex(ValueError, "published loopback port"):
                    peer.directory(root, CLI_SHA)

    def test_new_holdout_requires_the_pinned_client_and_all_three_fresh_percentiles(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            completed_run(root)
            name = "warmup-2-B.json"
            original = json.loads((root/name).read_text())
            for q in (50, 95, 99):
                client = json.loads(original["stdout"])
                del client[f"fresh_p{q}_us"]
                write(root, name, dict(original, stdout=json.dumps(client)))
                with self.assertRaisesRegex(ValueError, f"p{q}"):
                    peer.directory(root, CLI_SHA)
            write(root, name, original)
            plan = json.loads((root/"plan.json").read_text())
            plan["tools"]["fixed"] = peer.HASHES["fixed"]
            write(root, "plan.json", plan)
            with self.assertRaisesRegex(ValueError, "peer controls"):
                peer.directory(root, CLI_SHA)

    def test_same_selected_executable_cannot_hide_a_different_read_cap(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixtures = completed_run(root)
            schedule = json.loads((root / "plan.json").read_text())
            del schedule["arms"]["A"]["read_bytes"]
            del fixtures["A"]["read_bytes"]
            write(root, "fixtures.json", fixtures)
            write(root, "plan.json", schedule)
            self.assertIsNone(peer.directory(root, CLI_SHA)["relay_read_bytes"])
            with self.assertRaisesRegex(ValueError, "read size"):
                peer.directory(root, CLI_SHA, 512)  # Legacy receipts contain no native readback.
            schedule["arms"] = peer.arm_settings("peer", 4, 6, 512)
            write(root, "plan.json", schedule)
            fixtures["A"]["read_bytes"] = 262144
            write(root, "fixtures.json", fixtures)
            with self.assertRaisesRegex(ValueError, "read size"):
                peer.directory(root, CLI_SHA, 512)
            fixtures["A"]["read_bytes"] = 524288
            write(root, "fixtures.json", fixtures)
            with self.assertRaisesRegex(ValueError, "read size"):
                peer.directory(root, CLI_SHA, 256)
            self.assertEqual(peer.directory(root, CLI_SHA, 512)["relay_read_bytes"], 524288)

    def test_wrong_build_missing_quota_overlapping_round_and_missing_attempt_are_invalid(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            fixtures = completed_run(root)
            with self.assertRaisesRegex(ValueError, "candidate hash"):
                peer.directory(root, "b"*64)
            limits = fixtures["A"].pop("service_limits")
            write(root, "fixtures.json", fixtures)
            with self.assertRaises((KeyError, ValueError)):
                peer.directory(root, CLI_SHA)
            fixtures["A"]["service_limits"] = limits
            write(root, "fixtures.json", fixtures)
            name = "scored-16-B.json"
            row = json.loads((root/name).read_text())
            row["before"]["epoch_ns"] = 1
            write(root, name, row)
            with self.assertRaisesRegex(ValueError, "admission observations|windows overlap"):
                peer.directory(root, CLI_SHA)
            (root/name).unlink()
            call = subprocess.run([sys.executable, "-B", peer.__file__, "--run-directory", d,
                                   "--candidate-sha256", CLI_SHA], capture_output=True, text=True)
            self.assertEqual(call.returncode, 2)
            self.assertIn(name, call.stderr)

    def test_missing_stale_or_wrong_owner_observation_never_certifies_a_run(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            completed_run(root)
            name = "scored-1-A.json"
            original = (root/name).read_text()
            for field, change in (("admission", dict(reservation="wrong")),
                                  ("admission", dict(mode="workers")),
                                  ("admission", dict(scopes=["/fixture/B", "/fixture/A"])),
                                  ("admission", dict(fleet_time=iso(900))),
                                  ("admission", dict(valid_until_epoch=990)),
                                  ("admission_after", dict(expires_at=iso(3000))),
                                  ("admission_after", dict(observed_at=iso(1045))),
                                  ("admission_after", None)):
                with self.subTest(field=field, change=change):
                    row = json.loads(original)
                    if change is None:
                        del row[field]
                    else:
                        row[field].update(change)
                    write(root, name, row)
                    with self.assertRaises((KeyError, ValueError)):
                        peer.directory(root, CLI_SHA)
            row = json.loads(original)
            end = row["after"]["epoch_ns"] / 1e9
            row["admission"]["effective_disk_gate"]["expires_at"] = iso(end-3)
            row["admission"]["valid_until_epoch"] = end-3
            row["admission_after"]["effective_disk_gate"]["checked_at"] = iso(end-1)
            write(root, name, row)
            with self.assertRaisesRegex(ValueError, "continuous coverage"):
                peer.directory(root, CLI_SHA)
            row = json.loads(original)
            row["after"]["epoch_ns"] = row["before"]["epoch_ns"] + 10**9
            write(root, name, row)
            with self.assertRaisesRegex(ValueError, "cover the reported client window"):
                peer.directory(root, CLI_SHA)
            (root/name).write_text(original)
            (root/"handoff.json").unlink()
            with self.assertRaisesRegex(ValueError, "handoff.json"):
                peer.directory(root, CLI_SHA)


if __name__ == "__main__":
    unittest.main()
