#!/usr/bin/env python3
"""Controlled 3-way real-workload workspace & CI benchmark: OrbStack vs VZ Tuned vs HVF Phase B4."""
import argparse
import hashlib
import json
import os
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import bench_engine_tuning as bet  # noqa: E402

B5_KERNEL = ROOT / ".build/local-kernel-pages/20261125-b5-16k/full-16k/Image"
B4_KERNEL = ROOT / ".build/local-kernel-pages/20261125-b4-16k/full-16k/Image"


def build_probes(work: Path):
    env_l = dict(os.environ)
    env_l.pop("GOROOT", None)
    env_l.update({"GOOS": "linux", "GOARCH": "arm64", "CGO_ENABLED": "0"})

    wsbench = work / "workspacebench"
    subprocess.run(
        ["go", "build", "-trimpath", "-o", str(wsbench), str(ROOT / "scripts/workspacebench/main.go")],
        env=env_l,
        check=True,
    )
    wsbench.chmod(0o755)

    sink_src = work / "sink.go"
    sink_src.write_text(
        """package main
import ("crypto/sha256"; "encoding/hex"; "fmt"; "io"; "net")
func main() {
    ln, err := net.Listen("tcp", ":9090")
    if err != nil { panic(err) }
    for {
        c, err := ln.Accept()
        if err != nil { continue }
        go func(conn net.Conn) {
            defer conn.Close()
            h := sha256.New()
            n, _ := io.Copy(h, conn)
            fmt.Fprintf(conn, "%d %s\\n", n, hex.EncodeToString(h.Sum(nil)))
        }(c)
    }
}
"""
    )
    sink = work / "sink-linux"
    subprocess.run(
        ["go", "build", "-trimpath", "-o", str(sink), str(sink_src)],
        env=env_l,
        check=True,
    )
    sink.chmod(0o755)
    sink_src.unlink()
    return wsbench, sink


def seed_workspace_fixtures(work: Path):
    # 1. 1,000-file realistic source tree (50 dirs x 20 files, ~2 KiB each = ~2 MiB)
    tree = work / "src-tree"
    for d in range(50):
        sub = tree / f"pkg{d:02d}"
        sub.mkdir(parents=True, exist_ok=True)
        for f in range(20):
            (sub / f"file_{f:02d}.go").write_text(
                f"package pkg{d:02d}\n// " + ("x" * 2000) + f"\nvar V{f} = {d * 100 + f}\n"
            )

    # 2. 1,000-file tarball for bind-mounted tar extract/write/delete test
    tar_path = work / "tree.tar"
    bet.run(["tar", "-cf", str(tar_path), "-C", str(work), "src-tree"], timeout=60)
    return tree, tar_path


