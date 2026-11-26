"""Deliver HVF-produced frames to independently built Linux CI jobs over their published sockets."""

import http.client
import json
import random
import socket
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack

from qualify import HERE, ROOT, request, require, terminal, window

FRAME = 65536
FRAMES = 128
DEFAULT_SEND_KIB = 512


def schedule(buffers):
    if not buffers:
        return [
            (p, DEFAULT_SEND_KIB)
            for p in ("staged", "mapped", "mapped", "staged", "mapped", "staged", "staged", "mapped")
        ]
    conditions = [("staged", 64), ("mapped", 64), ("staged", 512), ("mapped", 512)]
    # Every condition occupies every position and follows each other condition once per quartet.
    rows = [[0, 1, 3, 2], [1, 2, 0, 3], [2, 3, 1, 0], [3, 0, 2, 1]]
    rng = random.Random(34326)
    order = []
    for _ in range(2):
        for block in rng.sample(rows, 4):
            order.extend(conditions[i] for i in block)
    return order


def grant_schedule():
    # The mirrored rows balance first-order carryover for an odd number of conditions.
    modes = [(0, "scalar"), (1, "scalar"), (8, "scalar"), (1, "neon"), (8, "neon")]
    rows = [[(offset + k) % 5 for k in (0, 1, 4, 2, 3)] for offset in range(5)]
    rows += [row[::-1] for row in rows]
    return [
        ("mapped", DEFAULT_SEND_KIB, *modes[i]) for row in random.Random(4315).sample(rows, 10) for i in row
    ]


def low_water_schedule():
    choices = [(0, "scalar", 0), (0, "scalar", 128), (8, "neon", 0), (8, "neon", 128)]
    rows = [(0, 1, 3, 2), (1, 2, 0, 3), (2, 3, 1, 0), (3, 0, 2, 1)]
    rng = random.Random(35892)
    return [
        ("mapped", DEFAULT_SEND_KIB, *choices[i])
        for _ in range(2)
        for row in rng.sample(rows, 4)
        for i in row
    ]


def build(root, folder, buffers=False, *, order=None):
    src = ROOT / "scripts/relaybench/hvf_notify"
    files = [src / "flows.c", src / "flows.S", src / "vm.c", src.parent / "hvf_tx_probe/apple.c"]
    exe = root / "flow-producer"
    terminal.invoke(
        "xcrun",
        "clang",
        "-arch",
        "arm64",
        "-O2",
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        *files,
        "-framework",
        "Hypervisor",
        "-o",
        exe,
    )
    ent = root / "hvf.plist"
    ent.write_text(
        '<plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>'
    )
    terminal.invoke("codesign", "--force", "--sign", "-", "--entitlements", ent, exe)
    terminal.invoke("codesign", "--verify", "--strict", exe)
    terminal.save(
        folder / "bridge-plan.json",
        {
            "main": terminal.digest(exe),
            "frames": FRAMES,
            "frame_bytes": FRAME,
            "max_pending_bytes_per_flow": 8 * FRAME,
            "order": order if order is not None else schedule(buffers),
            "fault": {"held": 0, "reset_after_first_verified_frame": 1},
            "count": 32,
            "ci_limit": 4,
            "sources": {
                str(p.relative_to(ROOT)): terminal.digest(p)
                for p in [*files, src / "vm.h", HERE / "bridge.py"]
            },
        },
    )
    return exe


def response(sock, job, start):
    try:
        with http.client.HTTPResponse(sock) as reply:
            reply.begin()
            body = reply.read(4097)
            require(reply.status == 200 and len(body) <= 4096, f"HTTP {reply.status}: {body[:200]!r}")
            data = json.loads(body)
            require(
                data
                == {"name": job["name"], "cookie": job["cookie"], "frames": FRAMES, "bytes": FRAME * FRAMES},
                f"unverified bytes or tenant identity for {job['name']}",
            )
        return {"name": job["name"], "seconds": time.monotonic() - start, "verified": True}
    except (OSError, http.client.HTTPException, ValueError) as exc:
        return {
            "name": job["name"],
            "seconds": time.monotonic() - start,
            "verified": False,
            "error": str(exc) or type(exc).__name__,
            "disconnected": isinstance(exc, (ConnectionResetError, http.client.RemoteDisconnected)),
        }


