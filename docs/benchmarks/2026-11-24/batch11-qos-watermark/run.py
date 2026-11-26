import argparse
import gzip
import hashlib
import json
import math
import os
import random
import statistics
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
LIB = ROOT/"scripts/relaybench"
BASE = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
ARCHIVE = ROOT/"docs/benchmarks/2026-11-21/gamma-mixed-scheduler.json.gz"
HASH = "9e3b184de862aafacff47312878441e940d030e8cfc8342c0e479d064f4724c8"
HEADER_COMMIT = "816121afd30fba52bda7828418cd963d4216166b"
SEED = 23006

def digest(v):return hashlib.sha256(v).hexdigest()

def prepare(d):
    data=ARCHIVE.read_bytes()
    assert digest(data)==HASH
    record=json.loads(gzip.decompress(data))
    src=record["records"]["fixtures/lowat.c"]
    h="Sources/CPublishedTCP/include/PublishedTCP.h"
    header=subprocess.check_output(["git","show",f"{HEADER_COMMIT}:{h}"],cwd=ROOT)
    assert digest(header)==record["source_sha256"][h]
    src_hash=digest(src.encode())
    # The sole treatment gate returns from the original promotion routine in the control.
    # Timer timestamps describe enqueuing the registration and processing its readiness.
    for old,new in [
        ("    if (e->raised ||", "    if (!adaptive) return;\n    if (e->raised ||"),
        ("    set_low(e,MP_LOW,true);","    record_timer(e,true);\n    set_low(e,MP_LOW,true);"),
        ("            e->raised=false;", "            record_timer(e,false);\n            e->raised=false;")]:
        if old not in src and "e->raised=false;" in old:
            old=next(l for l in src.splitlines() if l.strip()=="e->raised=false;")
            new="            record_timer(e,false);\n"+old
        assert src.count(old)==1,old
        src=src.replace(old,new)
    native=subprocess.check_output(["git","show",f"{BASE}:Sources/MicropodRuntime/NativeLoopbackRelay.swift"],cwd=ROOT)
    assert b'qos: .userInitiated)' in native and b'DispatchSource.makeReadSource' in native
    (d/"adaptive-prototype.c").write_text(src)
    (d/"PublishedTCP.h").write_bytes(header)
    subprocess.run(["clang","-std=gnu11","-O2","-Wall","-Wextra","-Werror","-DMP_LOW=131072",
                    "-I",str(d),"-I",str(LIB),str(HERE/"mixed.c"),"-o",str(d/"mixed")],check=True)
    return dict(analysis=BASE,archive_sha256=HASH,prototype_sha256=src_hash,header_sha256=digest(header),
                production_dispatch_source_sha256=digest(native),fixture_sha256=digest((HERE/"mixed.c").read_bytes()),
                reused_fixture_sha256=digest((LIB/"filter_work.c").read_bytes()),
                harness_sha256=digest(Path(__file__).read_bytes()),binary_sha256=digest((d/"mixed").read_bytes()))

def percentile(values,q):return sorted(values)[math.ceil(len(values)*q)-1]

def stats(row):
    tails=row["tails"]; elapsed=(row["score_end_ns"]-row["score_start_ns"])/1e9
    assert len(tails)==12 and row["bulk_sent"]==row["bulk_received"] and row["bulk_window_bytes"]>0
    within=all(row["score_start_ns"]<=x["sent_ns"]<=x["received_ns"]<=row["score_end_ns"] for x in tails)
    assert all(x["seed_bytes"]==262144 and x["marked_bytes"]==17 for x in tails)
    if row["adaptive"]: assert all(0<x["timer_armed_ns"]<=x["timer_serviced_ns"] for x in tails)
    else: assert all(x["timer_armed_ns"]==x["timer_serviced_ns"]==0 for x in tails)
    latency=[(x["received_ns"]-x["sent_ns"])/1e6 for x in tails]
    timers=[(x["timer_serviced_ns"]-x["timer_armed_ns"])/1e6 for x in tails if x["timer_armed_ns"]]
    scale=row["timebase"][0]/row["timebase"][1]*1e-9
    return dict(MiB_s=row["bulk_window_bytes"]/2**20/elapsed,open_tail_p50_ms=statistics.median(latency),
                open_tail_p95_ms=percentile(latency,.95),open_tail_p99_ms=percentile(latency,.99),
                cpu_s_GiB=row["cpu_ticks"]*scale/(row["bulk_window_bytes"]/2**30),
                runnable_s_s=row["runnable_ticks"]*scale/elapsed,timers_ms=timers,
                all_markers_inside_window=within,effective_qos_matches=row["qos_mismatches"]==0 and row["effective_qos_class"]==row["required_qos_class"])

def main():
    p=argparse.ArgumentParser();p.add_argument("--build",type=Path,required=True);p.add_argument("--score",type=Path);args=p.parse_args()
    d=args.build.resolve()
    if args.score is None:
        d.mkdir(exist_ok=False);meta=prepare(d);(d/"build.json").write_text(json.dumps(meta,indent=2));print(d);return
    meta=json.loads((d/"build.json").read_text())
    assert digest((d/"mixed").read_bytes())==meta["binary_sha256"] and digest((HERE/"mixed.c").read_bytes())==meta["fixture_sha256"] and digest(Path(__file__).read_bytes())==meta["harness_sha256"]
    order=["AB","BA"]*4;random.Random(SEED).shuffle(order)
    receipt=dict(build=meta,order=order,seed=SEED,rows=[])
    with args.score.open("x") as out:
        for b,arms in enumerate(order):
            for arm in arms:
                run=subprocess.run([str(d/"mixed"),str(int(arm=="B"))],capture_output=True,text=True,timeout=12)
                row=dict(block=b+1,arm=arm,exit_code=run.returncode,stderr=run.stderr,load=os.getloadavg())
                if run.returncode==0:
                    row["raw"]=json.loads(run.stdout)
                    try:row["summary"]=stats(row["raw"])
                    except AssertionError:row["invalid"]="delivery, marker or timer validation failed"
                else:row["stdout"]=run.stdout
                receipt["rows"].append(row)
                out.seek(0);out.truncate();json.dump(receipt,out,indent=2);out.flush();os.fsync(out.fileno())
                if run.returncode or "invalid" in row: print("first failed attempt retained; stopping");return
    print(args.score)

if __name__=="__main__":main()
