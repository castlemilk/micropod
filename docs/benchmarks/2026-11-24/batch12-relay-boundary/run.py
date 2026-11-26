"""Paired Darwin host boundary diagnostic. Arguments: smoke|run NEW_DIRECTORY."""
from contextlib import ExitStack
import fcntl
import hashlib
from importlib import util
import json
from pathlib import Path
import platform
import random
import shutil
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
BUILD = REPO / ".build/local-published-tcp/20261124-after-restart/handshake"
SEAL = HERE.parent / "batch11-handshake-tcp/post-restart-build.json"
LOCK = HERE.parent / "disposable-local-fixture/terminal-run.lock"
SEED = 2026112423201
REV = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
FLOOR = 60


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def check_build():
    seal = json.loads(SEAL.read_text())
    assert REV == seal["revision"]
    for name in ("suite.py", "fixed", "server", "relay-0", "meter.dylib", "PublishedTCP.c", "NativeLoopbackRelay.swift"):
        assert sha(BUILD / name) == seal["files"][name], name
    spec = util.spec_from_file_location("mixed", BUILD / "suite.py")
    mixed = util.module_from_spec(spec)
    spec.loader.exec_module(mixed)
    return seal, mixed


def listen_owner(child, addr):
    lines = subprocess.check_output(["lsof", "-nP", "-a", "-p", str(child.pid), "-iTCP@" + addr,
                                     "-sTCP:LISTEN", "-Fpn"], text=True, timeout=4).splitlines()
    assert lines == ["p" + str(child.pid), "n" + addr], (child.pid, addr, lines)
    return lines


def verify_route(mixed, child, addr, marker, full):
    host, port = addr.split(":")
    assert host == "127.0.0.1" and child.poll() is None
    ep = host, int(port)
    body = mixed.exchange(ep, "/id")
    assert body == marker.encode()
    proof = {"endpoint":addr, "listener":listen_owner(child,addr),
             "marker":body.decode(), "process":mixed.proc(child.pid)}
    assert proof["process"]["birth"] > 0
    if full:
        data = mixed.exchange(ep, "/data")
        proof.update(data_bytes=len(data), data_sha256=hashlib.sha256(data).hexdigest())
        assert proof["data_bytes"] == (8 << 20) and proof["data_sha256"] == mixed.PAYLOAD
    return proof


def main(action, out):
    assert action in ("smoke", "run")
    seal, mixed = check_build()
    out.mkdir(exist_ok=False)
    order = [[0,1], [1,0]] * 3
    random.Random(SEED).shuffle(order)
    marker = "published-boundary-" + uuid.uuid4().hex
    r = {"date":"2026-11-24", "direction":"232.01", "action":action, "control":"0 = published via two-worker relay",
         "candidate":"1 = direct to same Darwin service, relay remains available", "seed":SEED, "order":order,
         "evidence":"local/host-only ambient TCP loopback diagnostic", "revision":REV, "script_sha256":sha(Path(__file__)),
         "host":platform.platform(), "build_receipt_sha256":sha(SEAL), "build_files":seal["files"], "raw":[],
         "floor_free_gib":FLOOR, "started":mixed.now(), "marker":marker, "status":"active"}
    receipt = out/"receipt.json"
    mixed.write(receipt,r)
    try:
        with ExitStack() as group:
            lock = group.enter_context(LOCK.open("rb"))
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if shutil.disk_usage(BUILD).free / 2**30 < FLOOR:
                raise RuntimeError("disk below floor")
            server, port = mixed.service(group,marker,out)
            relay, pub = mixed.relay(group,0,port,out,marker)
            direct = f"127.0.0.1:{port}"
            assert pub != direct and relay.pid != server.pid
            routes = [(relay,pub),(server,direct)]
            r["initial_route_proofs"] = [verify_route(mixed,p,a,marker,True) for p,a in routes]
            mixed.write(receipt,r)
            births = [p["process"]["birth"] for p in r["initial_route_proofs"]]
            if action == "run":
                for i, block in enumerate(order,1):
                    for arm in block:
                        row = {"block":i,"arm":arm,"selected_endpoint":routes[arm][1],"client_attempted":False}
                        r["raw"].append(row)
                        dest = out/f"block-{i}-{arm}"
                        dest.mkdir()
                        mixed.write(receipt,r)
                        row["route_proofs"] = [verify_route(mixed,p,a,marker,False) for p,a in routes]
                        assert [p["process"]["birth"] for p in row["route_proofs"]] == births
                        idle = mixed.idle_gate(FLOOR)
                        # This is an ambient, locally coordinated slot. Unknown idle is retained.
                        row["admission"] = dict(idle,filesystem_free_GiB=shutil.disk_usage(BUILD).free/2**30)
                        if row["admission"]["filesystem_free_GiB"] < FLOOR: raise RuntimeError("disk below floor")
                        row.update(client_attempted=True,started=mixed.now())
                        mixed.write(receipt,r)
                        with ExitStack() as lifetime:
                            observed = mixed.observe_client(lifetime,server,relay,routes[arm][1],marker,dest,FLOOR)
                        row.update(observed,finished=mixed.now())
                        mixed.write(receipt,r)
                        if row["minimum_observed_free_GiB"] < FLOOR: raise RuntimeError("disk below floor")
                        for k, birth in zip(("relay","server"),births):
                            assert row["raw_initial"][k]["birth"] == row["raw_final"][k]["birth"] == birth
            r["final_route_proofs"] = [verify_route(mixed,p,a,marker,True) for p,a in routes]
            assert [p["process"]["birth"] for p in r["final_route_proofs"]] == births
        r["status"] = "complete"
    except BaseException as e:
        r.update(status="interrupted",error=repr(e))
        raise
    finally:
        r["finished"] = mixed.now()
        mixed.write(receipt,r)


if __name__=="__main__":
    main(sys.argv[1],Path(sys.argv[2]).resolve())
