"""#228.03. Score only when called with the explicit 'run' action."""
from contextlib import ExitStack
import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import select
import shutil
import subprocess
import time
import uuid

HERE = Path(__file__).resolve().parent
SEED = 2026112422803
FLOOR = 60
QOS_USER_INITIATED = 0x19
LABELS = {"dev.micropod.published-tcp."+part for part in ("accept","io.0","io.1")}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def observed(meter, pid):
    energy, birth = ctypes.c_uint64(), ctypes.c_uint64()
    err = meter.relay_energy(pid, ctypes.byref(energy), ctypes.byref(birth))
    return {"status":err, "pid":pid, "birth":birth.value, "energy_nj":energy.value}

def energy_delta(first,last):
    if first["status"] or last["status"] or first["birth"]!=last["birth"] or not first["birth"]:
        return None
    # Some Darwin environments return 0 for every energy field.
    delta=last["energy_nj"]-first["energy_nj"]
    return delta if delta>=0 and last["energy_nj"]>0 else None

def admission(mixed, build):
    start = time.monotonic_ns()
    first = mixed.system_counter("host_cpu", 4)
    time.sleep(2)
    last = mixed.system_counter("host_cpu", 4)
    end = time.monotonic_ns()
    delta = None
    if isinstance(first, list) and isinstance(last, list):
        delta = [(b - a) % 2**32 for a, b in zip(first, last)]
    idle = delta[2] / sum(delta) if delta and sum(delta) > 0 else None
    return {"raw_first": first, "raw_last": last, "delta_ticks": delta,
            "start_monotonic_ns": start, "end_monotonic_ns": end,
            "idle_fraction": idle, "eligible_at_90pct": idle is not None and idle >= .90,
            "idle_observation": "observed" if idle is not None else "unavailable: no advancing host tick sample",
            "filesystem_free_GiB": shutil.disk_usage(build).free / 2**30, "timestamp": mixed.now()}

def validate(path, arm):
    records=[json.loads(s) for s in path.read_text().splitlines() if s.startswith("{")]
    phases=[r["event"] for r in records]
    if phases!=["first_listener"]+["owner_sample"]*6+["last_listener","lease_released"]:
        raise ValueError("incomplete listener/owner evidence")
    first,last=records[0],records[-2]
    if first["held"]!=bool(arm) or last["ended"]!=bool(arm) or last["held"] or first["token"]!=last["token"] or ((first["token"]!="none")!=bool(arm)):
        raise ValueError("activity did not span exactly the listener lifetime")
    for phase in ["held_before","held_after"]:
        samples=[r for r in records if r.get("phase")==phase]
        if {r["owner"] for r in samples}!=LABELS or len(samples)!=3 or any(r["qos_class"]!=QOS_USER_INITIATED for r in samples):
            raise ValueError("production relay owners did not retain user-initiated QoS")
    if len({r["pid"] for r in records})!=1 or any(a["uptime_ns"]>=b["uptime_ns"] for a,b in zip(records,records[1:])):
        raise ValueError("process or event ordering changed")
    return records

