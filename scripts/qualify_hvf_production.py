#!/usr/bin/env python3
"""End-to-end production qualification suite for Micropod's Apple Silicon HVF engine (Phase B6).

Verifies seven production-grade gates on live hardware and writes a deterministic JSON receipt:
1. Graceful SIGTERM shutdown (VSOCK_PORT_CTRL 2379 -> guest sync -> PSCI_SYSTEM_OFF) + ext4 persistence.
2. Snapshot restore live wall-clock resync (after host pause) + live TLS HTTPS inside restored fork.
3. Cross-workspace snapshot fork rebinding + 4/4 POSIX host-edit visibility (size/held/replace/unlink).
4. Snapshot integrity & fail-fast validation (CRC32 bit-flip, device count mismatch, slot ID swap).
5. Outbound eth0 egress isolation (127.0.0.1, 169.254.169.254 blocked) + 200-query DNS churn FD hygiene.
6. Sustained concurrency (24 parallel containers), cgroup OOMKilled=true (137), published TCP, and idle CPU.
7. Signed VMM binary entitlement & initrd packaging readiness.
"""

import argparse
import concurrent.futures
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import bench_engine_tuning as bet  # noqa: E402

B5_KERNEL = ROOT / ".build/local-kernel-pages/20261125-b5-16k/full-16k/Image"


def wait_docker_ping(sock: Path, proc: subprocess.Popen, t0: float, timeout_s: float = 20.0) -> float:
    while time.perf_counter() - t0 < timeout_s:
        if proc.poll() is not None:
            o, e = proc.communicate()
            raise RuntimeError(f"VM exited early ({proc.returncode}): out={o!r} err={e!r}")
        if sock.exists():
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(1.0)
                s.connect(str(sock))
                s.sendall(b"GET /_ping HTTP/1.0\r\nHost: localhost\r\n\r\n")
                resp = s.recv(256)
                s.close()
                if b"200 OK" in resp and b"OK" in resp:
                    return (time.perf_counter() - t0) * 1000.0
            except Exception:
                pass
        time.sleep(0.001)
    raise RuntimeError(f"Timed out waiting for docker /_ping on {sock}")


