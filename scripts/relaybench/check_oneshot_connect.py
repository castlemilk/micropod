"""Measure the opt-in one-shot guest connect watch against the stock Micropod relay."""
import hashlib
import json
import platform
import random
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from statistics import median

from check_handshake_reads import FLAGS, HERE, RELAY, ROOT, compile_arm, run

ARMS = ("stock", "oneshot")


def checked_run(exe, arm, mode, deferred=False, batched=False):
    rows = run(exe, mode)
    flows = 512 if mode == "measure" else 1
    for r in rows:
        if r["async"]:
            filters = (4 if deferred else 6) - int(arm == "oneshot")
            calls = (2 if deferred else 4) if batched and mode != "qualify-split" else filters
        else:
            calls = filters = 2 if deferred else 3
        if (r["flows"] != flows or r["setup_change_syscalls"] != flows * calls
                or r["setup_filters"] != flows * filters or not 0 < r["setup_cpu_ns"] <= r["relay_cpu_ns"]):
            raise ValueError(f"{arm} {mode} unexpected filter or CPU result: {r}")
    return rows


def cpu_results(pairs):
    summary = {}
    for index, path in enumerate(("immediate", "async")):
        summary[path] = {}
        for field in ("setup_cpu_ns", "relay_cpu_ns"):
            ns = {arm: [p[arm][index][field] / p[arm][index]["flows"] for p in pairs] for arm in ARMS}
            differences = [100 * (b / a - 1) for a, b in zip(ns["stock"], ns["oneshot"])]
            summary[path][field] = dict(median_ns_per_flow={arm: median(ns[arm]) for arm in ARMS},
                                        paired_median_percent=median(differences),
                                        oneshot_lower_pairs=sum(d < 0 for d in differences))
    return summary


def main():
    qualifications, pairs = [], []
    with tempfile.TemporaryDirectory(prefix="mp-oneshot-") as work:
        folder = Path(work)
        for arm in ARMS:
            for deferred in (False, True):
                for batched in (False, True):
                    exe = folder / "qualified"
                    compile_arm(exe, deferred, batched, sanitize=True, oneshot=arm == "oneshot")
                    for mode in ("qualify", "qualify-split"):
                        rows = checked_run(exe, arm, mode, deferred, batched)
                        qualifications.append(dict(arm=arm, owner=mode, deferred=deferred, batched=batched, rows=rows))
        binaries = {arm: folder / arm for arm in ARMS}
        for arm, exe in binaries.items():
            compile_arm(exe, False, False, oneshot=arm == "oneshot")
            checked_run(exe, arm, "measure")
        binary_sha = {arm: hashlib.sha256(exe.read_bytes()).hexdigest() for arm, exe in binaries.items()}
        orders = [ARMS, ARMS[::-1]] * 6
        random.Random(20261124).shuffle(orders)
        for order in orders:
            pairs.append(dict(order=order, **{arm: checked_run(binaries[arm], arm, "measure") for arm in order}))
    sources = [RELAY / "PublishedTCP.c", RELAY / "include/PublishedTCP.h", HERE / "handshake_reads.c",
               HERE / "check_handshake_reads.py", Path(__file__).resolve()]
    print(json.dumps(dict(
        completed_utc=datetime.now(timezone.utc).isoformat(), host=platform.machine(), darwin=platform.release(),
        compiler=subprocess.check_output(["clang", "--version"], text=True).splitlines()[0], flags=FLAGS,
        measured_defines=dict(MICROPOD_BENCH_ONESHOT_CONNECT=dict(stock=0, oneshot=1),
                             MICROPOD_BENCH_DEFER_HANDSHAKE_READS=0, MICROPOD_BATCH_STREAM_FILTERS=0),
        binary_sha256=binary_sha, source_sha256={str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest()
                                               for f in sources},
        scope="Darwin anonymous streams, real kqueue and relay. Guest connect outcome and TCP-only options "
              "are substituted. One warmup per arm, 12 balanced randomized pairs. Each arm verifies 512 "
              "immediate and 512 asynchronous connections per pair, 98 request and 148 response bytes per flow. "
              "Thread CPU covers adoption and the first drain, then the response and close drains for lifecycle. "
              "Setup counter counts filter-change syscalls. The fixture does not measure guest TCP timing.",
        qualification="ASan and UBSan, both owner types, both batch settings, both read-registration settings. "
                      "Exercises retry, revocation, failed registration, both directions under backpressure, "
                      "idle wakeup after the handshake, ordered delivery and FIN.",
        qualifications=qualifications, pairs=pairs, summary=cpu_results(pairs),
    ), indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
