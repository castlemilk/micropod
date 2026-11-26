"""Replay the Gamma disposable-fixture peer holdout from its original per-client records."""

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE = HERE.parent / "disposable-local-fixture"
sys.path[:0] = [str(FIXTURE), str(HERE.parents[3] / "scripts/relaybench")]
import peer_verdict
import receiver

relay = receiver.relay
require = relay.require
SEED = 34203
WAIT = 180
CANDIDATE = "a13c1ef78ba4eae11172972a6d7b73662aeafccb266472d5b22c59d67bc986e8"
CLIENT = relay.host_role.CLIENT_SHA256
SELECTION = FIXTURE / "20261124T100757Z-local-zw8k9wvr/receiver/fixtures.json"


def load(path):
    return json.loads(path.read_bytes())


def verify_arms(arms, *, candidate_sha=CANDIDATE, source_revision=relay.STOCK_RELAY_REV,
                workers=2, callback_events=128, read_bytes=262144, process_type="Standard", kernel_sha=relay.STOCK_KERNEL):
    selected = load(SELECTION)["A"]
    a, b = arms["A"], arms["B"]
    require(process_type in relay.host_role.SPAWN_TYPES, "invalid launch role")
    for key in (
        "cli_sha256",
        "cpus",
        "relay_workers",
        "process_type",
        "spawn_type",
        "kernel_image_sha256",
        "read_bytes",
        "callback_events",
        "route",
        "image_config",
        "release",
        "service_env_sha256",
    ):
        expected = {"cli_sha256": candidate_sha, "relay_workers": workers, "callback_events": callback_events,
                    "read_bytes": read_bytes, "process_type": process_type, "kernel_image_sha256": kernel_sha,
                    "spawn_type": relay.host_role.SPAWN_TYPES[process_type]}.get(key, selected[key])
        require(a[key] == expected, f"selected Micropod control changed: {key}")
    require(
        a["process_type"] == process_type
        and a["cli_sha256"] == candidate_sha
        and a["relay_workers"] == workers
        and a["callback_events"] == callback_events
        and a["read_bytes"] == read_bytes
        and a["route"] == relay.DIRECT_ROUTE
        and a["kernel_image_sha256"] == kernel_sha,
        "wrong Micropod configuration",
    )
    mapped = a["mapped_relay_build"]
    require(
        mapped["mapped_inode"] > 0
        and mapped["worker_executable_sha256"] == candidate_sha
        and mapped["source_revision"] == source_revision,
        "unverified running Micropod executable",
    )
    for arm in (a, b):
        require(
            arm["cpus"] == 4
            and 3.7 * 2**30 < arm["memory_bytes"] <= 4 * 2**30
            and arm["cpuset"] == "0-3"
            and arm["service_limits"] == peer_verdict.LIMITS
            and arm["image_config"] == relay.IMAGE,
            "unmatched VM, service resources or image",
        )
    require(
        all(a[k] and b[k] and a[k] != b[k] for k in ("engine", "id", "address", "name", "scope")),
        "product endpoints share identity",
    )


def checked_environment(folder, action):
    arms = load(folder / "fixtures-before.json")
    require(arms == load(folder / "fixtures-after.json"), "fixture identity changed")
    verify_arms(arms)
    status = load(folder / "status.json")
    require(
        status.get("action") == action and status.get("complete") is True and not status.get("error"),
        "incomplete scored run",
    )
    cleanup = load(folder / "cleanup.json")
    orb_cleanup = load(folder / "orbstack-cleanup.json")
    require(
        not cleanup["retained"]
        and not cleanup["errors"]
        and orb_cleanup["removed"]
        and orb_cleanup["id"] == arms["B"]["id"],
        "incomplete teardown",
    )

    # The foreground guard brackets each attempt; the background monitor covers workload and disk in between.
    limits = [json.loads(line) for line in (folder / "disk.jsonl").read_text().splitlines()]
    require(
        limits
        and all(not r["below_floor"] and min(r["available_bytes"].values()) >= 12 * 2**30 for r in limits),
        "effective free disk fell below the floor",
    )
    obs = [json.loads(line) for line in (folder / "admission.jsonl").read_text().splitlines()]
    require(obs and all(not r["blockers"] for r in obs), "another timed client or CI job was present")
    orb = [json.loads(line) for line in (folder / "orb-activity.jsonl").read_text().splitlines()]
    require(
        orb and all(set(r["running_ids"]) <= {arms["B"]["id"]} for r in orb),
        "other active OrbStack container",
    )
    return arms


def first_attempt(folder, arms, phase, number, arm):
    r = load(folder / f"{phase}-{number}-{arm}.json")
    require(
        (r["phase"], r["pair"], r["arm"]) == (phase, number, arm)
        and "error" not in r
        and type(r["exit_code"]) is int
        and r["fixed_sha256"] == CLIENT,
        "missing or interrupted first attempt",
    )
    client = relay.single_port_client(arms[arm], r)
    start, end = r["client_spawn_start_ns"], r["client_reaped_ns"]
    require(
        r["guard_before_ns"]
        <= r["before"]["epoch_ns"]
        <= start
        < end
        <= r["after"]["epoch_ns"]
        <= r["guard_after_ns"]
        and 0 < client["window_s"] <= (end - start) / 1e9,
        "counter/guard window does not bracket client",
    )
    require(
        all(type(client[f"fresh_p{q}_us"]) is int and client[f"fresh_p{q}_us"] > 0 for q in (50, 95, 99)),
        "missing latency percentiles",
    )
    return dict(r, client=client)


def score(folder):
    plan = load(folder / "plan.json")
    orders = relay.plan(SEED, 16)
    require(
        plan["order"] == orders
        and plan["seed"] == SEED
        and plan["candidate"] == CANDIDATE
        and plan["tools"] == dict(relay.HASHES, fixed=CLIENT)
        and plan["idle_wait_seconds"] == WAIT
        and plan["selected_from_sha256"] == relay.digest(SELECTION),
        "holdout plan changed",
    )
    arms = checked_environment(folder, "run")

    def row(phase, number, arm):
        r = first_attempt(folder, arms, phase, number, arm)
        samples = r["idle_observations"]
        require(
            r["idle_gate_passed"]
            and len(samples) >= 2
            and all(
                s["eligible"]
                and 90 <= s["idle_pct"] <= 100
                and (s["paired_idle_gap_pp"] is None or s["paired_idle_gap_pp"] <= 5)
                for s in samples[-2:]
            )
            and samples[-1]["elapsed_seconds"] <= WAIT
            and r["idle_pct"] == samples[-1]["idle_pct"],
            "window failed idle admission",
        )
        order = orders[phase][number - 1]
        if arm == order[1]:
            previous = load(folder / f"{phase}-{number}-{order[0]}.json")["idle_pct"]
            require(
                all(abs(s["idle_pct"] - previous) <= 5 for s in samples[-2:]), "paired host load differed"
            )
        return r

    result = peer_verdict.assess(orders, {k: v["pids"] for k, v in arms.items()}, row, full_body_counts=True)
    return dict(
        study="Gamma local disposable peer holdout", source=str(folder), candidate=CANDIDATE, **result
    )


if __name__ == "__main__":
    print(json.dumps(score(Path(sys.argv[1]).resolve()), indent=2, allow_nan=False))
