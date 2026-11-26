"""Darwin loopback mixed load. The smoke subcommand sends two 8 MiB bodies in total."""
import argparse
from contextlib import ExitStack
import ctypes as C
from datetime import datetime, timezone
import hashlib
import http.client
import itertools
import json
import math
import os
from pathlib import Path
import random
import select
import shutil
import signal
import socket
from statistics import median, quantiles
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parent
meter = C.CDLL(str(ROOT/"meter.dylib"))
ORDER_SEED = 202611242303
GI = 1024**3
U = C.c_uint32


def now():
    return datetime.now(timezone.utc).isoformat()


def write(path, obj):
    tmp = path.with_name(path.name+".new")
    tmp.write_text(json.dumps(obj, indent=2)+"\n")
    tmp.replace(path)


def system_counter(method, count):
    counters=(U*count)()
    status=getattr(meter,method)(counters)
    if status:
        return {"error":status}
    return list(counters)


def proc(pid):
    data=(C.c_uint64*5)()
    err=meter.process_totals(pid,data)
    if err: return {"error":err,"pid":pid}
    return dict(zip(("birth","cpu_ticks","runnable_ticks","numer","denom"),data),pid=pid,
                clock=time.monotonic_ns())


def cost(before,after,scored_bytes,wall_s):
    if "error" in before or "error" in after or not scored_bytes or wall_s<=0: return None
    if before["birth"]!=after["birth"]: return None
    scale=after["numer"]/after["denom"]/1e9
    cpu=(after["cpu_ticks"]-before["cpu_ticks"])*scale
    runnable=(after["runnable_ticks"]-before["runnable_ticks"])*scale
    return dict(cpu_s=cpu,cpu_s_per_scored_GiB=cpu/(scored_bytes/GI),runnable_s=runnable,
                runnable_thread_s_per_wall_s=runnable/wall_s,
                runnable_minus_cpu_s=runnable-cpu)


def stop(p):
    if p.poll() is None:
        p.terminate()
        try: p.wait(timeout=2)
        except subprocess.TimeoutExpired: p.kill();p.wait()


def exchange(hostport, endpoint):
    con=http.client.HTTPConnection(*hostport,timeout=3)
    try:
        con.request("GET",endpoint)
        rsp=con.getresponse();body=rsp.read()
        if rsp.status!=200: raise RuntimeError((endpoint,rsp.status))
        return body
    finally: con.close()


def service(stack,marker,out):
    tmp=socket.socket();tmp.bind(("127.0.0.1",0));port=tmp.getsockname()[1];tmp.close()
    log=stack.enter_context((out/"server.log").open("xb"))
    server=subprocess.Popen([str(ROOT/"server"),"-listen",f"127.0.0.1:{port}","-marker",marker],stdout=log,stderr=log)
    stack.callback(stop,server)
    for i in range(100):
        if server.poll() is not None: raise RuntimeError("benchmark-owned server exited")
        try:
            if exchange(("127.0.0.1",port),"/id")==marker.encode(): return server,port
            raise ValueError("unexpected localhost listener marker")
        except (ConnectionRefusedError,ConnectionResetError): time.sleep(.03)
    raise TimeoutError("server startup")


def relay(stack,arm,serverport,out,marker):
    log=stack.enter_context((out/f"relay-{arm}.stderr").open("xb"))
    child=subprocess.Popen([str(ROOT/f"relay-{arm}"),"127.0.0.1",str(serverport)],
                           stdout=subprocess.PIPE,stderr=log,text=True)
    stack.callback(stop,child)
    if not select.select([child.stdout],[],[],5)[0]:raise TimeoutError("relay startup")
    addr=child.stdout.readline().strip();host,port=addr.split(":")
    if host!="127.0.0.1":raise RuntimeError("unexpected relay listener")
    ep=host,int(port)
    if exchange(ep,"/id")!=marker.encode():raise RuntimeError("relay marker")
    payload=exchange(ep,"/data")
    if len(payload)!=8<<20 or hashlib.sha256(payload).hexdigest()!=PAYLOAD:raise RuntimeError("relay payload")
    return child,addr


