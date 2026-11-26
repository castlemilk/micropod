"""Replay host counter and bulk-client window lengths in the archived four-vCPU holdout."""
import json
from statistics import median

from gamma_contrasts import GIB, ROOT, VM, clean_client, process_delta, read_receipt, stream_rates
from gap_process_work import HASHES


ARMS = {"confirm-micropod": "micropod", "confirm-orb": "orbstack"}
METRICS = ("client_ms", "host_ms", "outside_ms", "outside_pct_of_host", "host_cpu_s_per_scored_gib")


def observation(record, pids):
    client = record["client"]
    if clean_client(client) != record["clean"] or not (client["window_s"] >= 6):
        raise ValueError("archive disagrees with the client outcome or six-second offer")
    stream_rates(client, client["window_s"], client["mib_s"])
    errors = client["errors"] or []
    if any('/id"' not in error for error in errors):
        raise ValueError("unexpected failure outside the fresh request series")
    before, after = record["before"], record["after"]
    host_ns = after["epoch_ns"] - before["epoch_ns"]
    client_ns = round(client["window_s"] * 1e9)
    if host_ns < client_ns:
        raise ValueError("host counter interval is shorter than its client bulk interval")
    for snap in (before, after):
        if sorted(task["pid"] for task in snap["tasks"]) != sorted(pids):
            raise ValueError("unexpected host process set")
    cpu = sum(process_delta(before, after, pid)["cpu_s"] for pid in pids)
    extra = host_ns - client_ns
    return dict(clean=record["clean"], fresh_failed=len(errors), reopened=client["reopened"],
                client_ms=client_ns / 1e6, host_ms=host_ns / 1e6, outside_ms=extra / 1e6,
                outside_pct_of_host=100 * extra / host_ns, host_cpu_s_per_scored_gib=cpu / (client["bytes"] / GIB))


def summarize(rows):
    return dict(attempts=len(rows), **{key: median(row[key] for row in rows) for key in METRICS})


def replay():
    source = read_receipt(VM, HASHES[VM])
    pairs = []
    last_end = 0
    for phase, count in (("grace-warmup", 3), ("grace-holdout", 16)):
        stage = source["phases"][phase]
        expected = {str(n) for n in range(1, count + 1)}
        if (len(stage["orders"]) != count or set(stage["runs"]) != set(ARMS)
                or any(set(records) != expected for records in stage["runs"].values())):
            raise ValueError("missing or additional holdout attempts")
        for n, order in enumerate(stage["orders"], 1):
            arms = order.split()
            if sorted(arms) != sorted(ARMS):
                raise ValueError("holdout pair does not contain both arms")
            pair = dict(phase=phase, pair=n, first=ARMS[arms[0]])
            for arm in arms:
                record = stage["runs"][arm][str(n)]
                if record["before"]["epoch_ns"] < last_end:
                    raise ValueError("holdout process observations overlap or differ from the recorded order")
                last_end = record["after"]["epoch_ns"]
                scope = source["scopes"][arm]
                roles = ("vmm", "relay") if arm == "confirm-micropod" else ("vmm",)
                pair[ARMS[arm]] = observation(record, [int(scope[role]) for role in roles])
            pairs.append(pair)
    scored = [p for p in pairs if p["phase"] == "grace-holdout"]
    common = [p for p in scored if all(p[a]["clean"] for a in ARMS.values())]
    by_first = {}
    for first in ARMS.values():
        subset = [p for p in common if p["first"] == first]
        by_first[first] = {a: summarize([p[a] for p in subset]) for a in ARMS.values()}
    return dict(
        source=str(VM.relative_to(ROOT)), source_sha256=HASHES[VM],
        method="The host rusage snapshots bracket the full client invocation. The pinned Go client measures "
               "bulk bytes after stream setup and before fresh-request drain and stream shutdown. Outside time "
               "is the host elapsed duration minus the reported bulk duration. CPU sums the Micropod VMM and "
               "supervisor or the OrbStack helper over the full bracket and divides by scored payload GiB.",
        limitations="The archive cannot partition outside time into setup and teardown, count unscored bytes, "
                    "or isolate CPU consumption during the bulk window. Summaries are medians of individual "
                    "attempts. Run order alternated with pair number.",
        attempts=pairs,
        clean_scored_by_arm={a: summarize([p[a] for p in scored if p[a]["clean"]]) for a in ARMS.values()},
        common_clean_pairs=[p["pair"] for p in common],
        common_clean_by_arm={a: summarize([p[a] for p in common]) for a in ARMS.values()},
        common_clean_by_first=by_first,
    )


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2, allow_nan=False))