def one(mixed, meter, build, row, server, serverport, marker, dest, score, save):
    dest.mkdir()
    log=dest/"relay-events.jsonl"
    p=None
    try:
        with log.open("xb") as logs, ExitStack() as stack:
            p=subprocess.Popen([build/"relay","127.0.0.1",str(serverport),"on" if row["arm"] else "off"],
                               stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=logs,text=True)
            stack.callback(mixed.stop,p)
            if not select.select([p.stdout],[],[],8)[0]: raise TimeoutError("relay readiness")
            addr=p.stdout.readline().strip()
            host,port=addr.split(":")
            if host!="127.0.0.1" or not port.isdigit() or not 0<int(port)<65536: raise ValueError("relay endpoint")
            ep=(host,int(port))
            if mixed.exchange(ep,"/id")!=marker.encode(): raise ValueError("marker")
            payload=mixed.exchange(ep,"/data")
            if len(payload)!=8<<20 or hashlib.sha256(payload).hexdigest()!=mixed.PAYLOAD: raise ValueError("8MiB digest")
            row.update(marker=marker,address=addr,relay_pid=p.pid,service_pid=server.pid,marker_and_8MiB_verified=True)
            save()
            try:
                if score:
                    row["admission"]=admission(mixed,build)
                    if row["admission"]["filesystem_free_GiB"]<FLOOR:
                        raise ValueError("disk clearance below floor")
                    row["energy_before"]={k:observed(meter,pid) for k,pid in (("relay",p.pid),("server",server.pid))}
                    row["client_attempted"]=True; save()
                    row.update(mixed.observe_client(stack,server,p,addr,marker,dest,FLOOR))
                    row["energy_after"]={k:observed(meter,pid) for k,pid in (("relay",p.pid),("server",server.pid))}
                    row["energy_delta_nj"]={k:energy_delta(v,row["energy_after"][k]) for k,v in row["energy_before"].items()}
                    if row["minimum_observed_free_GiB"]<FLOOR: raise ValueError("disk floor crossed")
            finally:
                if p.poll() is None:
                    p.stdin.write("release\n");p.stdin.flush()
                    if p.wait(timeout=8)!=0: raise ValueError("failed to release listener cleanly")
        row["lifecycle_and_qos"]=validate(log,row["arm"])
    except BaseException as exc:
        row["error"]=str(exc) or type(exc).__name__
        raise
    finally:
        save()

def main(args):
    build=args.build.resolve(); out=args.output.resolve()
    seal=json.loads((HERE/"build.json").read_text())
    for name,sha in seal["files"].items():
        if digest(build/name)!=sha: raise ValueError("unsealed fixture: "+name)
    spec=importlib.util.spec_from_file_location("mixed",build/"suite.py")
    mixed=importlib.util.module_from_spec(spec);spec.loader.exec_module(mixed)
    meter=ctypes.CDLL(str(build/"energy.dylib"))
    meter.relay_energy.argtypes=[ctypes.c_int,ctypes.POINTER(ctypes.c_uint64),ctypes.POINTER(ctypes.c_uint64)]
    out.mkdir(exist_ok=False)
    scored=args.action=="run"
    orders=[[0,1],[1,0]]*3 if scored else [[0,1]]
    if scored: random.Random(SEED).shuffle(orders)
    marker="activity-"+uuid.uuid4().hex
    report={"started":mixed.now(),"status":"started","action":args.action,"direction":"228.03",
            "tier":"local/host-only","host":platform.node(),"macos":platform.mac_ver()[0],
            "mode":"ambient host-load diagnostic","build_sha256":digest(HERE/"build.json"),
            "driver_sha256":digest(Path(__file__)),"relay_sha256":seal["files"]["relay"],
            "revision":seal["revision"],"changed":"one Foundation listener-scoped activity on or off",
            "order":orders,"seed":SEED,"minimum_disk_GiB":FLOOR,"raw":[]}
    save=lambda: mixed.write(out/"receipt.json",report)
    save()
    try:
        with ExitStack() as resources:
            service,port=mixed.service(resources,marker,out)
            for block,order in enumerate(orders,1):
                for arm in order:
                    row={"block":block,"arm":arm,"started":mixed.now(),"client_attempted":False}
                    report["raw"].append(row); save()
                    one(mixed,meter,build,row,service,port,marker,out/f"block-{block}-{arm}",scored,save)
                    row["finished"]=mixed.now(); save()
        report["status"]="complete"
    except BaseException as e:
        report.update(status="interrupted",error=str(e) or type(e).__name__)
        raise
    finally:
        report["finished"]=mixed.now();save()

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("action",choices=["smoke","run"]);p.add_argument("build",type=Path);p.add_argument("output",type=Path)
    main(p.parse_args())
