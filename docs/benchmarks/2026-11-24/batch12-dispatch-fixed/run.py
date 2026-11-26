"""Check whether a Darwin dispatch relay can use and restore fixed mode in its callback."""
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import select
import socket
import subprocess
import sys
import tempfile
import threading

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
REV = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
PROBE = HERE.parent / "batch11-handshake-tcp/TCPRelayProbe.swift"
CFILES = ["Sources/CPublishedTCP/PublishedTCP.c", "Sources/CPublishedTCP/include/PublishedTCP.h",
          "Sources/MicropodRuntime/NativeLoopbackRelay.swift"]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def save(path, val):
    t = path.with_suffix(".tmp")
    t.write_text(json.dumps(val, indent=2) + "\n")
    t.replace(path)


def build(work):
    raw = {s:subprocess.check_output(["git", "-C", REPO, "show", REV + ":" + s]) for s in CFILES}
    for s, data in raw.items():
        (work / Path(s).name).write_bytes(data)
    swift = work / "NativeLoopbackRelay.swift"
    call = b"source.setEventHandler { mp_tcp_relay_drain(backend.handle, Int32(dataWorkers)) }"
    assert swift.read_bytes().count(call) == 1
    swift.write_bytes(swift.read_bytes().replace(call, b"source.setEventHandler { bench_drain(backend.handle, Int32(dataWorkers), name) }"))
    with (work / "PublishedTCP.h").open("a") as h:
        h.write("\nvoid bench_drain(mp_tcp_relay *, int, const char *);\n")
    (work / "module.modulemap").write_text('module CPublishedTCP { header "PublishedTCP.h" export * }\n')
    flags = ["xcrun", "clang", "-O2", "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-I.", "-c"]
    commands = [flags + ["PublishedTCP.c", "-o", "relay.o"], flags + [str(HERE / "observe.c"), "-o", "observe.o"],
                ["xcrun", "swiftc", "-swift-version", "6", "-O", "-module-cache-path", str(work / "modules"), "-I.",
                 "NativeLoopbackRelay.swift", str(PROBE), "relay.o", "observe.o", "-o", "relay"]]
    for cmd in commands:
        subprocess.run(cmd, cwd=work, check=True)
    return {"revision":REV, "source_sha256":{s:sha(d) for s,d in raw.items()},
            "linked_binary_sha256":sha((work/"relay").read_bytes()),
            "fixture_sha256":{p.name:sha(p.read_bytes()) for p in (PROBE, HERE/"observe.c", HERE/"run.py")},
            "observed_swift_sha256":sha(swift.read_bytes()), "commands":commands,
            "swift":subprocess.check_output(["swiftc","--version"],text=True).strip(),
            "host":platform.platform()}


def read_exact(conn, count):
    chunks = bytearray()
    while len(chunks) < count:
        part = conn.recv(count-len(chunks))
        if not part:
            raise ValueError("EOF before full marker")
        chunks.extend(part)
    return bytes(chunks)


