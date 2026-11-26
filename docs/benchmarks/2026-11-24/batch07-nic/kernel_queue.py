"""Compile pinned Linux RX/TX policy functions and record the fixed-work arm results."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SOURCE = {
    "dev": ("net/core/dev.c", "8b3c43e8becfd552ead597c2e009edf16b126924a7cbe4c5c961e74563b76274"),
    "virtio": ("drivers/net/virtio_net.c", "d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace"),
    "netdevice": ("include/linux/netdevice.h", "c01410d782e5c984ee118c5f6a041fb7cc91ce5c1ee06493de92d44670fd5907"),
    "dql": ("include/linux/dynamic_queue_limits.h", "411f7ee98f224fb23186dcfed7f8d20a72aa63cb7b30186941a14eb8d44b02d9")
}
FUNCTIONS = {
    "deferred_irq": [("dev", "bool napi_complete_done"), ("dev", "static enum hrtimer_restart napi_watchdog"),
                     ("virtio", "static bool virtqueue_napi_complete")],
    "tx_bql": [("dql", "static inline void dql_queued"), ("dql", "static inline int dql_avail"),
               ("netdevice", "static inline void netdev_tx_sent_queue"),
               ("netdevice", "static inline bool __netdev_tx_sent_queue"),
               ("virtio", "static bool tx_may_stop"), ("virtio", "static void check_sq_full_and_disable"),
               ("virtio", "static netdev_tx_t start_xmit")]
}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def compile_run(root, mode):
    parts, members = [], {}
    for key, signature in FUNCTIONS[mode]:
        member, expected = SOURCE[key]
        data = (root / member).read_bytes()
        if sha(data) != expected:
            raise ValueError(f"Linux source mismatch in {member}")
        members[member] = expected
        start = data.index(b"\n" + signature.encode() + b"(") + 1
        end = data.index(b"\n}\n", start) + 3
        parts.append(data[start:end])
    fragment = b"\n".join(parts)
    harness = HERE / f"{mode}.c"
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        (work / "linux_functions.inc").write_bytes(fragment)
        binary = work / "fixture"
        subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                        "-I", str(work), str(harness), "-o", str(binary)], check=True)
        lines = subprocess.check_output([binary], text=True).splitlines()
    return lines, dict(kernel_members=members, compiled_fragment_sha256=sha(fragment),
                       harness_sha256=sha(harness.read_bytes()), script_sha256=sha(Path(__file__).read_bytes()),
                       compiler=subprocess.check_output(["cc", "--version"], text=True).splitlines()[0])


def run(root, mode):
    lines, source = compile_run(root, mode)
    rows = []
    if mode == "deferred_irq":
        for line in lines:
            name, *nums = line.split()
            defer, count, interrupts, timers, empty, *waits = map(int, nums)
            assert len(waits) == count == 32 and all(delay >= 0 for delay in waits)
            rows.append(dict(arrival_train=name, defer_polls=defer, delivered_descriptors=count,
                             modeled_device_interrupts=interrupts, modeled_timer_polls=timers, empty_polls=empty,
                             enqueue_to_model_rx_ns=waits))
        assert len(rows) == len({(r["arrival_train"],r["defer_polls"]) for r in rows}) == 14
        setup = ("Seven fixed arrival trains of 32 descriptors, no GRO payload held, no processing time, "
                 "under-budget RX polls, no concurrent/missed events, 20,000 ns exact logical timer. "
                 "A masked device holds arrivals until a timer poll, and an interrupt-driven poll runs immediately.")
        direction = "231.03"
    else:
        names = ("skb_bytes", "tx_napi_weight", "submitted_skbs", "submitted_bytes", "dql_queued_bytes",
                 "fixed_bql_limit_bytes", "bql_stack_stopped", "ring_stops")
        for line in lines:
            rows.append(dict(zip(names, map(int, line.split()), strict=True)))
        assert len(rows) == len({(r["skb_bytes"],r["tx_napi_weight"]) for r in rows}) == 8
        setup = ("32 fixed-size SKBs offered to one 256-entry ring, one descriptor per SKB, no completions, "
                 "CONFIG_BQL enabled, MAX_SKB_FRAGS=17, one kick requested per submission, "
                 "fixed initial BQL allowance of 524288 B. Stop before next admission if the stack or driver queue stops.")
        direction = "231.08"
    return dict(direction=direction, date="2026-11-24", tier="source/fixture",
                micropod_revision="a60d203b16b24abd857e1b5c9e817636b241f850", linux="7.3.5",
                linux_tar_sha256="8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990",
                **source, fixture=setup, observations=rows)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("linux_tree", type=Path)
    parser.add_argument("fixture", choices=FUNCTIONS)
    args = parser.parse_args()
    print(json.dumps(run(args.linux_tree, args.fixture), indent=2))
