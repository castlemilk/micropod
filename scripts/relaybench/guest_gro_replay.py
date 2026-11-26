"""Compare archived flush timeouts at fixed IRQ deferral and TCP controller."""
import itertools
import json
from statistics import median

from gamma_contrasts import (GIB, IMAGE, ROOT, clean_client, paired_median_interval,
                             process_delta, read_receipt)

ARCHIVE = ROOT / "docs/benchmarks/2026-11-21/gamma-vm-scheduling.json.gz"
SHA256 = "29f33979ca570117e54addabfe07aecb452ab23af7f0b9e039c996dbb9611e51"
TIMEOUTS = (20, 50, 100)


def replay():
    source = read_receipt(ARCHIVE, SHA256)
    rows = []
    scopes = source["scopes"]
    for timeout in TIMEOUTS:
        name = f"lab-{timeout}"
        scope = scopes[name]
        if (scope["boot-policy"].splitlines()[:2] != ["2", str(timeout * 1000)]
                or scope["image"] != IMAGE or scope["vm"] != scopes["lab-20"]["vm"]):
            raise ValueError(f"mismatched boot policy, image or VM for {name}")
        for cc in ("reno", "cubic"):
            proof = scope["controller_proofs"][cc]
            if proof["accepted_socket"] != cc or proof["route"]["Congctl"] != cc:
                raise ValueError(f"controller mismatch for {name}/{cc}")
            arm = f"{name}_{cc}"
            for block, data in source["records"]["guest-screen"].items():
                raw = data["engines"][arm]
                client = raw["client"]
                clean = clean_client(client)
                if clean != raw["valid"]:
                    raise ValueError(f"archive scoring mismatch for {block}/{arm}")
                row = dict(block=int(block), controller=cc, timeout_us=timeout, clean=clean,
                           offered=client["arrivals"], errors=len(client["errors"] or []),
                           bulk_reopens=client["reopened"])
                if clean:
                    gib = client["bytes"] / GIB
                    counters = [process_delta(raw["before"], raw["after"], task["pid"])
                                for task in raw["before"]["tasks"]]
                    row.update(mib_s=client["mib_s"], p95_ms=client["fresh_p95_us"] / 1000,
                               p99_ms=client["fresh_p99_us"] / 1000,
                               irq_per_gib=(raw["irqafter"]["irq"] - raw["irqbefore"]["irq"]) / gib,
                               host_cpu_s_per_gib=sum(d["cpu_s"] for d in counters) / gib,
                               host_wait_s_per_s=sum(d["wait_s"] / d["sample_seconds"] for d in counters))
                rows.append(row)

    comparisons = []
    for cc in ("reno", "cubic"):
        for first, second in itertools.combinations(TIMEOUTS, 2):
            controls, trials = ({r["block"]: r for r in rows if r["clean"] and
                                 r["controller"] == cc and r["timeout_us"] == t} for t in (first, second))
            common = sorted(controls.keys() & trials.keys())
            ratios = [trials[k]["mib_s"] / controls[k]["mib_s"] for k in common]
            metrics = ("p95_ms", "p99_ms", "irq_per_gib", "host_cpu_s_per_gib", "host_wait_s_per_s")
            deltas = {m: median(trials[k][m] - controls[k][m] for k in common) for m in metrics}
            comparisons.append(dict(controller=cc, control_us=first, candidate_us=second,
                                    clean_blocks=common, wins=sum(r > 1 for r in ratios),
                                    throughput_ratio=median(ratios), descriptive_ci95=paired_median_interval(ratios),
                                    median_paired_delta=deltas))
    return dict(archive=ARCHIVE.name, sha256=SHA256, deferred_polls=2,
                scope="Archived guest screen. Different warm VM per timeout. Host CPU and wait cover both "
                      "observed processes over the full client attempt. IRQ counters bracket the attempt.",
                attempts=rows, comparisons=comparisons)


if __name__ == "__main__":
    print(json.dumps(replay(), indent=2, allow_nan=False))
