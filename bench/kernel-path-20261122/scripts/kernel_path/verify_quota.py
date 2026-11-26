#!/usr/bin/env python3
"""Offline eligibility check for the optional bpfland comparison."""

import argparse
import json
import re
from pathlib import Path, PurePosixPath

SOURCE = "e7b3a219617472cf78880ac424714e52c932db61"


def need(ok, message):
    if not ok:
        raise ValueError(message)


def verify(root, current=False):
    def read(name):
        return json.loads((root / name).read_text())

    build = read("policy-build.json")
    need(
        build["program"] == "scx_bpfland"
        and build["source_revision"] == SOURCE
        and re.fullmatch("[0-9a-f]{64}", build["executable_sha256"]),
        "wrong policy build",
    )
    need(
        build["executable_sha256"] == (root / "active/executable.sha256").read_text().split()[0],
        "loaded scheduler executable differs",
    )
    boot = None
    states = {}
    rates = {}
    phases = ["before", "active", "fallback"] + (["current-a", "current-b"] if current else [])
    boots = {}
    for phase in phases:
        q = read(phase + "/quota.json")
        left = read(phase + "/kernel-before.json")
        right = read(phase + "/kernel-after.json")
        if boot is None:
            boot = left["boot"]
        need(
            left["boot"]
            and left["boot"] == right["boot"]
            and (phase == "current-a" or boot == left["boot"])
            and left["sched_ext"] == right["sched_ext"],
            "boot or policy changed during probe",
        )
        state = left["sched_ext"]
        states[phase] = state
        boots[phase] = left["boot"]
        enabled = phase in ("active", "current-b")
        target = build["ops"] if enabled else "fair"
        need(
            state["state"] == ("enabled" if enabled else "disabled")
            and (not enabled or state["ops"] == target),
            "wrong scheduler in guest",
        )
        need(q["scheduler"] == target and q["pass"] is True and len(q["rounds"]) == 3, "missing quota rounds")
        layout = q["cgroup_layout"]
        paths = [PurePosixPath(x) for x in layout["paths"]]
        need(
            layout["pass"] is True
            and len(paths) == 2
            and paths[0] != paths[1]
            and paths[0].is_absolute()
            and paths[0].parent == paths[1].parent == PurePosixPath(layout["common_parent"]),
            "sibling cgroup layout",
        )
        rates[phase] = []
        for row, quota in zip(q["rounds"], (200000, 50000, 200000)):
            elapsed = float(row["end_s"]) - float(row["start_s"])
            need(elapsed >= 4.9, "incomplete elapsed interval")
            rate = (int(row["end_usec"]) - int(row["start_usec"])) / 1e6 / elapsed
            need(
                row["pass"]
                and row["cpu_max"] == f"{quota} 100000"
                and row["memory_max"] == str(1 << 30)
                and row["pids_max"] == "512"
                and row["state"] == state["state"]
                and int(row["sequence"]) == state["enable_seq"],
                "job limits or policy identity changed",
            )
            need(
                (row["ops"] == target and row["task_sched_ext"] == ["1", "1"])
                if enabled
                else "1" not in row["task_sched_ext"],
                "spinner scheduler membership differs",
            )
            need(rate >= 1.25 if quota == 200000 else 0.40 <= rate <= 0.60, "measured CPU bandwidth failed")
            rates[phase].append(rate)
    need(
        states["active"]["enable_seq"] > states["before"]["enable_seq"]
        and states["fallback"]["enable_seq"] >= states["active"]["enable_seq"],
        "missing attach/fallback transition",
    )
    if current:
        need(
            boots["current-a"] != boots["current-b"]
            and states["current-b"]["enable_seq"] > states["fallback"]["enable_seq"]
            and (root / "current-b/executable.sha256").read_text().split()[0] == build["executable_sha256"],
            "fresh quota or loaded executable missing after reattachment",
        )
    return dict(
        boots=boots,
        eligible_for_separate_timing=True,
        boot=boot,
        program=build["program"],
        source=SOURCE,
        states=states,
        cpu_seconds_per_second=rates,
    )


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("receipt_directory", type=Path)
    args = ap.parse_args()
    try:
        print(json.dumps(verify(args.receipt_directory), indent=2))
    except (ValueError, KeyError, OSError, TypeError) as e:
        ap.exit(1, f"Ineligible: {e}\n")
