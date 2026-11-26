"""Join verified guest driver snapshots to receiver payload on the same Micropod trial."""
import json
import math
import re
from email.utils import parsedate_to_datetime
from statistics import median

from gamma_contrasts import GIB, MIB, VM, read_receipt
from tx_offload_bql_replay import BENCH, SUPPLEMENT, VCPU, replay


def snapshot(text):
    if "driver: virtio_net" not in text.splitlines() or "Ring parameters for eth1:" not in text.splitlines():
        raise ValueError("guest snapshot is not the eth1 Virtio driver")
    queues = re.findall(r"^\s*tx(\d+)_kicks: (\d+)$", text, re.M)
    total = re.search(r"^\s*tx_kicks: (\d+)$", text, re.M)
    if len(queues) != 1 or queues[0][0] != "0" or not total or queues[0][1] != total[1]:
        raise ValueError("the single TX queue does not account for the interface kicks")
    stamp = parsedate_to_datetime(text.splitlines()[0])
    return int(stamp.timestamp()), int(total[1])


def report():
    evidence = replay("nic")
    trials = read_receipt(VM, VCPU)["phases"]["nic-trials"]["runs"]
    snapshots = read_receipt(BENCH / "2026-11-24/tx-offload-bql-readbacks.json.gz", SUPPLEMENT)["nic"]
    rows = []
    for row in evidence["rows"]:
        trial = trials[row["arm"]][str(row["block"])]
        client = trial["client"]
        delivered, seconds = client["bytes"], client["window_s"]
        if trial["before"]["epoch_ns"] != row["epoch_ns"] or not math.isclose(
            delivered / MIB / seconds, row["throughput_mib_s"]
        ):
            raise ValueError("receiver window and driver replay disagree")
        tx = row["tx_interface"]
        arm, block = row["arm"], row["block"]
        before = f"set-{arm}" if block == 1 else f"{arm}{block - 1}"
        pre_sec, pre_kicks = snapshot(snapshots[before])
        post_sec, post_kicks = snapshot(snapshots[f"{arm}{block}"])
        host_pre, host_post = (trial[k]["epoch_ns"] // 1_000_000_000 for k in ("before", "after"))
        aligned = pre_sec == host_pre and post_sec == host_post
        if post_kicks - pre_kicks != tx["tx0_kicks"] or (row["clean"] and not aligned):
            raise ValueError("guest totals or clean-trial boundary timestamps disagree")
        rows.append(dict(
            arm=row["arm"], attempt=row["block"], clean=row["clean"],
            receiver_bytes=delivered, bulk_window_s=seconds, receiver_mib_s=row["throughput_mib_s"],
            interface_bytes=tx["bytes"], interface_packets=tx["packets"], tx_kicks=tx["tx0_kicks"],
            kicks_per_delivered_gib=tx["tx0_kicks"] / (delivered / GIB) if aligned else None,
            kicks_per_interface_gib=row["tx_kicks_per_interface_gib"],
            boundary_seconds=dict(driver_pre=pre_sec, host_pre=host_pre, driver_post=post_sec, host_post=host_post),
            same_boundary_seconds=aligned,
            p95_ms=row["p95_ms"], p99_ms=row["p99_ms"], fresh_errors=row["fresh_errors"],
            bulk_errors=row["bulk_errors"], bulk_reopens=row["bulk_reopens"],
            host_cpu_s_per_delivered_gib={name: work["cpu_s_per_scored_gib"]
                                          for name, work in row["process"].items()},
        ))
    summaries = {}
    for arm, counts in evidence["summary"].items():
        clean = [r for r in rows if r["arm"] == arm and r["clean"]]
        summaries[arm] = dict(attempts=counts["attempts"], clean=len(clean),
                              clean_medians={field: median(r[field] for r in clean) for field in
                                             ("kicks_per_delivered_gib", "kicks_per_interface_gib",
                                              "receiver_mib_s", "p95_ms", "p99_ms")})
    return dict(archive_sha256=evidence["archive_sha256"], driver_snapshots_sha256=evidence["readbacks_sha256"],
                boot=evidence["boot"], image=evidence["image"], client=evidence["client"],
                workload=evidence["workload"], order=evidence["comparison"],
                counter_scope="On each clean attempt the driver and host boundaries match to the guest "
                              "clock's one-second resolution. Counts include work outside the six-second bulk "
                              "window. Withhold the normalized result if the boundary seconds differ. "
                              "A driver kick does not identify a host VM exit or its cost.",
                summary=summaries, rows=rows)


if __name__ == "__main__":
    print(json.dumps(report(), indent=2, allow_nan=False))