def attempt(work, dest, arm, state):
    rowsfile = dest / "callbacks.jsonl"
    state.update(arm=arm, verified_echo_bytes=0, verified_request_bytes=0, verified_turns=0, eof_both=0)
    with socket.socket() as backend:
        backend.bind(("127.0.0.1", 0))
        backend.listen(2)
        backend.settimeout(3)
        backend_errors = []
        def echo():
            try:
                for flow in range(2):
                    sock, _ = backend.accept()
                    with sock:
                        sock.settimeout(3)
                        for seq in range(8):
                            expect = payload(flow, seq)
                            if read_exact(sock, len(expect)) != expect:
                                raise ValueError("backend marker mismatch")
                            state["verified_request_bytes"] += len(expect)
                            sock.sendall(expect[::-1])
                        if sock.recv(1): raise ValueError("unexpected request after final marker")
                        sock.shutdown(socket.SHUT_WR)
            except (OSError,ValueError) as e:
                backend_errors.append(str(e))
        with rowsfile.open("x") as log:
            child = subprocess.Popen([work/"relay","127.0.0.1",str(backend.getsockname()[1])], stdout=subprocess.PIPE,
                                     stderr=log, env={**os.environ,"BENCH_CALLBACK_FIXED":str(arm)}, text=True)
            worker = threading.Thread(target=echo,daemon=True)
            try:
                worker.start()
                if not select.select([child.stdout], [], [], 8)[0]: raise TimeoutError("relay failed to bind")
                address = child.stdout.readline().strip().split(":")
                if len(address) != 2 or address[0] != "127.0.0.1": raise ValueError("missing scoped loopback relay")
                for flow in range(2):
                    with socket.create_connection(("127.0.0.1",int(address[1])),timeout=3) as conn:
                        for seq in range(8):
                            data = payload(flow,seq)
                            conn.sendall(data)
                            if read_exact(conn,len(data)) != data[::-1]: raise ValueError("client marker mismatch")
                            state["verified_echo_bytes"] += len(data)
                            state["verified_turns"] += 1
                        conn.shutdown(socket.SHUT_WR)
                        if conn.recv(1): raise ValueError("unexpected response after final marker")
                        state["eof_both"] += 1
            except (OSError,ValueError) as e:
                state["delivery_error"] = str(e)
            finally:
                if child.poll() is None:
                    child.terminate()
                try: child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
                child.stdout.close()
                worker.join(timeout=4)
                state["child_exit"] = child.returncode
                state["server_error"] = backend_errors
    lines = rowsfile.read_text().splitlines()
    samples = [json.loads(s) for s in lines if s.startswith("{")]
    state["stderr_other"] = [s for s in lines if not s.startswith("{")]
    state["callbacks_sha256"] = sha(rowsfile.read_bytes())
    state["counts_by_owner"] = {k:len([s for s in samples if s["owner"]==k]) for k in ("io.0","io.1")}
    state["threads_by_owner"] = {k:sorted({s["before"]["tid"] for s in samples if s["owner"]==k}) for k in state["counts_by_owner"]}
    state["set_status"] = sorted({s["set_status"] for s in samples if s["set_status"] != -1})
    state["restore_status"] = sorted({s["restore_status"] for s in samples if s["restore_status"] != -1})
    state["restoration_mismatches"] = sum(not s["restored"] for s in samples)
    applied = [s for s in samples if s["set_status"] == 0]
    state["applied_callbacks"] = len(applied)
    state["fixed_during_drain"] = sum(s["entered"]["timeshare"] == s["leaving"]["timeshare"] == 0 for s in applied)
    state["ordinary_entry_classes"] = sorted({(s["before"]["timeshare"],s["before"]["qos"]) for s in samples})
    state["delivery_clean"] = (state["verified_request_bytes"] == state["verified_echo_bytes"] == 65536
                               and state["verified_turns"] == 16 and state["eof_both"] == 2 and not backend_errors)
    state["all_handler_ids_stable"] = bool(samples) and all(s["stable_thread"] for s in samples)
    return (state["delivery_clean"] and state["all_handler_ids_stable"]
            and min(state["counts_by_owner"].values()) >= 2 and not state["restoration_mismatches"]
            and (not arm or (state["set_status"] == [0] and state["restore_status"] == [0]
                             and state["applied_callbacks"] == state["fixed_during_drain"] == len(samples))))


def payload(flow, seq):
    return hashlib.shake_256(f"micropod.228.04.{flow}:{seq}".encode()).digest(4096)


def main(out):
    out.mkdir(exist_ok=False)
    orders = ["01","10","01","10"]
    random.Random(37).shuffle(orders)
    if orders[0] != "01": orders.reverse()
    assert orders[0] == "01"
    report = {"date":"2026-11-24", "direction":"228.04", "seed":37, "planned_pair_order":orders,
              "evidence_tier":"local/host-only, untimed relay admission", "attempts":[]}
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        report["build"] = build(work)
        for i, order in enumerate(orders,1):
            for pos, a in enumerate(order,1):
                d = out / f"pair-{i}-{a}"
                d.mkdir()
                row = {"pair":i, "position":pos}
                report["attempts"].append(row)
                try:
                    suitable = attempt(work,d,int(a),row)
                finally:
                    save(out/"raw.json",report)
                if not suitable:
                    report["stop_reason"] = "incomplete delivery, effective scheduling, or callback restoration"
                    save(out/"raw.json", report)
                    return
    report["complete"] = True
    save(out/"raw.json",report)


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