def idle_gate(min_free, seconds=2):
    first=system_counter("host_cpu",4);time.sleep(seconds);last=system_counter("host_cpu",4)
    if not isinstance(first,list) or not isinstance(last,list):return dict(eligible=False,error="cpu unreadable")
    delta=[(b-a) % 2**32 for a,b in zip(first,last)]
    idle=delta[2]/sum(delta) if sum(delta) else 0
    free=shutil.disk_usage(ROOT).free/GI
    return dict(eligible=idle>=.90 and free>=min_free,idle_fraction=idle,idle_observation_s=seconds,
                floor_idle=.90,filesystem_free_GiB=free,min_free_GiB=min_free,timestamp=now())


def observe_client(stack,server,relay_p,addr,marker,out,min_free):
    pre={"server":proc(server.pid),"relay":proc(relay_p.pid)}
    lo_before=system_counter("loopback_totals",5);start=time.monotonic()
    outf=stack.enter_context((out/"client.out").open("xb"));errf=stack.enter_context((out/"client.err").open("xb"))
    ch=subprocess.Popen([str(ROOT/"fixed"),"http://"+addr,marker],stdout=outf,stderr=errf)
    stack.callback(stop,ch)
    lowest_free=shutil.disk_usage(ROOT).free/GI
    while os.waitid(os.P_PID,ch.pid,os.WEXITED|os.WNOWAIT|os.WNOHANG) is None:
        if time.monotonic()-start>80 or lowest_free<min_free:
            ch.kill();os.waitid(os.P_PID,ch.pid,os.WEXITED|os.WNOWAIT);break
        time.sleep(.1);lowest_free=min(lowest_free,shutil.disk_usage(ROOT).free/GI)
    end=time.monotonic()
    post={"server":proc(server.pid),"relay":proc(relay_p.pid),"client":proc(ch.pid)}
    lo_after=system_counter("loopback_totals",5)
    _,status,waitusage=os.wait4(ch.pid,0);ch.returncode=os.waitstatus_to_exitcode(status)
    client_cpu=waitusage.ru_utime+waitusage.ru_stime
    raw=(out/"client.out").read_text()
    try: client=json.loads(raw)
    except ValueError:client={}
    counted=client.get("bytes",0)
    lo=None if not isinstance(lo_before,list) or not isinstance(lo_after,list) else dict(zip(
        ("in_packets","out_packets","in_errors","out_errors","in_queue_drops"),
        [(b-a)%2**32 for a,b in zip(lo_before,lo_after)]))
    streams=client.get("per_stream_bytes", [])
    clean=(ch.returncode==0 and client.get("streams")==32 and client.get("arrivals")==240
           and client.get("period_us")==25000 and "errors" in client and client["errors"] in (None,[])
           and client.get("reopened")==0 and len(streams)==32 and min(streams)>0 and sum(streams)==counted
           and client.get("window_s",0)>=6 and client.get("mib_s",0)>0
           and math.isclose(counted/1048576/client["window_s"],client["mib_s"])
           and client.get("fresh_p95_us",0)>0 and client.get("fresh_p99_us",0)>=client["fresh_p95_us"])
    usage={k:cost(pre[k],post[k],counted,end-start) for k in ("server","relay")}
    if "error" not in post["client"]:
        pre["client"]=dict(post["client"],cpu_ticks=0,runnable_ticks=0)
        usage["client"]=cost(pre["client"],post["client"],counted,end-start)
    return dict(client=client,exit=ch.returncode,delivery_clean=clean,raw_initial=pre,raw_final=post,
                latency_p95_at_most_75_ms=clean and client["fresh_p95_us"]<=75000,
                loopback_host_shared_raw=[lo_before,lo_after],loopback_host_shared_delta=lo,
                cost_per_role=usage,client_wait4_cpu_s=client_cpu,
                cpu_scope="full fixed-client lifetime including establish/warm/drain; denominator scored bytes",
                period_s=end-start,minimum_observed_free_GiB=lowest_free)


def paired_stats(pairs, key):
    if not pairs:return None
    a=[r[0][key] for r in pairs];b=[r[1][key] for r in pairs]
    if not all(a):return None
    ratios=[100*(v/u-1) for u,v in zip(a,b)]
    boot=sorted(median(row) for row in itertools.product(ratios, repeat=len(ratios)))
    ci=None if len(pairs)<2 else [quantiles(boot,n=40,method="inclusive")[i] for i in (0,-1)]
    return dict(control_median=median(a),candidate_median=median(b),paired_median_pct=median(ratios),
                descriptive_paired_bootstrap_95_pct=ci,larger_pairs=sum(r>0 for r in ratios))


