"""Offline tests for the CI fanout study using an archived client and explicit mock clocks."""

import copy
import hashlib
import json
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import churn
import fanout_ci as study

ARCHIVE = Path(__file__).resolve().parent / "20261124T112552Z-churn-tncpeyjp"


def save(path, value):
    path.write_text(json.dumps(value))


class FanoutStudyTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)
        self.plan = {"schedule": study.schedule(), "client_sha256": study.peer.CLIENT,
                     "target_files": {a: str(self.folder / f"targets-{a}.tsv") for a in "AB"},
                     "resident_services": 32, "build_slots": 4, "streams": 32, "fresh_per_second": 40}
        save(self.folder / "fanout-plan.json", self.plan)
        fixtures = study.replay.read(ARCHIVE, "fixtures-before.json")
        save(self.folder / "fixtures-before.json", fixtures)
        run = study.replay.read(ARCHIVE, "plan.json")
        save(self.folder / "plan.json", dict(run, profile="fanout"))
        originals = {a: study.replay.read(ARCHIVE, f"churn-0-{a}.json") for a in "AB"}
        self.tenants = {}
        for arm in "AB":
            inventory = study.replay.read(ARCHIVE, f"tenants-{arm}-32.json")
            self.tenants[arm] = inventory["tenants"]
            save(self.folder / f"tenants-{arm}-32.json", inventory)
            (self.folder / f"targets-{arm}.tsv").write_text((ARCHIVE / f"targets-{arm}.tsv").read_text())
        tick = 1000
        for stage in self.plan["schedule"]:
            for arm in stage["order"]:
                row = copy.deepcopy(originals[arm])
                ids = sorted(t["id"] for t in self.tenants[arm])
                index = stage["target_index"]
                args = ["--targets", self.plan["target_files"][arm]]
                if index is not None:
                    target = self.tenants[arm][index]
                    args = [f"http://127.0.0.1:{target['port']}", target["name"]]
                    row["client"]["published_ports"] = 1
                if stage["cell"].endswith("-idle"):
                    row.update(running_ephemeral_at_barrier=0, jobs=[])
                row.update(block=stage["number"], cell=stage["cell"], resident_ids_before=ids, resident_ids_after=ids,
                           job_release_monotonic_s=tick, invocation={"arguments": args, "started_s": tick + 1,
                                                                    "ended_s": tick + 8})
                manifest = self.folder / f"targets-{arm}.tsv"
                row["invocation"]["target_sha256"] = hashlib.sha256(manifest.read_bytes()).hexdigest() if index is None else None
                for k, time_s, ticks in (("counter_before", tick, 10), ("counter_after", tick + 9, 50)):
                    row[k] = {"start_s": time_s, "end_s": time_s + 0.1,
                              "host": {"epoch_ns": time_s * 10**9, "tick_numer": 1, "tick_denom": 1,
                                       "tasks": [{"pid": pid, "birth_ticks": 3, "user_ticks": ticks,
                                                  "system_ticks": ticks, "runnable_ticks": ticks * 3}
                                                 for pid in fixtures[arm]["pids"].values()]}}
                save(self.folder / f"fanout-{stage['number']}-{arm}.json", row)
                tick += 20

    def test_balanced_design_and_complete_replay(self):
        for cell in study.CELLS:
            stages = [r for r in study.schedule() if r["cell"] == cell]
            self.assertEqual({r["number"] % 4 for r in stages}, set(range(4)))
            self.assertEqual(sorted(r["order"] for r in stages), ["AB", "AB", "BA", "BA"])
        for block in range(4):
            one_port = {r["target_index"] for r in study.schedule() if r["block"] == block and r["cell"].startswith("one")}
            self.assertEqual(one_port, {study.SINGLE_TENANTS[block]})
        result = study.assess(self.folder)
        self.assertEqual(result["blocks"], 4)
        for engine in result["arms"].values():
            self.assertEqual(engine["interaction_ratios_by_block"], [1] * 4)
            ci = engine["cell_medians"]["many-ci"]
            self.assertGreater(ci["min_scored_seconds_with_released_passing_jobs"], 5)
            self.assertAlmostEqual(ci["successful_jobs_per_second"] * ci["last_job_s"], 30)

    def test_interaction_uses_many_ci_over_idle_divided_by_one_ci_over_idle(self):
        predicted = []
        for stage in study.schedule():
            if stage["cell"] != "many-ci":
                continue
            path = self.folder / f"fanout-{stage['number']}-A.json"
            row = json.loads(path.read_bytes())
            raw = row["client"]
            predicted.append(raw["window_s"] / 6.75)
            raw["window_s"] = 6.75
            raw["mib_s"] = raw["bytes"] / 2**20 / raw["window_s"]
            save(path, row)
        result = study.assess(self.folder)["arms"]
        for observed, expected in zip(result["A"]["interaction_ratios_by_block"], predicted, strict=True):
            self.assertAlmostEqual(observed, expected)
        self.assertEqual(result["B"]["interaction_ratios_by_block"], [1] * 4)

    def test_rejects_changed_traffic_jobs_or_counters(self):
        rowpath = self.folder / "fanout-0-A.json"
        original = json.loads(rowpath.read_bytes())
        cases = [
            ("wrong port count", lambda x: x["client"].update(published_ports=32)),
            ("wrong single tenant", lambda x: x["invocation"]["arguments"].__setitem__(1, "foreign")),
            ("overlapping counters", lambda x: x["counter_before"].update(end_s=x["invocation"]["ended_s"])),
            ("extra job on idle path", lambda x: x.update(running_ephemeral_at_barrier=1)),
            ("changed resident", lambda x: x["resident_ids_after"].pop()),
            ("unaccounted bytes", lambda x: x["client"]["bulk_body_bytes"]["drain"].update(bytes=0)),
        ]
        for label, mutate in cases:
            with self.subTest(label=label):
                row = copy.deepcopy(original)
                mutate(row)
                save(rowpath, row)
                with self.assertRaises(ValueError):
                    study.assess(self.folder)
        save(rowpath, original)
        stage = next(s for s in study.schedule() if s["cell"].endswith("-ci"))
        path = self.folder / f"fanout-{stage['number']}-B.json"
        row = json.loads(path.read_bytes())
        next(j for j in row["jobs"] if j["kind"] == "pass")["receipts"][0]["product"] = "d" * 64
        save(path, row)
        with self.assertRaisesRegex(ValueError, "different revisions"):
            study.assess(self.folder)

    def test_rejects_changed_target_manifest_and_build_concurrency(self):
        stage = next(s for s in study.schedule() if s["cell"] == "many-ci")
        path = self.folder / f"fanout-{stage['number']}-A.json"
        original = json.loads(path.read_bytes())
        row = copy.deepcopy(original)
        row["invocation"]["target_sha256"] = "0" * 64
        save(path, row)
        with self.assertRaisesRegex(ValueError, "target cardinality"):
            study.assess(self.folder)
        row = copy.deepcopy(original)
        for job in row["jobs"]:
            job["submitted_s"] = 0
        save(path, row)
        with self.assertRaisesRegex(ValueError, "four slots"):
            study.assess(self.folder)

    def test_scoped_single_port_is_restored_after_client_error(self):
        a = SimpleNamespace(lock=threading.Lock(), receiver_group=21, offered=None, peer_scopes=())
        c = SimpleNamespace(admission=a, jobs=self.tenants["A"], folder=self.folder, arm="A")
        fixed = self.folder / "fixed"
        with patch.object(churn.terminal, "digest", return_value=study.peer.CLIENT):
            args = churn.traffic_arguments(c, fixed, 3)
        def failing(*cmd, **kwargs):
            self.assertEqual(cmd, (fixed, *args))
            self.assertEqual((a.peer_scopes[-1] / "name").read_text(), self.tenants["A"][3]["name"])
            raise RuntimeError("client stopped")
        with patch.object(churn.terminal, "invoke", side_effect=failing):
            with self.assertRaisesRegex(RuntimeError, "client stopped"):
                churn.run_traffic(c, fixed, args)
        self.assertEqual((a.receiver_group, a.offered, a.peer_scopes), (21, None, ()))

    def test_historical_input_does_not_fill_unmeasured_cells(self):
        archived = study.historical(ARCHIVE)
        self.assertEqual(len(archived["pairs"]), 2)
        self.assertTrue(all(r["all_micropod_streams_below_every_orbstack_stream"] for r in archived["pairs"]))
        with self.assertRaises(FileNotFoundError):
            study.assess(ARCHIVE)


if __name__ == "__main__":
    unittest.main()