def bench_workspace_arm(sock: Path, engine_label: str, work: Path, rounds: int = 3):
    # 1. 1,000-file WalkDir + ReadFile + SHA-256 (3 passes per round)
    stat_pass1, stat_pass2, stat_pass3 = [], [], []
    read_pass1, read_pass2, read_pass3 = [], [], []
    digests = set()
    for _ in range(rounds):
        out = bet.docker(
            sock, "run", "--rm", "--cpus", "4", "--memory", "1g",
            "-v", f"{work}:/mpw",
            "alpine:3.23", "/mpw/workspacebench", "scan", "/mpw/src-tree",
            timeout=60,
        ).stdout.strip()
        passes = json.loads(out)
        stat_pass1.append(passes[0]["stat_ms"])
        stat_pass2.append(passes[1]["stat_ms"])
        stat_pass3.append(passes[2]["stat_ms"])
        read_pass1.append(passes[0]["read_ms"])
        read_pass2.append(passes[1]["read_ms"])
        read_pass3.append(passes[2]["read_ms"])
        for p in passes:
            digests.add(p["sha256"])
    if len(digests) != 1:
        raise RuntimeError(f"{engine_label}: inconsistent workspace scan SHA-256 digests: {digests}")

    # 2. Host-edit visibility (size, held, replace, unlink) across 3 rounds
    edit_dir = work / f"edits-{uuid.uuid4().hex[:8]}"
    edit_dir.mkdir()
    try:
        for i in range(rounds):
            for kind in ("size", "held", "replace", "unlink"):
                (edit_dir / f"{kind}-{i}").write_text("previous")
        proc = subprocess.Popen(
            [
                "docker", "--host", f"unix://{sock}", "run", "--rm",
                "-v", f"{work}:/mpw",
                "alpine:3.23", "/mpw/workspacebench", f"/mpw/{edit_dir.name}", str(rounds),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        per_kind = {k: [] for k in ("size", "held", "replace", "unlink")}
        for i in range(rounds):
            for kind in ("size", "held", "replace", "unlink"):
                ready = edit_dir / f"{kind}-{i}.ready"
                done = edit_dir / f"{kind}-{i}.done"
                target = edit_dir / f"{kind}-{i}"
                tw = time.perf_counter()
                while not ready.exists():
                    if time.perf_counter() - tw > 15:
                        raise RuntimeError(f"{engine_label}: timeout waiting for {ready}")
                    time.sleep(0.002)
                t0 = time.perf_counter()
                if kind == "size":
                    with open(target, "ab") as f:
                        f.write(b"revision")
                elif kind == "held":
                    with open(target, "r+b") as f:
                        f.write(b"revision")
                elif kind == "replace":
                    tmp = edit_dir / f"{kind}-{i}-tmp"
                    tmp.write_text("revision")
                    os.replace(tmp, target)
                elif kind == "unlink":
                    target.unlink()
                while not (done.exists() and done.stat().st_size > 0):
                    if time.perf_counter() - t0 > 5:
                        raise RuntimeError(f"{engine_label}: timeout waiting for {done}")
                    time.sleep(0.001)
                status = done.read_text().strip()
                per_kind[kind].append({"status": status, "ms": round((time.perf_counter() - t0) * 1000, 2)})
        out, err = proc.communicate(timeout=20)
        if proc.returncode != 0:
            per_kind["error"] = f"exit {proc.returncode}: {(out + err).strip()[:200]}"
    finally:
        shutil.rmtree(edit_dir, ignore_errors=True)

    # 3. Bind-mounted 1,000-file tar extract + rm -rf inside RW /mpw workspace
    extract_ms = []
    rm_ms = []
    for _ in range(rounds):
        sub = f"extract-{uuid.uuid4().hex[:8]}"
        cmd = (
            f"mkdir -p /mpw/{sub} && "
            f"t0=$(date +%s%3N 2>/dev/null || awk 'BEGIN{{srand(); print 0}}'); "
            f"tar -xf /mpw/tree.tar -C /mpw/{sub} && "
            f"echo EXTRACT_DONE && "
            f"rm -rf /mpw/{sub}"
        )
        # Time extract and rm separately via sh + /proc/uptime for sub-ms precision on BusyBox
        sh_cmd = (
            f"mkdir -p /mpw/{sub} && "
            f"read u0 _ < /proc/uptime && "
            f"tar -xf /mpw/tree.tar -C /mpw/{sub} && "
            f"read u1 _ < /proc/uptime && "
            f"rm -rf /mpw/{sub} && "
            f"read u2 _ < /proc/uptime && "
            f"echo \"$u0 $u1 $u2\""
        )
        out = bet.docker(
            sock, "run", "--rm", "--cpus", "4", "--memory", "1g",
            "-v", f"{work}:/mpw",
            "alpine:3.23", "sh", "-c", sh_cmd,
            timeout=60,
        ).stdout.strip().split()
        u0, u1, u2 = map(float, out[-3:])
        extract_ms.append(round((u1 - u0) * 1000.0, 1))
        rm_ms.append(round((u2 - u1) * 1000.0, 1))

    # 4. Sequential 64 MiB bind-mount write + read throughput (dd 256 KiB blocks)
    write_mibs, read_mibs = [], []
    for _ in range(rounds):
        fname = f"io-{uuid.uuid4().hex[:8]}.bin"
        sh_cmd = (
            f"read u0 _ < /proc/uptime && "
            f"dd if=/dev/zero of=/mpw/{fname} bs=262144 count=256 2>/dev/null && "
            f"read u1 _ < /proc/uptime && "
            f"dd if=/mpw/{fname} of=/dev/null bs=262144 2>/dev/null && "
            f"read u2 _ < /proc/uptime && "
            f"rm -f /mpw/{fname} && "
            f"echo \"$u0 $u1 $u2\""
        )
        out = bet.docker(
            sock, "run", "--rm", "--cpus", "4", "--memory", "1g",
            "-v", f"{work}:/mpw",
            "alpine:3.23", "sh", "-c", sh_cmd,
            timeout=60,
        ).stdout.strip().split()
        u0, u1, u2 = map(float, out[-3:])
        write_mibs.append(round(64.0 / max(u1 - u0, 0.001), 1))
        read_mibs.append(round(64.0 / max(u2 - u1, 0.001), 1))

    # 5. Host -> Guest 64 MiB Published-Port TCP upload (SHA-256 verified)
    tag = f"mpup-{uuid.uuid4().hex[:8]}"
    upload_mibs = []
    try:
        bet.docker(
            sock, "run", "-d", "--name", tag,
            "-p", "127.0.0.1::9090",
            "--cpus", "4", "--memory", "512m",
            "-v", f"{work}:/mpw:ro",
            "alpine:3.23", "/mpw/sink-linux",
            timeout=30,
        )
        port = bet.docker(sock, "port", tag, "9090/tcp", timeout=15).stdout.strip().splitlines()[0].rsplit(":", 1)[-1]
        time.sleep(0.2)
        chunk = bytes((i % 251) for i in range(1024 * 1024))
        h = hashlib.sha256()
        for _ in range(64):
            h.update(chunk)
        expected_sha = h.hexdigest()
        for _ in range(rounds):
            t0 = time.perf_counter()
            s = socket.create_connection(("127.0.0.1", int(port)), timeout=15)
            s.settimeout(15)
            for _ in range(64):
                s.sendall(chunk)
            s.shutdown(socket.SHUT_WR)
            resp = s.recv(4096).decode().strip()
            dt = time.perf_counter() - t0
            s.close()
            if expected_sha not in resp or "67108864" not in resp:
                raise RuntimeError(f"{engine_label}: upload mismatch: {resp!r}")
            upload_mibs.append(round(64.0 / max(dt, 0.0001), 1))
    finally:
        bet.docker(sock, "rm", "-f", tag, timeout=15, check=False)

    return {
        "engine": engine_label,
        "scan_1000_files": {
            "stat_pass1_ms": round(statistics.median(stat_pass1), 2),
            "stat_pass2_ms": round(statistics.median(stat_pass2), 2),
            "stat_pass3_50ms_pause_ms": round(statistics.median(stat_pass3), 2),
            "read_pass1_ms": round(statistics.median(read_pass1), 2),
            "read_pass2_ms": round(statistics.median(read_pass2), 2),
            "read_pass3_50ms_pause_ms": round(statistics.median(read_pass3), 2),
            "sha256": next(iter(digests)),
        },
        "host_edit_visibility": {
            k: (
                {
                    "statuses": [x["status"] for x in v],
                    "median_ms": round(statistics.median([x["ms"] for x in v]), 2),
                    "all_observed": all(x["status"] == "observed" for x in v),
                }
                if isinstance(v, list)
                else v
            )
            for k, v in per_kind.items()
        },
        "tar_extract_1000_ms": round(statistics.median(extract_ms), 1),
        "rm_rf_1000_ms": round(statistics.median(rm_ms), 1),
        "seq_64m_write_mibs": round(statistics.median(write_mibs), 1),
        "seq_64m_read_mibs": round(statistics.median(read_mibs), 1),
        "published_upload_64m_mibs": round(statistics.median(upload_mibs), 1),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--kernel", type=Path, default=B5_KERNEL)
    ap.add_argument("--idle-poll-us", type=int, default=150)
    ap.add_argument("--label", default="phase-b5-workspace-ci")
    args = ap.parse_args()

    work = Path(tempfile.mkdtemp(prefix="mp-ws-ci-", dir="/private/tmp"))
    try:
        build_probes(work)
        seed_workspace_fixtures(work)

        img_tar = work / "images.tar"
        bet.run(
            ["docker", "--host", f"unix://{bet.ORB_SOCK}", "save", "-o", str(img_tar),
             "registry.k8s.io/pause:3.10.2", "alpine:3.23"],
            timeout=120,
        )

        base_tools = bet.AUTH_PRODUCT_DIR / "micropod-oci-tools"
        if not base_tools.exists():
            base_tools = bet.DEFAULT_PRODUCT_DIR / "micropod-oci-tools"
        cand_tools = work / "tools-candidate"
        bet.stage_oci_tools(base_tools, cand_tools, rebuild_runner=False)

        mp_bin = bet.AUTH_PRODUCT_DIR / "micropod"
        if not mp_bin.exists():
            mp_bin = bet.DEFAULT_PRODUCT_DIR / "micropod"

        poll_arg = f" idle_poll_us={args.idle_poll_us}" if args.idle_poll_us > 0 else ""
        cand_kargs = (
            "micropod.ci_sched=hrtick-250us micropod.ci_wakeup=next-buddy,sync-colocate "
            "cgroup.memory=nokmem,nosocket slab_min_order=2 swiotlb=noforce "
            f"workqueue.power_efficient=1 micropod.ci_sysctls=perf micropod.ci_cc=cubic{poll_arg}"
        )

        results = {
            "label": args.label,
            "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "rounds": args.rounds,
            "kernel": str(args.kernel),
            "idle_poll_us": args.idle_poll_us,
            "arms": {},
        }

        for name, kind in [("orbstack", "orb"), ("micropod-vz-tuned", "vz"), ("micropod-hvf", "hvf")]:
            print(f"=== Workspace CI arm: {name} ===", flush=True)
            worker = None
            try:
                if kind == "orb":
                    sock = bet.ORB_SOCK
                    boot_s = None
                elif kind == "vz":
                    worker = bet.WorkerHandle(name, mp_bin, cand_tools, args.kernel, cand_kargs, work)
                    boot_s = worker.start()
                    bet.load_images(worker.sock, img_tar)
                    sock = worker.sock
                else:
                    worker = bet.HVFWorkerHandle(
                        name, bet.DEFAULT_HVF_BIN, bet.DEFAULT_HVF_INITRD, cand_tools,
                        args.kernel, work, mtu=9000, wakeup="next-buddy,sync-colocate", cc="cubic",
                        idle_poll_us=args.idle_poll_us if args.idle_poll_us > 0 else None,
                    )
                    boot_s = worker.start()
                    bet.load_images(worker.sock, img_tar)
                    sock = worker.sock

                arm = bench_workspace_arm(sock, name, work, rounds=args.rounds)
                arm["boot_s"] = boot_s
                results["arms"][name] = arm
                print(f"  {name}: {json.dumps(arm)}", flush=True)
            finally:
                if worker is not None:
                    worker.stop()

        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(results, indent=2) + "\n")
        print(f"\nSaved workspace CI receipt to {args.out}", flush=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