def main(args):
    out=args.new_output.resolve();out.mkdir(parents=False,exist_ok=False)
    smoke=args.mode=="smoke";marker="loopback-"+uuid.uuid4().hex
    relative=list(range(6));random.Random(ORDER_SEED).shuffle(relative)
    orders=[[0,50000] if n%2==0 else [50000,0] for n in relative]
    report=dict(mode=args.mode,tier="Darwin host-only loopback, no VM",seed=ORDER_SEED,
                first_attempt_order=orders,started=now(),attempts=[],smokes=[],throughput_unit="MiB/s")
    report["comparison_status"]="qualified idle host" if args.mode=="run" else ("observed-load diagnostic, ineligible for stock or peer verdict" if args.mode=="diagnostic" else "untimed smoke")
    report["qualified_precheck"]=json.loads((ROOT/"qualified-initial-gate.json").read_text()) if (ROOT/"qualified-initial-gate.json").exists() else None
    report["file_sha256"]={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in
        ("hot.c","PublishedTCP.h","dispatch-probe.c","fixed.go","server.go","relay-0","relay-50000",
         "fixed","server","meter.c","meter.dylib","suite.py")}
    path=out/"receipt.json";write(path,report)
    try:
        with ExitStack() as resources:
            server,port=service(resources,marker,out)
            for arm in (0,50000):
                dest=out/f"smoke-{arm}";dest.mkdir()
                with ExitStack() as scope:
                    rp,addr=relay(scope,arm,port,dest,marker)
                    report["smokes"].append(dict(arm=arm,service_hash=PAYLOAD,payload_B=8<<20,
                        marker_match=True,relay_observer=proc(rp.pid),server_observer=proc(server.pid),
                        lo0=system_counter("loopback_totals",5)))
                write(path,report)
            if smoke: report["status"]="smoke completed";return
            if args.min_free_gib is None or args.min_free_gib<=0:
                raise ValueError("pass an explicit positive filesystem floor")
            for block,order in enumerate(orders,1):
                for arm in order:
                    dest=out/f"block-{block}-{arm}";dest.mkdir()
                    with ExitStack() as scope:
                        rp,addr=relay(scope,arm,port,dest,marker)
                        gate=idle_gate(args.min_free_gib)
                        gate["meets_stock_idle"]=gate["eligible"] if "error" not in gate else False
                        if args.mode=="diagnostic" and "error" not in gate:
                            gate["eligible"]=gate["filesystem_free_GiB"]>=args.min_free_gib
                        if not gate["eligible"]:
                            report.update(status="pre-start gate blocked",gate=gate,next_block=block,next_arm=arm)
                            return
                        first=dict(block=block,arm_ns=arm,start=now(),admission=gate)
                        report["attempts"].append(first);write(path,report)
                        first.update(observe_client(scope,server,rp,addr,marker,dest,args.min_free_gib))
                        first["finish"]=now();write(path,report)
                        if first["minimum_observed_free_GiB"]<args.min_free_gib:
                            report["status"]="disk gate lost";return
            report["status"]="complete"
    except BaseException as e:
        report.update(status="interrupted",error=f"{type(e).__name__}: {e}");raise
    finally:
        pairs=[]
        for block in range(1,7):
            arms={r["arm_ns"]:r for r in report["attempts"] if r["block"]==block}
            if len(arms)==2 and all(v.get("delivery_clean") for v in arms.values()):
                pairs.append([arms[i]["client"] for i in (0,50000)])
        report.update(joint_clean_pairs=len(pairs),clean_pair_summary={
            k:paired_stats(pairs,k) for k in ("mib_s","fresh_p95_us","fresh_p99_us")},finished=now())
        write(path,report)
        print(report["status"] if "status" in report else "unknown",path)


PAYLOAD=hashlib.sha256(b"micropod"*(1<<20)).hexdigest()
if __name__=="__main__":
    signal.signal(signal.SIGTERM,lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    p=argparse.ArgumentParser(description=__doc__);p.add_argument("mode",choices=["smoke","run","diagnostic"])
    p.add_argument("new_output",type=Path);p.add_argument("--min-free-gib",type=float)
    main(p.parse_args())
