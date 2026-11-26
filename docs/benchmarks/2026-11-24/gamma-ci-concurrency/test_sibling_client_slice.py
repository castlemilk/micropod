"""Offline checks for the native client slice and the locked issuing thread."""

import hashlib
import tempfile
import unittest
from pathlib import Path

import sibling_client_slice as trial
from qualify import ROOT


def thread(tid, slice_ns):
    return {"tid": tid, "policy": 0, "nice": 0, "priority": 0,
            "cpus_allowed_list": "1", "slice_ns": slice_ns}


def client(requested, effective):
    job = {"name": "client", "mask": "1", "client_slice_ns": requested}
    receipt = {"window": {"pid": 8, "threads": [thread(8, effective), thread(9, effective)]},
               "pace": {"issuing_tid": 9}}
    return job, receipt


class NativeClientSliceTests(unittest.TestCase):
    def test_source_changes_only_the_pre_gate_issuing_thread_proof(self):
        source = ROOT / "scripts/netbench/quiet/main.go"
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            target = folder / "quiet-http.go"
            plan = trial.stage(source, target, folder)
            observed = target.read_bytes()
            plan["quiet_source_sha256"] = hashlib.sha256(observed).hexdigest()
            self.assertEqual(trial.rewrite_probe(observed, restore=True), source.read_bytes())
            trial.check_probe(folder, plan)
            bad_source = observed.replace(b"clock.wait(ctx, due)", b"clock.wait(ctx, due+1)")
            self.assertNotEqual(bad_source, observed)
            target.write_bytes(bad_source)
            plan["quiet_source_sha256"] = hashlib.sha256(bad_source).hexdigest()
            with self.assertRaisesRegex(ValueError, "pinned sources"):
                trial.check_probe(folder, plan)

    def test_native_client_control_and_candidate_keep_the_peer_coarse(self):
        for us in (0, 250, 500, 750):
            for arm, requested in (("A", us * 1000), ("B", 0)):
                with self.subTest(arm=arm, slice_us=us):
                    job, receipt = client(requested, requested or trial.BASE_NS)
                    trial.check_client(receipt, job, arm, us * 1000, paced=True)
                    del receipt["pace"]
                    trial.check_client(receipt, job, arm, us * 1000, paced=False)

    def test_rejects_wrong_issuing_identity_affinity_and_slice(self):
        job, receipt = client(250_000, 250_000)
        receipt["pace"]["issuing_tid"] = 99
        with self.assertRaisesRegex(ValueError, "issuing thread"):
            trial.check_client(receipt, job, "A", 250_000, paced=True)
        receipt["pace"]["issuing_tid"] = 9
        actual = receipt["window"]["threads"][-1]
        actual["cpus_allowed_list"] = "0-3"
        with self.assertRaises(ValueError):
            trial.check_client(receipt, job, "A", 250_000, paced=True)
        actual["cpus_allowed_list"] = "1"
        actual["slice_ns"] = trial.BASE_NS
        with self.assertRaisesRegex(ValueError, "250000 ns slice"):
            trial.check_client(receipt, job, "A", 250_000, paced=True)

    def test_service_and_build_child_must_keep_the_coarse_slice(self):
        policy = [thread(8, trial.BASE_NS)]
        job = {"name": "service", "mask": "1", "server_pid": 8, "requested_slice_ns": 0,
               "affinity": {"pid": 8}, "http_policy_threads": policy, "threads": [dict(policy[0])]}
        trial.check_service(job)
        job["threads"][0]["slice_ns"] = 250_000
        with self.assertRaisesRegex(ValueError, "service or holder"):
            trial.check_service(job)
        rows = [{"policy": {"dispatcher": thread(10, trial.BASE_NS), "child": thread(11, trial.BASE_NS)}}]
        trial.check_builds(rows)
        rows[0]["policy"]["child"]["slice_ns"] = 250_000
        with self.assertRaisesRegex(ValueError, "build slot 0"):
            trial.check_builds(rows)


if __name__ == "__main__":
    unittest.main()
