"""Regression fixtures for the local receiver's worker/callback admission checks."""
import json
from pathlib import Path
from unittest.mock import patch

import receiver


def run():
    evidence = Path(__file__).resolve().parent / "20261124T062433Z"
    stock = json.loads((evidence / "revised-runtime-build.json").read_text())
    fixed = json.loads((evidence / "fixed-workers-runtime-build.json").read_text())
    cases = [
        ("stock-two", stock, 2, "baseline", {}, {}, {}, True),
        ("stock-four-also-changes-budget", stock, 4, "workers", {}, {}, {}, False),
        ("stock-live-read-conflict", stock, 2, "baseline", {"read_bytes": 65536}, {}, {}, False),
        ("fixed-two", fixed, 2, "workers", {"callback_events": 128}, {}, {}, True),
        ("fixed-four", fixed, 4, "workers", {"callback_events": 128}, {}, {}, True),
        ("fixed-four-missing-live-callback", fixed, 4, "workers", {}, {}, {}, False),
        ("fixed-four-live-24", fixed, 4, "workers", {"callback_events": 24}, {}, {}, False),
        ("fixed-four-float-count", fixed, 4, "workers", {"callback_events": 128.0}, {}, {}, False),
        ("fixed-bad-live-read", fixed, 2, "workers", {"callback_events": 128, "read_bytes": 32768}, {}, {}, False),
        ("fixed-missing-seal", fixed, 2, "workers", {"callback_events": 128}, {"controlled_relay": {}}, {}, False),
        ("fixed-mapping-mismatch", fixed, 2, "workers", {"callback_events": 128}, {}, {"worker_executable_sha256": ""}, False),
        ("fixed-no-vnode", fixed, 4, "workers", {"callback_events": 128}, {}, {"mapped_inode": 0}, False),
        ("fixed-wrong-kernel", fixed, 4, "workers", {"callback_events": 128}, {}, {"kernel_image_sha256": ""}, False),
        ("fixed-binary-in-stock-baseline", fixed, 2, "baseline", {"callback_events": 128}, {}, {}, False),
    ]
    for name, build, workers, mode, observation, edited_build, edited_mapping, expected in cases:
        fixture = {"relay_workers": workers, "cli_sha256": build["worker_executable_sha256"], **observation}
        # This suite tests the admission decision after live_attestation.
        # Vnode and session fields here are fixture inputs, never live observations.
        mapping = {"source_revision": build["source_revision"], "mapped_inode": 1,
                   "kernel_image_sha256": receiver.relay.STOCK_KERNEL,
                   "worker_executable_sha256": build["worker_executable_sha256"], **edited_mapping}
        accepted = True
        try:
            receiver.bind_relay_controls(fixture, {**build, **edited_build}, mapping, mode)
        except ValueError:
            accepted = False
        if expected != accepted:
            raise ValueError(f"{name}: expected admission {expected}, got {accepted}")
        if accepted and not (fixture["read_bytes"] == 262144 and fixture["callback_events"] == 128):
            raise ValueError(f"{name}: incorrect admitted controls")
        print(f"{name}: {'admit' if accepted else 'reject'}")


def check_idle():
    for name, previous, idle, diagnostic, should_run, gate in [
        ("at-floor", None, 90.0, False, True, True),
        ("below-floor", None, 89.99, False, False, False),
        ("at-pair-limit", 90.0, 95.0, False, True, True),
        ("over-pair-limit", 96.0, 90.99, False, False, False),
        ("ambient-below-floor", None, 40.0, True, True, False),
        ("ambient-mismatched-starts", 99.0, 92.0, True, True, False),
        ("missing-observation", None, float("nan"), True, False, None),
    ]:
        row = {}
        ran = True
        try:
            receiver.record_idle(row, previous, idle, diagnostic)
        except ValueError:
            ran = False
        if ran != should_run or row.get("idle_gate_passed") is not gate:
            raise ValueError(f"{name}: incorrect idle gate or diagnostic admission")
        print(f"{name}: {'admit' if ran else 'reject'}, idle gate {gate}")


def check_abbreviated_inventory():
    facts = "\n".join(["boot=fixture-boot", "release=" + receiver.path_pilot.STOCK["release"], "machine=aarch64",
                       "config_sha256=" + receiver.path_pilot.CONFIG, "# CONFIG_SCHED_CLASS_EXT is not set",
                       "virtio_nic=eth0", "/sys/class/net/eth0/queues/rx-0", "/sys/class/net/eth0/queues/tx-0",
                       "ethtool_inventory=omitted_in_local_diagnostic"])
    with patch.object(receiver.relay, "command", return_value=json.dumps({"boot": "fixture-boot", "sched_ext": None})):
        for name, content, expected in [
            ("abbreviated-explicit", facts, True),
            ("abbreviated-wrong-boot", facts.replace("boot=fixture-boot", "boot=unrelated"), False),
            ("abbreviated-duplicate-boot", facts + "\nboot=fixture-boot", False),
            ("abbreviated-missing-tx", facts.replace("queues/tx-0", "queues/missing"), False),
            ("abbreviated-unmarked", facts.replace("ethtool_inventory=", "missing="), False),
            ("abbreviated-wrong-scheduler", facts.replace("is not set", "changed"), False),
        ]:
            admitted = True
            try:
                receiver.abbreviated_kernel_facts(Path("/unused-fixture"), content)
            except ValueError:
                admitted = False
            if admitted != expected:
                raise ValueError(f"{name}: incorrect abbreviated guest identity admission")
            print(f"{name}: {'admit' if admitted else 'reject'}")


if __name__ == "__main__":
    check_idle()
    check_abbreviated_inventory()
    run()
