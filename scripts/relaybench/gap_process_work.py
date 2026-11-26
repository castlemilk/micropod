"""Replay host process work in three archived four-vCPU Micropod download series."""
import hashlib
import json
from statistics import median

from gamma_contrasts import IMAGE, ROOT, VM, clean_client, process_work, read_receipt

DIRECT = VM.with_name("gamma-direct-macvlan.json.gz")
HASHES = {
    VM: "066cd4071f3f926a228d87310f6d7b6f361c38f07c7a8240aa09a57f03f201e4",
    DIRECT: "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976",
}
METRICS = ("mean_host_cores", "wait_s_per_s", "instructions_per_byte", "cycles_per_byte",
           "instructions_per_cycle")


def sample(number, record, scope, valid_key):
    client = record["client"]
    if not record[valid_key] or not clean_client(client):
        raise ValueError(f"unexpected unqualified Micropod round {number}")
    if scope["image"] != IMAGE or int(scope["vm"].split()[0]) != 4:
        raise ValueError("unexpected image or VM CPU budget")
    if int(scope["relay"]) == int(scope["vmm"]):
        raise ValueError("relay and VMM identify the same process")
    before, after = record["before"], record["after"]
    counter_s = (after["epoch_ns"] - before["epoch_ns"]) / 1e9
    if counter_s < client["window_s"]:
        raise ValueError("process snapshots span less time than the scored bytes")
    row = dict(round=int(number), mib_s=client["mib_s"], payload_bytes=client["bytes"],
               bulk_window_s=client["window_s"], host_counter_window_s=counter_s)
    for role in ("relay", "vmm"):
        work = process_work(before, after, int(scope[role]), client["bytes"])
        if any(work[key] is None for key in METRICS):
            raise ValueError(f"incomplete archived process counters in {number}/{role}")
        row[role] = {key: work[key] for key in METRICS}
    return row


def summarize(rows):
    result = {key: median(r[key] for r in rows)
              for key in ("mib_s", "bulk_window_s", "host_counter_window_s")}
    result["rounds"] = [r["round"] for r in rows]
    for role in ("vmm", "relay"):
        result[role] = {key: median(r[role][key] for r in rows) for key in METRICS}
    return result


def cohort(records, scope, valid_key, total):
    if sorted(map(int, records)) != list(range(1, total + 1)):
        raise ValueError("missing or additional source round")
    rows = [sample(n, records[str(n)], scope, valid_key) for n in range(1, total + 1)]
    ranked = sorted(rows, key=lambda r: r["mib_s"])
    k = total // 4
    return dict(slowest_quarter=summarize(ranked[:k]), fastest_quarter=summarize(ranked[-k:]),
                all_rounds=summarize(rows), rows=rows)


def main():
    vm = read_receipt(VM, HASHES[VM])
    direct = read_receipt(DIRECT, HASHES[DIRECT])
    cases = {
        "peer_holdout_micropod": cohort(vm["phases"]["grace-holdout"]["runs"]["confirm-micropod"],
                                       vm["scopes"]["confirm-micropod"], "clean", 16)
    }
    for phase, scopes in (("confirmation", "workers"), ("kernel-holdout", "holdout_workers")):
        records = {n: row["engines"]["full-reno"] for n, row in direct["records"][phase].items()}
        cases[phase + "_full_reno"] = cohort(records, direct["records"][scopes]["full-reno"], "valid", 12)
    print(json.dumps({
        "source_sha256": {str(p.relative_to(ROOT)): h for p, h in HASHES.items()},
        "archived_host_rusage_c_sha256": hashlib.sha256(direct["sources"]["host-rusage.c"].encode()).hexdigest(),
        "method": "Within each archived four-vCPU Micropod series, rank all clean rounds by bulk MiB/s. "
                  "Take the bottom and top quarter and compute the median of each metric separately. "
                  "Keep the two older full-Reno series separate from the peer holdout. They have distinct "
                  "worker lifetimes. Use original client bytes and the VMM and supervisor PIDs in each fixture.",
        "scope": "Apple process counters cover setup and drain as well as the client byte interval. "
                 "Instructions and cycles per byte use the payload counted in that byte interval. "
                 "Mean host cores and runnable off-CPU thread-seconds per second use elapsed host counter time. "
                 "The VMM process is a host accounting boundary. These figures cannot attribute work to individual "
                 "vCPU threads, identify a guest kernel function, or separate host scheduling from offered CPU demand. "
                 "Ranking by observed throughput makes these comparisons descriptive. The peer holdout contributes "
                 "all 16 clean Micropod attempts, including the round in which the OrbStack peer had a fresh failure.",
        "series": cases,
    }, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