def transfer(exe, jobs, direct, fault, send_kib, group=0, store="scalar", low_kib=0):
    with ExitStack() as stack:
        sockets = []
        low_readbacks = []
        for i, j in enumerate(jobs):
            sock = stack.enter_context(socket.create_connection(("127.0.0.1", j["port"]), timeout=32))
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, send_kib << 10)
            if low_kib:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDLOWAT, low_kib << 10)
            low_readbacks.append(sock.getsockopt(socket.SOL_SOCKET, socket.SO_SNDLOWAT))
            require(not low_kib or low_readbacks[-1] == low_kib << 10, "Darwin write threshold readback")
            require(
                sock.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF) == send_kib << 10,
                "effective sender buffer differs from request",
            )
            mode = "?fault=hold" if fault and i == 0 else "?fault=reset" if fault and i == 1 else ""
            header = (
                f"POST /frames{mode} HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                f"Content-Length: {FRAMES * FRAME}\r\nConnection: close\r\n\r\n"
            )
            sock.sendall(header.encode("ascii"))
            sockets.append(sock)
        if fault:
            # The held job has reached its application barrier before the producer starts.
            deadline = time.monotonic() + 4
            while not json.loads(request(jobs[0], "/identity"))["holding_upload"]:
                require(time.monotonic() < deadline, "receiver never entered the hold")
                time.sleep(0.01)
        fds = [s.fileno() for s in sockets]
        start = time.monotonic()
        options = ["--group", str(group), store] if group else []
        command = [
            exe,
            *options,
            str(FRAMES),
            *(f"{fd}:{j['cookie']}" for fd, j in zip(fds, jobs, strict=True)),
        ]
        with (
            subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                pass_fds=fds,
                text=True,
            ) as proc,
            ThreadPoolExecutor(max_workers=len(jobs)) as readers,
        ):
            replies = [readers.submit(response, s, j, start) for s, j in zip(sockets, jobs, strict=True)]
            try:
                proc.stdin.write(f"1 {int(direct)} 8\n")
                proc.stdin.close()
                release_s = None
                if fault:
                    for f in replies[2:]:
                        require(f.result(timeout=20)["verified"], "healthy flow failed before release")
                    require(
                        not replies[0].done() and json.loads(request(jobs[0], "/identity"))["holding_upload"],
                        "held tenant resumed before healthy siblings finished",
                    )
                    release_s = time.monotonic() - start
                    request(jobs[0], "/release", "POST")
                rc = proc.wait(timeout=38)
                out, err = proc.stdout.read(), proc.stderr.read()
                require(rc == 0, f"HVF execution failed ({rc}): {err[-1000:]}")
                delivery = [f.result(timeout=5) for f in replies]
                raw = json.loads(out)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                for sock in sockets:
                    try:
                        sock.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
        reset = json.loads(request(jobs[1], "/identity"))["reset_after_verified_frame"] if fault else 0
        row = {
            "path": "mapped" if direct else "staged",
            "fault": fault,
            "raw": raw,
            "send_kib": send_kib,
            "group": group,
            "store": store,
            "low_kib": low_kib,
            "effective_low_bytes": low_readbacks,
            "delivery": delivery,
            "host_monotonic_start": start,
            "healthy_finished_before_release": release_s,
            "reset_after_verified_frame": reset,
            "e2e_s": max(r["seconds"] for r in delivery),
        }
        return row


