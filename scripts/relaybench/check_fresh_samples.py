"""Exercise stock and paired read-size clients against the same virtual-time HTTP transport."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import fresh_samples
from build_host_role_tools import build
from gamma_contrasts import ROOT

HERE = Path(__file__).resolve().parent


def virtual_attempt(source, test, output):
    env = dict(os.environ, GO111MODULE="off", GOPROXY="off", GOWORK="off", GOTOOLCHAIN="local",
               MP_FRESH_RECEIPT=str(output))
    subprocess.run(["go", "test", "-p", "2", "-count=1", source, test], env=env,
                   check=True, stdout=subprocess.DEVNULL)
    return json.loads(output.read_text())


def identical_summaries(align):
    rows = []
    for i in range(240):
        finish = 90_000_000 if i < 20 else 60_000_000
        delayed = i < 20 if align else 20 <= i < 40
        launch = 50_000_000 if delayed else 0
        rows.append(dict(ordinal=i, scheduled_ns=i * 25_000_000, launch_delay_ns=launch,
                         completion_delay_ns=finish, ok=True))
    return dict(fresh_samples=rows, arrivals=240, period_us=25000, window_s=6, begin_ns=1, end_ns=6_000_000_001,
                fresh_p50_us=60000, fresh_p95_us=90000, fresh_p99_us=90000, dispatch_p95_us=50000,
                dispatch_max_us=50000)


def check():
    with tempfile.TemporaryDirectory() as directory:
        temp = Path(directory).resolve()
        builds = {}
        attempts = {}
        source = ROOT / "scripts/netbench/offered/main.go"
        for name in ("control", "paired"):
            builds[name] = build(temp / (name + "-tools"), paired_fresh=name == "paired")
            work = temp / name
            work.mkdir()
            main = work / "main.go"
            if name == "paired":
                subprocess.run(["patch", "-s", "-F", "0", "-o", main, source, HERE / "fresh_samples.patch"], check=True)
            else:
                shutil.copyfile(source, main)
            test = work / "fixture_test.go"
            shutil.copyfile(HERE / "fresh_samples_test.go.in", test)
            attempts[name] = virtual_attempt(main, test, work / "result.json")
    control, paired = attempts["control"], attempts["paired"]
    if any(paired[k] != v for k, v in control.items()):
        raise ValueError("original scored fields differ across virtual-time arms")
    summary = fresh_samples.summarize(paired)
    failures = [r for r in paired["fresh_samples"] if not r["ok"]]
    if (len(failures) != 1 or failures[0]["ordinal"] != 237 or failures[0]["completion_delay_ns"] != 150_000_000
            or paired["fresh_samples"][239]["completion_delay_ns"] != 250_000_000):
        raise ValueError("lost failed or drained first attempt")
    bad = copy.deepcopy(paired)
    bad["fresh_samples"][238]["ordinal"] = 237
    try:
        fresh_samples.summarize(bad)
    except ValueError as exc:
        rejected = str(exc)
    else:
        raise ValueError("duplicate arrival identity accepted")
    examples = {name: fresh_samples.summarize(identical_summaries(aligned)) for name, aligned in
                (("long_launches_on_long_responses", True), ("long_launches_on_short_responses", False))}
    return dict(date="2026-11-24", direction="230.15", tier="source/fixture",
                base="a3b561c6a97320d4ca9aff60885ae6393ccaa613", builds=builds,
                go=subprocess.check_output(["go", "version"], text=True).strip(),
                source_sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in
                               (source, HERE / "fresh_samples.patch", HERE / "fresh_samples_test.go.in",
                                HERE / "fresh_samples.py", Path(__file__))},
                changed_variable="Stock percentile-only encoding versus preserving ordinal-paired request observations.",
                workload="32 stock bulk readers, 240 offers every 25 ms, virtual clock and in-process HTTP transport. "
                         "One failed identity at ordinal 237, one successful response delayed past the scoring window. "
                         "Two additional deterministic 240-arrival schedules have identical original marginals.",
                qualification=dict(paired=summary, duplicate_rejection=rejected, identical_marginal_examples=examples),
                raw_first_attempts=attempts,
                limits="Times are virtual. The diagnostic labels client launch versus completion and retains errors. "
                       "The full path after launch includes HTTP, network and service time. Its real overhead is unknown. "
                       "The ordinary tools and official scheduled-time latency thresholds stay the control.")


if __name__ == "__main__":
    print(json.dumps(check(), indent=2, allow_nan=False))
