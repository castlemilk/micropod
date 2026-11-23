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
                                  tools=dict(peer.HASHES, fixed=peer.CLIENT_SHA256)))
    fixtures = {}
    clock = 1000
    write(root, "handoff.json", admission(clock-2))
    for arm in "AB":
        fixtures[arm] = dict(engine=arm, id=arm, address=arm, name=arm, scope="/fixture/"+arm,
                             cpus=6, cpuset="0-3", memory_bytes=4*2**30,
                             image_config=peer.IMAGE, service_limits=peer.LIMITS, release=arm, engine_version=arm,
                             pids={"vmm": 10, "relay": 20} if arm == "A" else {"vmm": 30})
    fixtures["A"].update(cli_sha256=CLI_SHA, relay_workers=4, callback_events=128, route=peer.DIRECT_ROUTE,
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
                client = dict(streams=32, arrivals=240, period_us=25000, bytes=total, per_stream_bytes=[stream]*32,
                              window_s=6, mib_s=total/2**20/6, fresh_p50_us=900, fresh_p95_us=75000, fresh_p99_us=80000,
                              errors=None, reopened=0)
                row = dict(phase=phase, pair=n, arm=arm, before=snapshot(clock), after=snapshot(clock+7),
                           admission=admission(clock-.1), admission_after=admission(clock+7.1),
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