def validate(row):
    fault = row["fault"]
    raw = row["raw"]
    require(
        raw["direct"] == int(row["path"] == "mapped")
        and len(raw["flows"]) == len(row["delivery"]) == 32
        and raw["sender_cpu_ns"] > 0
        and raw["wall_ns"] > 0,
        "incomplete host receipts",
    )
    for i, (flow, reply) in enumerate(zip(raw["flows"], row["delivery"], strict=True)):
        if fault and i == 1:
            require(
                not reply["verified"] and reply["disconnected"] and row["reset_after_verified_frame"] == 1,
                "expected tenant reset was not observed at both ends",
            )
        else:
            require(
                reply["verified"] and flow["error"] == 0 and flow["bytes"] == FRAMES * FRAME,
                f"unverified flow {i}",
            )
    if fault:
        release = row["healthy_finished_before_release"]
        require(
            all(r["seconds"] <= release for r in row["delivery"][2:])
            and row["delivery"][0]["seconds"] > release
            and raw["flows"][0]["waits"] > 0,
            "slow flow did not exercise independent backpressure",
        )
    else:
        require(raw["grants"] == len(raw["flows"]) * ((FRAMES + 7) // 8), "unexpected guest refill count")
    if "group" in row:
        limit = max(1, row["group"])
        require(
            raw["group_limit"] == row["group"]
            and raw["vector_store"] == int(row["store"] == "neon")
            and raw["completion_exits"] == 1
            and 0 < raw["vcpu_ns"] <= raw["wall_ns"]
            and 1 <= raw["max_group"] <= limit
            and (raw["grants"] + limit - 1) // limit <= raw["data_exits"] <= raw["grants"],
            "inconsistent guest submission accounting",
        )
    if "effective_low_bytes" in row:
        levels = row["effective_low_bytes"]
        require(
            len(levels) == len(raw["flows"])
            and len(set(levels)) == 1
            and levels[0] > 0
            and (not row["low_kib"] or levels[0] == row["low_kib"] << 10),
            "inconsistent socket write thresholds",
        )
        if not fault:
            for f in raw["flows"]:
                require(
                    f["sends"] == (FRAMES + 7) // 8 + f["short_writes"] + f["would_block"] + f["interrupted"],
                    "send calls did not match completed, partial and blocked writes",
                )


def study(cohort, folder, buffers=False, *, profile="bridge"):
    fault_case = ("mapped", DEFAULT_SEND_KIB)
    if profile == "grants":
        order = grant_schedule()
        fault_case += (8, "neon")
    elif profile == "low-water":
        order = low_water_schedule()
        fault_case += (8, "neon", 128)
    else:
        order = schedule(buffers or profile == "buffers")
    exe = build(cohort.runner.root, folder, order=order)
    cohort.add(32)
    # One identical bounded CI burst per transfer window.
    plan = json.loads((folder / "bridge-plan.json").read_bytes())
    for i, (mode, send_kib, *options) in enumerate([*plan["order"], fault_case]):
        code = f"hv{i:02}"
        started = threading.Event()
        with ThreadPoolExecutor(max_workers=1) as executor:
            ci = executor.submit(window, cohort, 4, code, started)
            if not started.wait(15):
                ci.result()
                raise RuntimeError("CI wave failed to start")
            row = transfer(exe, cohort.jobs, mode == "mapped", i == len(plan["order"]), send_kib, *options)
            jobs = ci.result()
        origin = jobs["host_monotonic_start"]
        lo = row["host_monotonic_start"] - origin
        hi = lo + row["e2e_s"]
        row["ci_wave"] = code
        row["overlap_builds"] = [
            j["name"] for j in jobs["jobs"] if j["submitted_s"] < hi and j["build_done_s"] > lo
        ]
        row["transfer_relative_to_wave_s"] = [lo, hi]
        terminal.save(folder / f"transfer-{code}.json", row)
        validate(row)
        require(row["overlap_builds"] and hi < jobs["seconds"], "transfer extended outside CI burst")
        print(
            f"{code} {mode} group={row['group']} {row['store']} low={row['low_kib']} KiB: {len(row['delivery'])} endpoints, "
            f"{row['e2e_s']:.3f}s, fault={row['fault']}",
            flush=True,
        )
    cohort.running()