def parse_json_summary(stdout_text: str) -> dict:
    for line in reversed(stdout_text.strip().splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            return json.loads(line)
    raise RuntimeError(f"No JSON summary line found in VMM stdout: {stdout_text!r}")


def count_open_fds(pid: int) -> int:
    out = subprocess.check_output(["lsof", "-n", "-P", "-p", str(pid)], text=True, stderr=subprocess.DEVNULL)
    return max(0, len(out.strip().splitlines()) - 1)


def proc_cpu_seconds(pid: int) -> float:
    # `ps -o time=` is coarse; use `ps -o cputime=` or `python` / `ps -o %cpu=` over a window.
    # On macOS, `ps -o time=` has centisecond precision (MM:SS.cc).
    raw = subprocess.check_output(["ps", "-o", "time=", "-p", str(pid)], text=True).strip()
    parts = raw.split(":")
    if len(parts) == 2:
        return int(parts[0]) * 60.0 + float(parts[1])
    if len(parts) == 3:
        return int(parts[0]) * 3600.0 + int(parts[1]) * 60.0 + float(parts[2])
    return float(raw)


def measure_idle_cpu_pct(pid: int, window_s: float = 3.0) -> float:
    c0 = proc_cpu_seconds(pid)
    t0 = time.perf_counter()
    time.sleep(window_s)
    c1 = proc_cpu_seconds(pid)
    dt = time.perf_counter() - t0
    return round(((c1 - c0) / dt) * 100.0, 2)


def free_tcp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def launch_cold_hvf(
    kernel: Path,
    disk: Path,
    cand_tools: Path,
    workspace_host: Path,
    workspace_guest: Path,
    sock: Path,
    oci_sock: Path,
    idle_poll_us: int,
    extra_vmm_args: list[str] | None = None,
) -> subprocess.Popen:
    cmdline = (
        "quiet console=ttyAMA0 rcupdate.rcu_expedited=1 psi=1 "
        "cgroup.memory=nokmem,nosocket slab_min_order=2 swiotlb=noforce "
        "workqueue.power_efficient=1 micropod.ci_sched=hrtick-250us "
        "micropod.ci_wakeup=next-buddy,sync-colocate micropod.ci_sysctls=perf "
        f"micropod.ci_cc=cubic idle_poll_us={idle_poll_us} "
        f"mp.mtu=9000 mp.workspace={workspace_guest}"
    )
    cmd = [
        str(bet.DEFAULT_HVF_BIN),
        "--kernel", str(kernel),
        "--initrd", str(bet.DEFAULT_HVF_INITRD),
        "--disk", str(disk),
        "--cpus", "4",
        "--memory-mib", "4096",
        "--cmdline", cmdline,
        "--published-net", "--published-mtu", "9000",
        "--share", f"oci-tools:{cand_tools}:ro",
        "--share", f"workspace:{workspace_host}",
        "--vsock-expose", f"{sock}:2375",
        "--vsock-expose", f"{oci_sock}:2376",
        "--quiet",
        "--json-summary",
    ]
    if extra_vmm_args:
        cmd.extend(extra_vmm_args)
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def stop_gracefully(proc: subprocess.Popen, timeout_s: float = 8.0) -> tuple[float, dict, str]:
    t0 = time.perf_counter()
    proc.terminate()
    try:
        out, err = proc.communicate(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
        raise RuntimeError(f"VMM did not exit within {timeout_s}s after SIGTERM: err={err!r}")
    elapsed_ms = round((time.perf_counter() - t0) * 1000.0, 2)
    if proc.returncode != 0:
        raise RuntimeError(f"VMM exited non-zero ({proc.returncode}): out={out!r} err={err!r}")
    return elapsed_ms, parse_json_summary(out), err


def run_host_edit_visibility(sock: Path, host_ws: Path, guest_ws: Path) -> dict:
    """Verify all 4 POSIX host-edit visibility cases (size, held, replace, unlink) on a live share."""
    results = {}

    # 1. size: host appends bytes to file after guest read it
    f_size = host_ws / "vis_size.txt"
    f_size.write_text("alpha")
    script = (
        f"a=$(cat {guest_ws}/vis_size.txt); "
        f"echo READY_SIZE; "
        f"i=0; while [ $i -lt 200 ]; do "
        f"  b=$(cat {guest_ws}/vis_size.txt); "
        f"  if [ \"$b\" = \"alpha-beta\" ]; then echo SEEN_SIZE; exit 0; fi; "
        f"  usleep 10000; i=$((i+1)); "
        f"done; echo TIMEOUT_SIZE:$b; exit 1"
    )
    p = subprocess.Popen(
        ["docker", "--host", f"unix://{sock}", "run", "--rm", "-v", f"{guest_ws}:{guest_ws}",
         "alpine:3.23", "sh", "-c", script],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    t_mut = None
    seen_ms = None
    assert p.stdout is not None
    for line in p.stdout:
        s = line.strip()
        if s == "READY_SIZE":
            t_mut = time.perf_counter()
            f_size.write_text("alpha-beta")
        elif s == "SEEN_SIZE" and t_mut is not None:
            seen_ms = round((time.perf_counter() - t_mut) * 1000.0, 2)
    p.wait(timeout=15)
    assert p.returncode == 0 and seen_ms is not None, f"size visibility failed (rc={p.returncode})"
    results["size_ms"] = seen_ms

    # 2. held: guest keeps fd open while host replaces file atomically -> open fd keeps old inode, path sees new!
    f_held = host_ws / "vis_held.txt"
    f_held.write_text("old-inode-v1")
    script = (
        f"exec 3<{guest_ws}/vis_held.txt; "
        f"echo READY_HELD; "
        f"i=0; while [ $i -lt 200 ]; do "
        f"  cur=$(cat {guest_ws}/vis_held.txt); "
        f"  if [ \"$cur\" = \"new-inode-v2\" ]; then "
        f"    held=$(cat <&3); "
        f"    if [ \"$held\" = \"old-inode-v1\" ]; then echo SEEN_HELD; exit 0; fi; "
        f"    echo BAD_HELD:$held; exit 1; "
        f"  fi; "
        f"  usleep 10000; i=$((i+1)); "
        f"done; echo TIMEOUT_HELD; exit 1"
    )
    p = subprocess.Popen(
        ["docker", "--host", f"unix://{sock}", "run", "--rm", "-v", f"{guest_ws}:{guest_ws}",
         "alpine:3.23", "sh", "-c", script],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    t_mut = None
    seen_ms = None
    assert p.stdout is not None
    for line in p.stdout:
        s = line.strip()
        if s == "READY_HELD":
            t_mut = time.perf_counter()
            tmp = host_ws / "vis_held.txt.tmp"
            tmp.write_text("new-inode-v2")
            os.replace(tmp, f_held)
        elif s == "SEEN_HELD" and t_mut is not None:
            seen_ms = round((time.perf_counter() - t_mut) * 1000.0, 2)
    p.wait(timeout=15)
    assert p.returncode == 0 and seen_ms is not None, f"held visibility failed (rc={p.returncode})"
    results["held_ms"] = seen_ms

    # 3. replace: host atomically replaces file with same length different bytes
    f_rep = host_ws / "vis_replace.txt"
    f_rep.write_text("AAAA")
    script = (
        f"cat {guest_ws}/vis_replace.txt >/dev/null; "
        f"echo READY_REP; "
        f"i=0; while [ $i -lt 200 ]; do "
        f"  cur=$(cat {guest_ws}/vis_replace.txt); "
        f"  if [ \"$cur\" = \"BBBB\" ]; then echo SEEN_REP; exit 0; fi; "
        f"  usleep 10000; i=$((i+1)); "
        f"done; echo TIMEOUT_REP; exit 1"
    )
    p = subprocess.Popen(
        ["docker", "--host", f"unix://{sock}", "run", "--rm", "-v", f"{guest_ws}:{guest_ws}",
         "alpine:3.23", "sh", "-c", script],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    t_mut = None
    seen_ms = None
    assert p.stdout is not None
    for line in p.stdout:
        s = line.strip()
        if s == "READY_REP":
            t_mut = time.perf_counter()
            tmp = host_ws / "vis_replace.txt.tmp"
            tmp.write_text("BBBB")
            os.replace(tmp, f_rep)
        elif s == "SEEN_REP" and t_mut is not None:
            seen_ms = round((time.perf_counter() - t_mut) * 1000.0, 2)
    p.wait(timeout=15)
    assert p.returncode == 0 and seen_ms is not None, f"replace visibility failed (rc={p.returncode})"
    results["replace_ms"] = seen_ms

    # 4. unlink: host deletes file -> guest immediately sees ENOENT
    f_un = host_ws / "vis_unlink.txt"
    f_un.write_text("ephemeral")
    script = (
        f"cat {guest_ws}/vis_unlink.txt >/dev/null; "
        f"echo READY_UN; "
        f"i=0; while [ $i -lt 200 ]; do "
        f"  if [ ! -e {guest_ws}/vis_unlink.txt ]; then echo SEEN_UN; exit 0; fi; "
        f"  usleep 10000; i=$((i+1)); "
        f"done; echo TIMEOUT_UN; exit 1"
    )
    p = subprocess.Popen(
        ["docker", "--host", f"unix://{sock}", "run", "--rm", "-v", f"{guest_ws}:{guest_ws}",
         "alpine:3.23", "sh", "-c", script],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    t_mut = None
    seen_ms = None
    assert p.stdout is not None
    for line in p.stdout:
        s = line.strip()
        if s == "READY_UN":
            t_mut = time.perf_counter()
            f_un.unlink()
        elif s == "SEEN_UN" and t_mut is not None:
            seen_ms = round((time.perf_counter() - t_mut) * 1000.0, 2)
    p.wait(timeout=15)
    assert p.returncode == 0 and seen_ms is not None, f"unlink visibility failed (rc={p.returncode})"
    results["unlink_ms"] = seen_ms
    results["passed"] = 4
    return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--kernel", type=Path, default=B5_KERNEL)
    ap.add_argument("--idle-poll-us", type=int, default=150)
    ap.add_argument("--clock-pause-secs", type=float, default=5.0)
    args = ap.parse_args()

    work = Path(tempfile.mkdtemp(prefix="mp-prod-qual-", dir="/private/tmp"))
    active_procs: list[subprocess.Popen] = []
    try:
        # Gate 7: Packaging & codesign readiness check
        print("[Gate 7] Verifying signed micropod-vmm binary & initrd...", flush=True)
        subprocess.run(["codesign", "--verify", "--strict", str(bet.DEFAULT_HVF_BIN)], check=True)
        ent = subprocess.check_output(
            ["codesign", "-d", "--entitlements", "-", str(bet.DEFAULT_HVF_BIN)],
            stderr=subprocess.STDOUT, text=True,
        )
        assert "com.apple.security.hypervisor" in ent, "missing hypervisor entitlement"
        initrd_bytes = bet.DEFAULT_HVF_INITRD.stat().st_size
        assert initrd_bytes > 500_000, f"initrd unexpectedly small: {initrd_bytes}"
        gate7 = {
            "pass": True,
            "vmm_binary": str(bet.DEFAULT_HVF_BIN),
            "codesign_strict_ok": True,
            "hypervisor_entitlement_ok": True,
            "initrd_bytes": initrd_bytes,
        }

        img_tar = work / "images.tar"
        bet.run(
            ["docker", "--host", f"unix://{bet.ORB_SOCK}", "save", "-o", str(img_tar),
             "registry.k8s.io/pause:3.10.2", "alpine:3.23"],
            timeout=120,
        )
        base_tools = bet.AUTH_PRODUCT_DIR / "micropod-oci-tools"
        if not base_tools.exists():
            base_tools = bet.DEFAULT_PRODUCT_DIR / "micropod-oci-tools"
        cand_tools = work / "tools"
        bet.stage_oci_tools(base_tools, cand_tools, rebuild_runner=False)

        # Shared guest mountpath (used for cross-workspace fork test!)
        ws_base = work / "ws-base"
        ws_fork = work / "ws-fork"
        ws_base.mkdir()
        ws_fork.mkdir()
        (ws_base / "shared.txt").write_text("base-content")
        (ws_base / "base_only.txt").write_text("only-in-base")
        (ws_fork / "shared.txt").write_text("fork-content")
        (ws_fork / "fork_only.txt").write_text("only-in-fork")

        # =====================================================================
        # Gate 1: Graceful SIGTERM Shutdown + Ext4 Persistence Across Restart
        # =====================================================================
        print("[Gate 1] Testing graceful SIGTERM guest flush & ext4 persistence...", flush=True)
        g1_home = work / "g1-home"
        g1_home.mkdir()
        g1_disk = work / "g1.ext4"
        subprocess.run(["cp", "-c", str(bet.DEFAULT_ALPINE_EXT4), str(g1_disk)], check=True)
        g1_sock = g1_home / "docker.sock"
        g1_oci = g1_home / "oci.sock"

        t0 = time.perf_counter()
        p1 = launch_cold_hvf(args.kernel, g1_disk, cand_tools, ws_base, ws_base, g1_sock, g1_oci, args.idle_poll_us)
        active_procs.append(p1)
        g1_boot1_ms = round(wait_docker_ping(g1_sock, p1, t0), 2)
        bet.load_images(g1_sock, img_tar)

        # Create persistent named container + write state on ext4
        bet.docker(
            g1_sock, "run", "--name", "persist-check-b6",
            "alpine:3.23", "sh", "-c", "echo PERSIST_OK > /persist_marker && sync",
            timeout=20,
        )
        # Touch base workspace files too so FUSE node table is populated before snapshot later
        r_ws = bet.docker(
            g1_sock, "run", "--rm", "-v", f"{ws_base}:{ws_base}",
            "alpine:3.23", "sh", "-c", f"cat {ws_base}/shared.txt {ws_base}/base_only.txt",
            timeout=15,
        )
        assert "base-content" in r_ws.stdout and "only-in-base" in r_ws.stdout

        g1_shutdown_ms, g1_summary, _ = stop_gracefully(p1)
        active_procs.remove(p1)
        assert g1_summary["exit_reason"] == "poweroff", f"Expected clean poweroff, got {g1_summary['exit_reason']!r}"

        # Relaunch on the SAME ext4 disk and take snapshot while verifying persisted container!
        snap_dir = work / "snap"
        trig_path = work / "snap.trigger"
        t0 = time.perf_counter()
        p1b = launch_cold_hvf(
            args.kernel, g1_disk, cand_tools, ws_base, ws_base, g1_sock, g1_oci, args.idle_poll_us,
            extra_vmm_args=[
                "--snapshot-trigger", str(trig_path),
                "--snapshot-out", str(snap_dir),
                "--snapshot-and-exit",
            ],
        )
        active_procs.append(p1b)
        g1_reboot_ms = round(wait_docker_ping(g1_sock, p1b, t0), 2)
        names_after = bet.docker(g1_sock, "ps", "-a", "--format", "{{.Names}}", timeout=15).stdout.strip().splitlines()
        assert "persist-check-b6" in names_after, f"Persisted container missing after graceful reboot: {names_after}"
        # Warm workspace dentries right before snapshot to stress cross-workspace restore in Gate 3!
        r_ws2 = bet.docker(
            g1_sock, "run", "--rm", "-v", f"{ws_base}:{ws_base}",
            "alpine:3.23", "sh", "-c", f"cat {ws_base}/shared.txt && cat {ws_base}/base_only.txt",
            timeout=15,
        )
        assert "base-content" in r_ws2.stdout
        time.sleep(0.1)

        snap_wall_utc = time.time()
        t_snap = time.perf_counter()
        trig_path.write_text("go\n")
        out_s, err_s = p1b.communicate(timeout=30)
        active_procs.remove(p1b)
        assert p1b.returncode == 0, f"snapshot failed: {out_s}\n{err_s}"
        snap_summary = parse_json_summary(out_s)
        assert snap_summary["exit_reason"] == "snapshot_done"
        snap_ms = round((time.perf_counter() - t_snap) * 1000.0, 2)

        gate1 = {
            "pass": True,
            "cold_boot_ms": g1_boot1_ms,
            "graceful_sigterm_exit_reason": g1_summary["exit_reason"],
            "graceful_sigterm_shutdown_ms": g1_shutdown_ms,
            "reboot_ms": g1_reboot_ms,
            "persisted_container_verified": True,
            "snapshot_wall_ms": snap_ms,
        }
        print(f"  [PASS] Gate 1: exit_reason={g1_summary['exit_reason']} in {g1_shutdown_ms} ms, ext4 persisted", flush=True)

        # =====================================================================
        # Gate 2 & Gate 3: Clock Resync after Pause + Live TLS + Cross-Workspace Fork (4/4 POSIX)
        # =====================================================================
        print(f"[Gate 2 & 3] Waiting {args.clock_pause_secs}s to test post-restore clock resync, TLS & cross-workspace fork...", flush=True)
        time.sleep(args.clock_pause_secs)

        f_home = work / "fork-home"
        f_home.mkdir()
        f_disk = work / "fork.ext4"
        f_sock = f_home / "docker.sock"
        f_oci = f_home / "oci.sock"

        t_rf = time.perf_counter()
        pf = subprocess.Popen(
            [
                str(bet.DEFAULT_HVF_BIN),
                "--restore-from", str(snap_dir),
                "--disk", str(f_disk),
                "--published-net", "--published-mtu", "9000",
                "--share", f"oci-tools:{cand_tools}:ro",
                "--share", f"workspace:{ws_fork}",
                "--vsock-expose", f"{f_sock}:2375",
                "--vsock-expose", f"{f_oci}:2376",
                "--quiet",
                "--json-summary",
            ],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        active_procs.append(pf)
        fork_ping_ms = round(wait_docker_ping(f_sock, pf, t_rf), 2)

        # Gate 2a: Measure restored guest CLOCK_REALTIME vs host UTC
        host_utc_before = time.time()
        r_date = bet.docker(f_sock, "run", "--rm", "alpine:3.23", "date", "+%s", timeout=15)
        host_utc_after = time.time()
        guest_utc = int(r_date.stdout.strip())
        host_utc_mid = (host_utc_before + host_utc_after) / 2.0
        clock_drift_s = round(abs(guest_utc - host_utc_mid), 3)
        clock_jumped_forward_s = round(guest_utc - snap_wall_utc, 2)
        assert clock_drift_s <= 1.5, (
            f"Restored guest clock did NOT resync! guest={guest_utc} host={host_utc_mid:.1f} snap={snap_wall_utc:.1f}"
        )

        # Gate 2b: Live TLS HTTPS inside restored fork (verifies DNS + TCP + valid wall-clock for X.509!)
        r_tls = bet.docker(
            f_sock, "run", "--rm", "alpine:3.23",
            "sh", "-c", "wget -q -O - --timeout=10 https://cloudflare.com/cdn-cgi/trace | head -n 4",
            timeout=20,
        )
        assert r_tls.returncode == 0 and "fl=" in r_tls.stdout, f"Live TLS HTTPS failed: rc={r_tls.returncode} out={r_tls.stdout!r} err={r_tls.stderr!r}"

        gate2 = {
            "pass": True,
            "pause_before_restore_s": args.clock_pause_secs,
            "restore_to_docker_ping_ms": fork_ping_ms,
            "guest_clock_drift_vs_host_s": clock_drift_s,
            "guest_clock_advanced_past_snapshot_s": clock_jumped_forward_s,
            "live_tls_https_ok": True,
        }
        print(f"  [PASS] Gate 2: restore_ping={fork_ping_ms} ms, clock_drift={clock_drift_s}s (+{clock_jumped_forward_s}s vs snap), TLS HTTPS OK", flush=True)

        # Gate 3: Cross-workspace fork verification + 4/4 POSIX host-edit visibility on ws_fork!
        r_xws = bet.docker(
            f_sock, "run", "--rm", "-v", f"{ws_base}:{ws_base}",
            "alpine:3.23", "sh", "-c",
            f"shared=$(cat {ws_base}/shared.txt); "
            f"forkonly=$(cat {ws_base}/fork_only.txt); "
            f"if [ -e {ws_base}/base_only.txt ]; then base=PRESENT; else base=ABSENT; fi; "
            f"echo \"$shared|$forkonly|$base\"",
            timeout=15,
        )
        assert r_xws.stdout.strip() == "fork-content|only-in-fork|ABSENT", (
            f"Cross-workspace rebinding mismatch: {r_xws.stdout!r}"
        )
        vis = run_host_edit_visibility(f_sock, ws_fork, ws_base)
        gate3 = {
            "pass": True,
            "cross_workspace_isolation_ok": True,
            "host_edit_visibility": vis,
        }
        print(f"  [PASS] Gate 3: cross-workspace isolated + 4/4 POSIX visibility ({vis})", flush=True)

        # =====================================================================
        # Gate 5: eth0 Egress Isolation + 200-Query UDP DNS Churn FD Hygiene
        # =====================================================================
        print("[Gate 5] Testing eth0 egress isolation & 200-query DNS churn FD hygiene...", flush=True)
        r_blk = bet.docker(
            f_sock, "run", "--rm", "alpine:3.23",
            "sh", "-c",
            "wget -q -T 2 -O /dev/null http://127.0.0.1:80/ 2>/dev/null && echo LOOPBACK_LEAK || echo LOOPBACK_BLOCKED; "
            "wget -q -T 2 -O /dev/null http://169.254.169.254/latest/meta-data/ 2>/dev/null && echo META_LEAK || echo META_BLOCKED",
            timeout=15,
        )
        assert "LOOPBACK_BLOCKED" in r_blk.stdout and "META_BLOCKED" in r_blk.stdout, (
            f"Egress isolation failed: {r_blk.stdout!r}"
        )

        fds_before = count_open_fds(pf.pid)
        r_dns = bet.docker(
            f_sock, "run", "--rm", "alpine:3.23",
            "sh", "-c",
            "ok=0; for i in $(seq 1 200); do "
            "  nslookup -type=A cloudflare.com 10.42.0.1 >/dev/null 2>&1 && ok=$((ok+1)); "
            "done; echo DNS_OK=$ok",
            timeout=60,
        )
        dns_ok = 0
        for tok in r_dns.stdout.split():
            if tok.startswith("DNS_OK="):
                dns_ok = int(tok.split("=", 1)[1])
        assert dns_ok >= 195, f"DNS churn had too many failures: {dns_ok}/200 ({r_dns.stdout!r})"
        fds_peak = count_open_fds(pf.pid)
        time.sleep(6.5)  # Allow 5s DNS post-reply GC sweep to reclaim completed UDP FDs
        fds_after = count_open_fds(pf.pid)
        fd_delta = fds_after - fds_before
        assert fd_delta <= 15, f"Host FD leak after DNS churn: before={fds_before} peak={fds_peak} after={fds_after}"

        gate5 = {
            "pass": True,
            "loopback_blocked": True,
            "link_local_metadata_blocked": True,
            "dns_churn_ok": dns_ok,
            "dns_churn_total": 200,
            "host_fds_before": fds_before,
            "host_fds_peak": fds_peak,
            "host_fds_after_gc": fds_after,
            "host_fd_delta_after_gc": fd_delta,
        }
        print(f"  [PASS] Gate 5: isolation OK, DNS {dns_ok}/200, FDs {fds_before} -> {fds_peak} -> {fds_after} (delta {fd_delta:+d})", flush=True)

        # =====================================================================
        # Gate 6: 24-Way Concurrency + OOMKilled=true (137) + Published TCP + Idle CPU
        # =====================================================================
        print("[Gate 6] Testing 24-way concurrency, cgroup OOM(137), published TCP, and idle CPU...", flush=True)
        t_conc = time.perf_counter()
        with concurrent.futures.ThreadPoolExecutor(max_workers=24) as ex:
            futs = [
                ex.submit(bet.docker, f_sock, "run", "--rm", "alpine:3.23", "sh", "-c", f"echo C{i}", timeout=30)
                for i in range(24)
            ]
            conc_ok = sum(1 for i, f in enumerate(futs) if f"C{i}" in f.result().stdout)
        conc_ms = round((time.perf_counter() - t_conc) * 1000.0, 1)
        assert conc_ok == 24, f"Concurrency failed: {conc_ok}/24"

        # Cgroup v2 OOM check: allocate > 64 MiB anonymous RAM inside a 32 MiB cgroup limit
        oom_name = "oom-qual-b6"
        r_oom = subprocess.run(
            ["docker", "--host", f"unix://{f_sock}", "run", "--name", oom_name, "--memory", "32m",
             "alpine:3.23", "awk", "BEGIN{s=\"A\"; for(i=0;i<27;i++) s=s s; print length(s)}"],
            capture_output=True, text=True, timeout=20,
        )
        insp = json.loads(bet.docker(f_sock, "inspect", oom_name, timeout=10).stdout)[0]
        oom_killed = bool(insp["State"].get("OOMKilled"))
        oom_exit = int(insp["State"].get("ExitCode", -1))
        bet.docker(f_sock, "rm", "-f", oom_name, timeout=10)
        assert oom_killed and oom_exit == 137, f"OOM check failed: OOMKilled={oom_killed} ExitCode={oom_exit} rc={r_oom.returncode}"

        # Published TCP port check (host -> guest container over eth1 macvlan + port broker)
        pub_port = free_tcp_port()
        pub_name = "pub-qual-b6"
        bet.docker(
            f_sock, "run", "-d", "--name", pub_name, "-p", f"127.0.0.1:{pub_port}:8080",
            "alpine:3.23", "sh", "-c",
            "while true; do printf 'HTTP/1.0 200 OK\\r\\nContent-Length: 10\\r\\n\\r\\nPUB_B6_OK\\n' | nc -l -p 8080; done",
            timeout=15,
        )
        pub_ok = False
        try:
            deadline = time.perf_counter() + 10.0
            while time.perf_counter() < deadline:
                try:
                    with socket.create_connection(("127.0.0.1", pub_port), timeout=1.0) as s:
                        s.sendall(b"GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
                        body = s.recv(512)
                        if b"PUB_B6_OK" in body:
                            pub_ok = True
                            break
                except Exception:
                    time.sleep(0.05)
        finally:
            bet.docker(f_sock, "rm", "-f", pub_name, timeout=10)
        assert pub_ok, "Published TCP port check failed"

        # Idle host CPU check after workload drains
        time.sleep(2.5)
        idle_cpu_pct = measure_idle_cpu_pct(pf.pid, window_s=3.0)
        assert idle_cpu_pct <= 2.5, f"Idle host CPU too high: {idle_cpu_pct}%"

        # Graceful SIGTERM shutdown of the restored fork!
        fork_shutdown_ms, fork_summary, _ = stop_gracefully(pf)
        active_procs.remove(pf)
        assert fork_summary["exit_reason"] == "poweroff", (
            f"Restored fork did not poweroff cleanly: {fork_summary['exit_reason']!r}"
        )

        gate6 = {
            "pass": True,
            "concurrent_24_ok": conc_ok,
            "concurrent_24_wall_ms": conc_ms,
            "oom_killed": oom_killed,
            "oom_exit_code": oom_exit,
            "published_tcp_ok": pub_ok,
            "idle_host_cpu_pct": idle_cpu_pct,
            "restored_fork_graceful_exit_reason": fork_summary["exit_reason"],
            "restored_fork_graceful_shutdown_ms": fork_shutdown_ms,
        }
        print(f"  [PASS] Gate 6: 24/24 ({conc_ms} ms), OOM=137, pubTCP=OK, idleCPU={idle_cpu_pct}%, fork_poweroff={fork_shutdown_ms} ms", flush=True)

        # =====================================================================
        # Gate 4: Snapshot Integrity & Fail-Fast Error Handling
        # =====================================================================
        print("[Gate 4] Testing snapshot CRC32 corruption & device topology mismatch rejection...", flush=True)
        bad_snap = work / "snap-corrupt"
        shutil.copytree(snap_dir, bad_snap)
        vs_path = bad_snap / "vmstate.bin"
        raw_vs = bytearray(vs_path.read_bytes())
        raw_vs[32] ^= 0x55
        vs_path.write_bytes(raw_vs)

        r_crc = subprocess.run(
            [
                str(bet.DEFAULT_HVF_BIN),
                "--restore-from", str(bad_snap),
                "--disk", str(work / "bad1.ext4"),
                "--published-net", "--published-mtu", "9000",
                "--share", f"oci-tools:{cand_tools}:ro",
                "--share", f"workspace:{ws_fork}",
                "--vsock-expose", f"{work}/bad1.sock:2375",
                "--vsock-expose", f"{work}/bad1o.sock:2376",
            ],
            capture_output=True, text=True, timeout=10,
        )
        assert r_crc.returncode != 0 and "CRC32" in r_crc.stderr, (
            f"Expected CRC32 rejection, got rc={r_crc.returncode} err={r_crc.stderr!r}"
        )

        # Missing --published-net -> device count mismatch
        r_cnt = subprocess.run(
            [
                str(bet.DEFAULT_HVF_BIN),
                "--restore-from", str(snap_dir),
                "--disk", str(work / "bad2.ext4"),
                "--share", f"oci-tools:{cand_tools}:ro",
                "--share", f"workspace:{ws_fork}",
                "--vsock-expose", f"{work}/bad2.sock:2375",
                "--vsock-expose", f"{work}/bad2o.sock:2376",
            ],
            capture_output=True, text=True, timeout=10,
        )
        assert r_cnt.returncode != 0 and "device count mismatch" in r_cnt.stderr, (
            f"Expected device count mismatch, got rc={r_cnt.returncode} err={r_cnt.stderr!r}"
        )

        # Same count, wrong slot device_id (--no-balloon + extra share) -> slot device mismatch
        extra_share = work / "extra-share"
        extra_share.mkdir()
        r_slot = subprocess.run(
            [
                str(bet.DEFAULT_HVF_BIN),
                "--restore-from", str(snap_dir),
                "--disk", str(work / "bad3.ext4"),
                "--no-balloon",
                "--published-net", "--published-mtu", "9000",
                "--share", f"oci-tools:{cand_tools}:ro",
                "--share", f"workspace:{ws_fork}",
                "--share", f"extra:{extra_share}:ro",
                "--vsock-expose", f"{work}/bad3.sock:2375",
                "--vsock-expose", f"{work}/bad3o.sock:2376",
            ],
            capture_output=True, text=True, timeout=10,
        )
        assert r_slot.returncode != 0 and "device mismatch" in r_slot.stderr, (
            f"Expected slot device mismatch, got rc={r_slot.returncode} err={r_slot.stderr!r}"
        )

        gate4 = {
            "pass": True,
            "crc32_corruption_rejected": True,
            "device_count_mismatch_rejected": True,
            "slot_device_id_mismatch_rejected": True,
        }
        print("  [PASS] Gate 4: CRC32 + count mismatch + slot ID mismatch all rejected cleanly", flush=True)

        report = {
            "label": "phase-b6-production-qualification",
            "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "kernel": str(args.kernel),
            "idle_poll_us": args.idle_poll_us,
            "all_gates_passed": True,
            "gates": {
                "gate1_graceful_shutdown_and_persistence": gate1,
                "gate2_restore_clock_resync_and_tls": gate2,
                "gate3_cross_workspace_fork_and_posix_visibility": gate3,
                "gate4_snapshot_integrity_and_validation": gate4,
                "gate5_egress_isolation_and_dns_fd_hygiene": gate5,
                "gate6_concurrency_oom_published_tcp_and_idle_cpu": gate6,
                "gate7_signing_and_packaging_readiness": gate7,
            },
        }
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2) + "\n")
        print("\n=== ALL 7 PRODUCTION QUALIFICATION GATES PASSED ===", flush=True)
        print(json.dumps(report, indent=2), flush=True)
        print(f"\nSaved receipt to {args.out}", flush=True)
    finally:
        for p in active_procs:
            if p.poll() is None:
                p.kill()
                p.wait()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
