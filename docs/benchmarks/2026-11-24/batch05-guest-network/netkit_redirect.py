"""Run pinned Linux forwarding branches over fixed frames and compare with the source-TX qualifier."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

DIR = Path(__file__).resolve().parent
ROOT = DIR.parents[3]
sys.path.insert(0, str(ROOT / "scripts/relaybench"))
from guest_link_path import check

REVISION = "7d9b565173a901cb18942e00384838da96e0ba98"
MEMBERS = {
    "net/core/filter.c": ("ff0d9a21d2e0513a1797bcbd66002acde76b4797e544fb53a84ee74cf0ea2c73", "int skb_do_redirect("),
    "drivers/net/netkit.c": ("cd7425f0d282bb02838491c474b6fe241a1966f4f9317bc4a043fa7772dd3f0e", "static netdev_tx_t netkit_xmit("),
}


def linux_function(path, expected, signature):
    data = path.read_bytes()
    assert hashlib.sha256(data).hexdigest() == expected
    source = data.decode()
    start = source.index(signature)
    return source[start:source.index("\n}", start) + 2] + "\n"


def snapshot(at, tx):
    return {"boot_id": "f206787c-7083-4b5d-8a2c-319200000005", "netns": "net:[100]",
            "monotonic_ns": at, "links": [{"ifname": "nk", "ifindex": 7, "address": "02:00:00:00:00:01",
            "linkinfo": {"info_kind": "netkit", "info_data": {"mode": "l2"}},
            "stats64": {"tx": {"bytes": tx}, "rx": {"bytes": 0}}}]}


def run(kernel_tree):
    verifier = ROOT / "scripts/relaybench/guest_link_path.py"
    assert hashlib.sha256(verifier.read_bytes()).hexdigest() == "0f7269230ce164bc4b33f60eb2c93f808c1f6be8189418a0b7bb130192366843"
    with tempfile.TemporaryDirectory() as scratch:
        wd = Path(scratch)
        chunks = [linux_function(kernel_tree / name, sha, sig) for name, (sha, sig) in MEMBERS.items()]
        (wd / "kernel_functions.inc").write_text("\n".join(chunks))
        subprocess.run(["cc", "-std=c11", "-Wall", "-Werror", "-I", str(wd),
                        str(DIR / "netkit_fixture.c"), "-o", str(wd / "replay")], check=True)
        output = subprocess.check_output([wd / "replay"], text=True)
    # Same independent synthetic client in both arms. Its delivery must never be
    # attributed to the frame train by the shared byte total.
    payload = 32 * 1460
    client = {"streams": 32, "arrivals": 240, "period_us": 25000, "window_s": 6, "bytes": payload,
              "per_stream_bytes": [1460] * 32, "mib_s": payload / (1024**2 * 6),
              "errors": [], "reopened": 0, "fresh_p95_us": 500, "fresh_p99_us": 500}
    attempts = []
    for line in output.splitlines():
        present, success, tx, drops, delivered, freed = map(int, line.split())
        capture = {"before": snapshot(0, 0), "after": snapshot(6_000_000_000, tx), "client": client}
        coverage = check(capture, "nk", "netkit", "tx", "l2")
        attempts.append({"redirect_ifindex_present": bool(present), "submitted_frames": 32,
                         "netdev_tx_success_returns": success, "source_tx_bytes": tx,
                         "source_tx_drop_increment": drops, "destination_stub_received_frames": delivered,
                         "kernel_called_free_frames": freed, "current_source_tx_qualifier": coverage})
    assert len(attempts) == 2
    assert [(a["netdev_tx_success_returns"], a["source_tx_bytes"], a["source_tx_drop_increment"],
             a["destination_stub_received_frames"], a["kernel_called_free_frames"]) for a in attempts] == [
        (32, 48448, 0, 32, 0), (32, 48448, 0, 0, 32)]
    return {"stable_id": "233.03", "date_local": "2026-11-24", "source_revision": REVISION,
            "evidence_tier": "source/fixture", "kernel_version": "7.3.5",
            "kernel_archive_sha256": "8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990",
            "kernel_members": {p: sha for p, (sha, _) in MEMBERS.items()},
            "functions_compiled_unmodified": ["skb_do_redirect", "netkit_xmit"],
            "client_fixture": "Identical independent synthetic complete-client receipt in both arms, 32 x 1460 B",
            "workload": "32 x 1514 byte fixed L2 frames, egress peer redirect to ifindex 17",
            "changed_variable": "whether the target ifindex resolves in the simulated namespace",
            "first_attempts": attempts,
            "limitations": "One deterministic pair, userspace device table and endpoint shim. No live kernel, network, throughput, measured latency or statistical interval."}


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("kernel_tree", type=Path)
    print(json.dumps(run(p.parse_args().kernel_tree), indent=2))
