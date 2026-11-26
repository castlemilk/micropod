"""Compare eager versus deferred read-filter registration at a fixed two-worker budget."""
from contextlib import ExitStack
from importlib import util
import argparse
import hashlib
import json
from pathlib import Path
import random
import uuid

SEED = 202611242314
here = Path(__file__).resolve().parent

def main(build, out):
    build, out = build.resolve(), out.resolve()
    seal = json.loads((here / "build.json").read_text())
    for name, checksum in seal["files"].items():
        if hashlib.sha256((build / name).read_bytes()).hexdigest() != checksum:
            raise RuntimeError("build bytes differ for " + name)
    spec = util.spec_from_file_location("mixed", build / "suite.py")
    mixed = util.module_from_spec(spec)
    spec.loader.exec_module(mixed)
    out.mkdir(exist_ok=False)
    marker = "two-worker-filter-" + uuid.uuid4().hex
    orders = [[0,1], [1,0]] * 3
    random.Random(SEED).shuffle(orders)
    report = dict(issue=230, direction="230.14", control="eager", candidate="defer asynchronous read filter registration",
                  source=seal["revision"], tier="Darwin host-only TCP loopback",
                  predeclared_mode="ambient host load diagnostic", floor_free_gib=60,
                  endpoints="two-worker native relay between Darwin Go service and fixed client, one published port per attempt",
                  workers=2, callback_events=128, read_bytes=262144, profiling=False,
                  fixture_source_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  build_receipt_sha256=hashlib.sha256((here/"build.json").read_bytes()).hexdigest(),
                  started=mixed.now(), order_seed=SEED, order=orders, raw=[], status="running")
    receipt = out / "receipt.json"
    mixed.write(receipt, report)
    try:
        with ExitStack() as resources:
            server,port=mixed.service(resources, marker, out)
            for block,order in enumerate(orders,1):
                for arm in order:
                    dest = out / f"block-{block}-{arm}"
                    dest.mkdir()
                    with ExitStack() as scope:
                        relay,addr = mixed.relay(scope, arm, port, dest, marker)
                        admission = mixed.idle_gate(60)
                        if "error" in admission or admission["filesystem_free_GiB"] < 60:
                            raise RuntimeError("admission failed: " + str(admission))
                        first = dict(block=block, arm=arm, started=mixed.now(), admission=admission, marker=marker)
                        report["raw"].append(first)
                        mixed.write(receipt, report)
                        first.update(mixed.observe_client(scope,server,relay,addr,marker,dest,60))
                        first["finished"]=mixed.now()
                        mixed.write(receipt, report)
                        if first["minimum_observed_free_GiB"] < 60:
                            raise RuntimeError("disk floor crossed")
        report["status"]="complete"
    except BaseException as exc:
        report.update(status="interrupted",error=str(exc))
        raise
    finally:
        paired = []
        for block in range(1,7):
            arms = {x["arm"]:x for x in report["raw"] if x["block"]==block}
            if len(arms)==2 and all(x.get("delivery_clean") for x in arms.values()):
                paired.append([arms[i]["client"] for i in [0,1]])
        report.update(joint_clean=len(paired),finished=mixed.now(),
                      clean_summary={key:mixed.paired_stats(paired,key) for key in ["mib_s","fresh_p95_us","fresh_p99_us"]})
        mixed.write(receipt,report)
if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("build",type=Path);p.add_argument("new_results",type=Path)
    args=p.parse_args()
    main(args.build,args.new_results)
