#!/usr/bin/env python3
"""Phase B7: Real-world CI jobs, BuildKit/scoped/volume/workspace caching, restart persistence,
and managed APFS CoW snapshot pool inheritance on the packaged Micropod HVF release CLI."""

import argparse
import concurrent.futures
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
MP_CLI = DIST / "micropod"
ORB_SOCK = Path.home() / ".orbstack/run/docker.sock"


def free_tcp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def run_cmd(
    args: list[str],
    env: dict[str, str] | None = None,
    cwd: Path | None = None,
    timeout: int = 180,
    check: bool = True,
) -> subprocess.CompletedProcess:
    res = subprocess.run(
        args,
        env=env,
        cwd=str(cwd) if cwd else None,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if check and res.returncode != 0:
        raise RuntimeError(
            f"Command failed (rc={res.returncode}): {' '.join(args)}\n"
            f"STDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}"
        )
    return res


def base_ci_env(home: Path, workspace: Path | None = None, extra: dict[str, str] | None = None) -> dict[str, str]:
    """Zero-config HVF environment: NO MICROPOD_CI_HVF_BIN, INITRD, KERNEL, or OCI_TOOLS overrides!"""
    env = {
        k: v
        for k, v in os.environ.items()
        if not k.startswith("MICROPOD_")
        and k not in ("DOCKER_HOST", "DOCKER_CONTEXT", "BUILDX_BUILDER")
    }
    env["MICROPOD_CI_HOME"] = str(home)
    env["MICROPOD_CI_VMM"] = "hvf"
    env["MICROPOD_CI_ENGINE"] = "containerd"
    env["MICROPOD_CI_CPUS"] = "4"
    env["MICROPOD_CI_MEMORY_MIB"] = "4096"
    env["MICROPOD_CI_PUBLISHED_PATH"] = "macvlan"
    env["MICROPOD_CI_PUBLISHED_MTU"] = "9000"
    if workspace is not None:
        env["MICROPOD_CI_WORKSPACE"] = str(workspace)
    if extra:
        env.update(extra)
    return env


def wait_http_ok(url: str, timeout_s: float = 15.0) -> tuple[int, str]:
    deadline = time.perf_counter() + timeout_s
    last_err = None
    while time.perf_counter() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2.0) as resp:
                return resp.status, resp.read().decode("utf-8", errors="replace")
        except Exception as e:
            last_err = e
            time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for HTTP {url}: {last_err}")


class LocalOTLPCollector:
    """In-process OTLP/HTTP JSON metrics receiver to verify live OTLP push exports end-to-end."""

    def __init__(self):
        self.received: list[dict] = []
        self._lock = threading.Lock()
        parent = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length)
                try:
                    parsed = json.loads(body.decode("utf-8"))
                    with parent._lock:
                        parent.received.append({"path": self.path, "payload": parsed})
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(b"{}")
                except Exception as exc:
                    self.send_response(400)
                    self.end_headers()
                    self.wfile.write(str(exc).encode("utf-8"))

            def log_message(self, format, *args):
                return

        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self._server.server_address[1]
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    @property
    def endpoint(self) -> str:
        return f"http://127.0.0.1:{self.port}/v1/metrics"

    @property
    def traces_endpoint(self) -> str:
        return f"http://127.0.0.1:{self.port}/v1/traces"

    def snapshot(self) -> list[dict]:
        with self._lock:
            return list(self.received)

    def close(self):
        self._server.shutdown()
        self._server.server_close()


def create_sample_projects(work: Path) -> dict[str, Path]:
    """Create realistic multi-file C/BuildKit, Node.js, Go, and Compose CI project repos."""
    # 1. Multi-stage BuildKit C microservice project
    bk_dir = work / "repo-buildkit-c"
    (bk_dir / "src").mkdir(parents=True)
    (bk_dir / ".dockerignore").write_text(".git\n*.tmp\n")
    (bk_dir / "src/version.h").write_text('#define APP_VERSION "1.0.0-cold"\n')
    (bk_dir / "src/main.c").write_text(textwrap.dedent("""\
        #include <stdio.h>
        #include "version.h"
        int compute_checksum(int n);
        int main(void) {
            printf("APP_VERSION=%s CHECKSUM=%d\\n", APP_VERSION, compute_checksum(100));
            return 0;
        }
    """))
    (bk_dir / "src/math_ops.c").write_text(textwrap.dedent("""\
        int compute_checksum(int n) {
            int s = 0;
            for (int i = 1; i <= n; i++) s += i * 3;
            return s;
        }
    """))
    (bk_dir / "Dockerfile").write_text(textwrap.dedent("""\
        # syntax=docker/dockerfile:1.7
        FROM alpine:3.23 AS builder
        RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \\
            apk add --cache-dir /var/cache/apk gcc musl-dev
        WORKDIR /src
        COPY src/ ./src/
        RUN gcc -O2 -Wall -Werror -o /out_app src/main.c src/math_ops.c && /out_app

        FROM alpine:3.23
        COPY --from=builder /out_app /usr/local/bin/app
        ENTRYPOINT ["/usr/local/bin/app"]
    """))

    # 2. Node.js 24 project with native node --test suite + package.json
    node_dir = work / "repo-node-ci"
    (node_dir / "src").mkdir(parents=True)
    (node_dir / "test").mkdir(parents=True)
    (node_dir / "package.json").write_text(json.dumps({
        "name": "micropod-ci-node-demo",
        "version": "1.0.0",
        "type": "module",
        "scripts": {"test": "node --test test/*.test.mjs"},
    }, indent=2) + "\n")
    (node_dir / "src/calc.mjs").write_text(textwrap.dedent("""\
        export function fib(n) {
            let a = 0, b = 1;
            for (let i = 0; i < n; i++) [a, b] = [b, a + b];
            return a;
        }
        export function buildTag() { return "node-v1"; }
    """))
    (node_dir / "test/calc.test.mjs").write_text(textwrap.dedent("""\
        import test from 'node:test';
        import assert from 'node:assert/strict';
        import { fib, buildTag } from '../src/calc.mjs';

        test('fibonacci sequence', () => {
            assert.equal(fib(0), 0);
            assert.equal(fib(10), 55);
            assert.equal(fib(20), 6765);
        });
        test('build tag matches', () => {
            assert.equal(buildTag(), 'node-v1');
        });
    """))

    # 3. Multi-module C workspace for Virtio-FS incremental Make rebuild coherency
    inc_dir = work / "repo-incremental-make"
    inc_dir.mkdir(parents=True)
    mod_names = []
    for i in range(16):
        name = f"mod_{i:02d}"
        mod_names.append(name)
        (inc_dir / f"{name}.c").write_text(f"int fn_{name}(void) {{ return {i + 1}; }}\n")
    decls = "\n".join(f"int fn_{m}(void);" for m in mod_names)
    calls = " + ".join(f"fn_{m}()" for m in mod_names)
    (inc_dir / "main.c").write_text(textwrap.dedent(f"""\
        #include <stdio.h>
        {decls}
        int main(void) {{
            printf("SUM=%d\\n", {calls});
            return 0;
        }}
    """))
    objs = " ".join(f"{m}.o" for m in mod_names) + " main.o"
    (inc_dir / "Makefile").write_text(
        f"OBJS = {objs}\n"
        "app: $(OBJS)\n"
        "\tgcc -O2 -o app $(OBJS)\n"
        "%.o: %.c\n"
        "\t@echo COMPILED:$<\n"
        "\tgcc -O2 -c $< -o $@\n"
    )

    # 4. Multi-service Docker Compose project (Postgres 16 + Node 24 HTTP API + integration tester)
    compose_dir = work / "repo-compose-pg"
    compose_dir.mkdir(parents=True)
    (compose_dir / "init.sql").write_text(textwrap.dedent("""\
        CREATE TABLE IF NOT EXISTS ci_runs (
            id SERIAL PRIMARY KEY,
            job_name TEXT NOT NULL,
            status TEXT NOT NULL
        );
        INSERT INTO ci_runs (job_name, status) VALUES ('bootstrap', 'ok');
    """))
    (compose_dir / "api.mjs").write_text(textwrap.dedent("""\
        import http from 'node:http';
        import net from 'node:net';

        const pgHost = process.env.PGHOST || 'db';
        const pgPort = Number(process.env.PGPORT || 5432);

        function checkTcp(host, port) {
            return new Promise((resolve, reject) => {
                const s = net.createConnection({ host, port, timeout: 2000 }, () => {
                    s.end();
                    resolve(true);
                });
                s.on('error', reject);
                s.on('timeout', () => { s.destroy(); reject(new Error('timeout')); });
            });
        }

        const server = http.createServer(async (req, res) => {
            try {
                await checkTcp(pgHost, pgPort);
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ ok: true, db_host: pgHost, db_port: pgPort, path: req.url }));
            } catch (err) {
                res.writeHead(503, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ ok: false, error: String(err) }));
            }
        });
        server.listen(8080, '0.0.0.0', () => console.log('API_LISTENING_8080'));
    """))

    return {
        "buildkit": bk_dir,
        "node": node_dir,
        "incremental": inc_dir,
        "compose": compose_dir,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    assert MP_CLI.exists(), f"Packaged CLI missing at {MP_CLI}; run scripts/package_app.sh first"
    for req_art in ("micropod-vmm", "mp-hvf-init.cpio", "vmlinux-hvf", "micropod-oci", "micropod-oci-tools"):
        assert (DIST / req_art).exists(), f"Missing packaged HVF artifact: {DIST / req_art}"

    work = Path(tempfile.mkdtemp(prefix="mp-b7-ci-", dir="/private/tmp"))
    active_homes: list[dict[str, str]] = []
    otlp_collector = LocalOTLPCollector()
    try:
        prom_port = free_tcp_port()
        obs_yaml_main = work / "observability.yaml"
        obs_yaml_pool = work / "observability-pool.yaml"
        obs_yaml_pool.write_text(textwrap.dedent(f"""\
            schema: 1
            service_name: micropod-b7-pool
            prometheus:
              enabled: true
              path: /metrics
            otlp:
              enabled: true
              endpoint: {otlp_collector.endpoint}
              export_interval_secs: 2
              resource_attributes:
                deployment.environment: gamma-pool
            tracing:
              enabled: true
              endpoint: {otlp_collector.traces_endpoint}
              sample_rate: 1.0
              slow_op_threshold_ms: 5
            health:
              memory_warn_pct: 90
              vmm_timeout_ms: 2000
        """))

        repos = create_sample_projects(work)
        ws_root = work / "workspace"
        ws_root.mkdir()
        # Symlink/copy repos inside shared workspace so host edits propagate live via Virtio-FS
        for k, p in repos.items():
            shutil.move(str(p), str(ws_root / p.name))
            repos[k] = ws_root / p.name

        # Export common CI base images from local OrbStack cache once so runs are deterministic & fast
        print("[Setup] Saving local CI base images (alpine:3.23, node:24-alpine, postgres:16-alpine, pause)...", flush=True)
        img_tar = work / "ci-images.tar"
        run_cmd([
            "docker", "--host", f"unix://{ORB_SOCK}", "save", "-o", str(img_tar),
            "registry.k8s.io/pause:3.10.2", "alpine:3.23", "node:24-alpine", "postgres:16-alpine",
        ], timeout=180)

        # =====================================================================
        # 1. Clean CLI Config Management + Zero-Config Managed HVF Boot + On-Demand Tracing
        # =====================================================================
        print("[1/6] Configuring observability YAML via `micropod telemetry`, booting zero-config HVF...", flush=True)
        ci_home = work / "ci-home-main"
        env = base_ci_env(
            ci_home,
            workspace=ws_root,
            extra={"MICROPOD_OBSERVABILITY_CONFIG": str(obs_yaml_main)},
        )
        active_homes.append(env)

        # Manage YAML config purely via the clean `micropod telemetry` / `micropod config` CLI!
        run_cmd([str(MP_CLI), "telemetry", "init", str(obs_yaml_main)], env=env)
        run_cmd([str(MP_CLI), "config", "set", "service_name", "micropod-b7-e2e"], env=env)
        run_cmd([str(MP_CLI), "config", "set", "prometheus.listen", f"127.0.0.1:{prom_port}"], env=env)
        run_cmd([str(MP_CLI), "config", "set", "otlp.endpoint", otlp_collector.endpoint], env=env)
        run_cmd([str(MP_CLI), "config", "set", "otlp.export_interval_secs", "2"], env=env)
        run_cmd([str(MP_CLI), "config", "set", "otlp.resource_attributes.deployment.environment", "gamma-e2e"], env=env)
        run_cmd([str(MP_CLI), "config", "set", "tracing.endpoint", otlp_collector.traces_endpoint], env=env)
        run_cmd([str(MP_CLI), "telemetry", "enable", "otlp"], env=env)
        # Keep tracing OFF at boot to prove zero-overhead default + live runtime toggle later!
        run_cmd([str(MP_CLI), "telemetry", "disable", "tracing"], env=env)
        val_out = run_cmd([str(MP_CLI), "telemetry", "validate"], env=env).stdout
        assert "OK:" in val_out and "tracing=false" in val_out, val_out
        yaml_echo = run_cmd([str(MP_CLI), "telemetry", "show"], env=env).stdout
        assert "micropod-b7-e2e" in yaml_echo and str(prom_port) in yaml_echo, yaml_echo

        t0 = time.perf_counter()
        st_res = run_cmd([str(MP_CLI), "ci", "runner-start"], env=env, timeout=180)
        cold_start_ms = round((time.perf_counter() - t0) * 1000.0, 1)
        status_json = json.loads(st_res.stdout)
        docker_ep = run_cmd([str(MP_CLI), "ci", "runner-docker-endpoint"], env=env).stdout.strip()
        bk_ep = run_cmd([str(MP_CLI), "ci", "runner-buildkit-endpoint"], env=env).stdout.strip()
        kernel_metrics = json.loads(run_cmd([str(MP_CLI), "ci", "metrics", "--kernel"], env=env).stdout)

        # Confirm ZERO metric files exist on disk (pure live Unix telemetry.sock + Prometheus + OTLP!)
        assert not (ci_home / "vmm-health.json").exists(), "unexpected static metric file found on disk!"
        assert (ci_home / "telemetry.sock").exists(), "live telemetry.sock missing!"

        def sample_health(stage: str, target_env: dict[str, str], allow_degraded: bool = False) -> dict:
            h = json.loads(run_cmd([str(MP_CLI), "telemetry", "health"], env=target_env).stdout)
            hv = h.get("hypervisor")
            assert hv is not None, f"[{stage}] missing live HVF hypervisor telemetry: {h}"
            assert hv["state"] == "running", f"[{stage}] unexpected hypervisor state: {hv}"
            assert hv["guestCtrlConnected"] is True, f"[{stage}] guest control channel disconnected: {hv}"
            assert hv["hostPhysFootprintMib"] > 0, f"[{stage}] invalid footprint: {hv}"
            assert h["engine"]["vmm"] == "hvf", f"[{stage}] wrong vmm: {h['engine']}"
            assert h["engine"]["buildkitAvailable"] is True, f"[{stage}] buildkit not available: {h['engine']}"
            if not allow_degraded:
                assert h["verdict"] == "healthy", f"[{stage}] expected healthy verdict, got {h['verdict']}: {h['warnings']}"
            return h

        health_timeline: dict[str, dict] = {}
        health_timeline["boot_idle"] = sample_health("boot_idle", env)

        # Verify live Prometheus TCP scrape directly from micropod-vmm AND unified `micropod telemetry metrics`!
        prom_status, prom_vmm_body = wait_http_ok(f"http://127.0.0.1:{prom_port}/metrics", timeout_s=5.0)
        assert prom_status == 200 and "micropod_vmm_up" in prom_vmm_body and "micropod_vmm_guest_ctrl_connected 1" in prom_vmm_body, prom_vmm_body
        prom_unified = run_cmd([str(MP_CLI), "telemetry", "metrics", "--format", "prometheus"], env=env).stdout
        assert "micropod_vmm_host_phys_footprint_bytes" in prom_unified and "micropod_engine_health_status" in prom_unified, prom_unified
        otlp_unified = json.loads(run_cmd([str(MP_CLI), "telemetry", "metrics", "--format", "otlp"], env=env).stdout)
        assert "resourceMetrics" in otlp_unified, otlp_unified

        # Verify ON-DEMAND live tracing toggle on the running worker with ZERO VM restart!
        tr_off = json.loads(run_cmd([str(MP_CLI), "telemetry", "trace", "status"], env=env).stdout)
        assert tr_off["enabled"] is False and tr_off["recorded_spans"] == 0, tr_off
        tr_on = json.loads(run_cmd([str(MP_CLI), "telemetry", "trace", "enable"], env=env).stdout)
        assert tr_on["enabled"] is True and tr_on["recorded_spans"] >= 1, tr_on
        tr_dump = json.loads(run_cmd([str(MP_CLI), "telemetry", "trace", "dump"], env=env).stdout)
        assert "resourceSpans" in tr_dump, tr_dump
        tr_summary = run_cmd([str(MP_CLI), "telemetry", "trace", "dump", "--summary"], env=env).stdout
        assert "vmm.tracing.enabled" in tr_summary, tr_summary
        tr_dis = json.loads(run_cmd([str(MP_CLI), "telemetry", "trace", "disable"], env=env).stdout)
        assert tr_dis["enabled"] is False, tr_dis

        print(
            f"  [PASS] Zero-config HVF started in {cold_start_ms} ms "
            f"(verdict={health_timeline['boot_idle']['verdict']}, "
            f"phys={health_timeline['boot_idle']['hypervisor']['hostPhysFootprintMib']} MiB, "
            f"prom=127.0.0.1:{prom_port}/metrics OK, otlp=OK, live_trace_toggle=OK, metric_files=0)",
            flush=True,
        )

        # Load base images into the managed HVF worker
        t_load = time.perf_counter()
        run_cmd([str(MP_CLI), "ci", "docker", "load", "-i", str(img_tar)], env=env, timeout=180)
        load_ms = round((time.perf_counter() - t_load) * 1000.0, 1)

        # =====================================================================
        # 2. Real CI Job #1: Multi-Stage BuildKit Build & Layer/Mount Cache Tests
        # =====================================================================
        print("[2/6] Running multi-stage BuildKit CI builds (cold vs warm hit vs partial edit vs mount cache)...", flush=True)
        bk_repo = repos["buildkit"]

        # 2a. Cold BuildKit build (pulls gcc/musl-dev via eth0 into --mount=type=cache,target=/var/cache/apk)
        t0 = time.perf_counter()
        r_bk_cold = run_cmd(
            [str(MP_CLI), "ci", "docker", "buildx", "build", "--load", "--progress=plain",
             "-t", "demo-app:v1", str(bk_repo)],
            env=env, timeout=180,
        )
        bk_cold_s = round(time.perf_counter() - t0, 3)
        r_run_v1 = run_cmd([str(MP_CLI), "ci", "docker", "run", "--rm", "demo-app:v1"], env=env)
        assert "APP_VERSION=1.0.0-cold CHECKSUM=15150" in r_run_v1.stdout, r_run_v1.stdout

        # 2b. Warm 100% cache-hit rebuild
        t0 = time.perf_counter()
        r_bk_warm = run_cmd(
            [str(MP_CLI), "ci", "docker", "buildx", "build", "--load", "--progress=plain",
             "-t", "demo-app:v1", str(bk_repo)],
            env=env, timeout=120,
        )
        bk_warm_s = round(time.perf_counter() - t0, 3)
        warm_cached_steps = (r_bk_warm.stdout + r_bk_warm.stderr).count("CACHED")
        assert warm_cached_steps >= 3, f"Expected >=3 CACHED BuildKit steps, got {warm_cached_steps}\n{r_bk_warm.stderr}"

        # 2c. Partial invalidation: edit src/version.h on host -> apk layer stays CACHED, only compile reruns!
        (bk_repo / "src/version.h").write_text('#define APP_VERSION "1.0.1-edited"\n')
        t0 = time.perf_counter()
        r_bk_partial = run_cmd(
            [str(MP_CLI), "ci", "docker", "buildx", "build", "--load", "--progress=plain",
             "-t", "demo-app:v2", str(bk_repo)],
            env=env, timeout=120,
        )
        bk_partial_s = round(time.perf_counter() - t0, 3)
        partial_log = r_bk_partial.stdout + r_bk_partial.stderr
        assert "CACHED" in partial_log, f"Expected apk base layer CACHED on partial edit:\n{partial_log}"
        r_run_v2 = run_cmd([str(MP_CLI), "ci", "docker", "run", "--rm", "demo-app:v2"], env=env)
        assert "APP_VERSION=1.0.1-edited CHECKSUM=15150" in r_run_v2.stdout, r_run_v2.stdout

        # 2d. BuildKit `micropod ci snapshot` reusable checkout image (cold vs warm hit)
        t0 = time.perf_counter()
        snap_img1 = run_cmd([str(MP_CLI), "ci", "snapshot", "node:24-alpine", str(repos["node"])], env=env).stdout.strip().splitlines()[-1]
        ci_snap_cold_s = round(time.perf_counter() - t0, 3)
        t0 = time.perf_counter()
        snap_img2 = run_cmd([str(MP_CLI), "ci", "snapshot", "node:24-alpine", str(repos["node"])], env=env).stdout.strip().splitlines()[-1]
        ci_snap_warm_s = round(time.perf_counter() - t0, 3)
        assert snap_img1 == snap_img2 and snap_img1.startswith("sha256:"), f"snapshot mismatch: {snap_img1} vs {snap_img2}"

        print(
            f"  [PASS] BuildKit: cold={bk_cold_s}s, warm_hit={bk_warm_s}s ({warm_cached_steps} CACHED), "
            f"partial_edit={bk_partial_s}s, ci_snapshot={ci_snap_cold_s}s->{ci_snap_warm_s}s",
            flush=True,
        )

        # =====================================================================
        # 3. Real CI Job #2: Node.js + Scoped Package Caches + Native OCI Job + Primed Pods
        # =====================================================================
        print("[3/6] Running Node.js CI job, scoped cache isolation, native OCI jobs & Virtio-FS incremental Make...", flush=True)
        node_repo = repos["node"]
        # Run Node.js test suite inside scoped npm cache volume AND verify cache persistence + scope isolation!
        r_node1 = run_cmd(
            [str(MP_CLI), "ci", "run", "--cache", "npm", "--cache-scope", "scope-alpha",
             "-v", f"{node_repo}:/work", "-w", "/work", "node:24-alpine",
             "sh", "-c", "npm test && echo ALPHA_CACHED_V1 > \"$npm_config_cache/marker.txt\""],
            env=env,
        )
        assert "pass 2" in r_node1.stdout or "tests 2" in r_node1.stdout, r_node1.stdout

        # Same scope sees marker; different scope does NOT!
        r_scope_hit = run_cmd(
            [str(MP_CLI), "ci", "run", "--cache", "npm", "--cache-scope", "scope-alpha",
             "node:24-alpine", "sh", "-c", "cat \"$npm_config_cache/marker.txt\""],
            env=env,
        )
        assert r_scope_hit.stdout.strip() == "ALPHA_CACHED_V1"

        r_scope_iso = run_cmd(
            [str(MP_CLI), "ci", "run", "--cache", "npm", "--cache-scope", "scope-beta",
             "node:24-alpine", "sh", "-c", "test ! -e \"$npm_config_cache/marker.txt\" && echo ISOLATED_OK"],
            env=env,
        )
        assert r_scope_iso.stdout.strip() == "ISOLATED_OK"

        # Python bytecode cache scope test
        r_py_cache = run_cmd(
            [str(MP_CLI), "ci", "run", "--cache", "python", "--cache-scope", "scope-py",
             "alpine:3.23", "sh", "-c", "echo PY_CACHE_READY > \"$PYTHONPYCACHEPREFIX/ok.txt\" && cat \"$PYTHONPYCACHEPREFIX/ok.txt\""],
            env=env,
        )
        assert r_py_cache.stdout.strip() == "PY_CACHE_READY"

        # Native OCI job + runner-prime + native scoped cache (MICROPOD_CI_CACHE_SCOPE)
        run_cmd([str(MP_CLI), "ci", "runner-prime", "4"], env=env)
        env_native_cache = dict(env, MICROPOD_CI_CACHE_SCOPE="native-scope-1")
        r_job1 = run_cmd(
            [str(MP_CLI), "ci", "job", "trusted", "docker.io/library/alpine:3.23",
             "sh", "-c", "echo NATIVE_GO_CACHE_OK > \"$GOCACHE/key.txt\" && echo JOB1_OK"],
            env=env_native_cache,
        )
        assert "JOB1_OK" in r_job1.stdout, r_job1.stdout
        r_job2 = run_cmd(
            [str(MP_CLI), "ci", "job", "trusted", "docker.io/library/alpine:3.23",
             "sh", "-c", "cat \"$GOCACHE/key.txt\""],
            env=env_native_cache,
        )
        assert "NATIVE_GO_CACHE_OK" in r_job2.stdout, r_job2.stdout

        # Real Virtio-FS incremental Make build (16 C modules) using our gcc toolchain image!
        # Build a reusable gcc toolchain image once (instantly hits cached apk layer from BuildKit!)
        tc_dir = work / "gcc-toolchain"
        tc_dir.mkdir()
        (tc_dir / "Dockerfile").write_text(textwrap.dedent("""\
            # syntax=docker/dockerfile:1.7
            FROM alpine:3.23
            RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \\
                apk add --cache-dir /var/cache/apk gcc musl-dev make
        """))
        run_cmd(
            [str(MP_CLI), "ci", "docker", "buildx", "build", "--load", "-t", "ci-gcc:local", str(tc_dir)],
            env=env, timeout=180,
        )
        inc_repo = repos["incremental"]
        t0 = time.perf_counter()
        r_mk1 = run_cmd(
            [str(MP_CLI), "ci", "docker", "run", "--rm", "-v", f"{inc_repo}:/src", "-w", "/src",
             "ci-gcc:local", "sh", "-c", "make -j4 && ./app"],
            env=env,
        )
        mk_cold_ms = round((time.perf_counter() - t0) * 1000.0, 1)
        compiled_cold = r_mk1.stdout.count("COMPILED:")
        assert compiled_cold == 17 and "SUM=136" in r_mk1.stdout, r_mk1.stdout

        # No-op incremental Make -> 0 files compiled!
        t0 = time.perf_counter()
        r_mk_noop = run_cmd(
            [str(MP_CLI), "ci", "docker", "run", "--rm", "-v", f"{inc_repo}:/src", "-w", "/src",
             "ci-gcc:local", "sh", "-c", "make -j4 && ./app"],
            env=env,
        )
        mk_noop_ms = round((time.perf_counter() - t0) * 1000.0, 1)
        assert r_mk_noop.stdout.count("COMPILED:") == 0 and "SUM=136" in r_mk_noop.stdout, r_mk_noop.stdout

        # Atomic host-side edit of 1 module (mod_05.c: 6 -> 106, so SUM 136 -> 236) -> ONLY mod_05.c recompiles!
        time.sleep(1.05)  # Ensure 1-second Make mtime granularity advances cleanly
        tmp_edit = inc_repo / "mod_05.c.tmp"
        tmp_edit.write_text("int fn_mod_05(void) { return 106; }\n")
        os.replace(tmp_edit, inc_repo / "mod_05.c")
        t0 = time.perf_counter()
        r_mk_inc = run_cmd(
            [str(MP_CLI), "ci", "docker", "run", "--rm", "-v", f"{inc_repo}:/src", "-w", "/src",
             "ci-gcc:local", "sh", "-c", "make -j4 && ./app"],
            env=env,
        )
        mk_inc_ms = round((time.perf_counter() - t0) * 1000.0, 1)
        compiled_inc = r_mk_inc.stdout.count("COMPILED:")
        assert compiled_inc == 1 and "COMPILED:mod_05.c" in r_mk_inc.stdout and "SUM=236" in r_mk_inc.stdout, r_mk_inc.stdout

        print(
            f"  [PASS] Node/OCI/Make: scopes isolated, native job cached, "
            f"Make cold={mk_cold_ms}ms (17 files) -> noop={mk_noop_ms}ms (0 files) -> 1-file-edit={mk_inc_ms}ms (1 file, SUM=236)",
            flush=True,
        )

        # =====================================================================
        # 4. Real CI Job #3: Multi-Service Docker Compose Integration Test (Postgres + API + Published Port)
        # =====================================================================
        print("[4/6] Running multi-service Docker Compose integration test (postgres:16-alpine + Node API)...", flush=True)
        compose_repo = repos["compose"]
        api_port = free_tcp_port()
        (compose_repo / "compose.yml").write_text(textwrap.dedent(f"""\
            services:
              db:
                image: postgres:16-alpine
                environment:
                  POSTGRES_USER: ci
                  POSTGRES_PASSWORD: cipassword
                  POSTGRES_DB: cidb
                volumes:
                  - {compose_repo}/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
                  - pgdata:/var/lib/postgresql/data
                healthcheck:
                  test: ["CMD-SHELL", "pg_isready -U ci -d cidb"]
                  interval: 1s
                  timeout: 3s
                  retries: 30
              api:
                image: node:24-alpine
                depends_on:
                  db:
                    condition: service_healthy
                environment:
                  PGHOST: db
                  PGPORT: "5432"
                volumes:
                  - {compose_repo}/api.mjs:/app/api.mjs:ro
                command: ["node", "/app/api.mjs"]
                ports:
                  - "127.0.0.1:{api_port}:8080"
            volumes:
              pgdata:
        """))

        t0 = time.perf_counter()
        try:
            run_cmd(
                [str(MP_CLI), "ci", "docker", "compose", "-f", str(compose_repo / "compose.yml"),
                 "up", "-d", "--wait"],
                env=env, timeout=120,
            )
            http_status, http_body = wait_http_ok(f"http://127.0.0.1:{api_port}/health", timeout_s=15.0)
            assert http_status == 200 and '"ok":true' in http_body, f"API health failed: {http_status} {http_body}"

            # Run real SQL insert + select against Postgres via compose exec!
            r_sql = run_cmd(
                [str(MP_CLI), "ci", "docker", "compose", "-f", str(compose_repo / "compose.yml"),
                 "exec", "-T", "db", "psql", "-U", "ci", "-d", "cidb", "-tAc",
                 "INSERT INTO ci_runs (job_name, status) VALUES ('b7-hvf', 'pass'); SELECT count(*) FROM ci_runs;"],
                env=env, timeout=30,
            )
            assert r_sql.stdout.strip().splitlines()[-1] == "2", f"Unexpected SQL output: {r_sql.stdout!r}"

            # Capture live engine + running workload health while Postgres + API are actively serving!
            h_compose = sample_health("compose_active", env)
            health_timeline["compose_active"] = h_compose
            assert h_compose["workloads"]["runningCount"] >= 2, f"Expected >=2 running Compose containers: {h_compose['workloads']}"
            running_items = [w for w in h_compose["workloads"]["items"] if w["state"] == "running"]
            assert any("postgres" in w["image"] and (w.get("memoryUsageBytes") or 0) > 0 and (w.get("memoryPeakBytes") or 0) > 0 and (w.get("cpuUsageNs") or 0) > 0 for w in running_items), running_items
            assert any("node" in w["image"] and any(str(api_port) in p for p in w.get("ports", [])) and (w.get("netRxBytes") is not None) for w in running_items), running_items
            assert h_compose.get("runtimeEngine") is not None and h_compose["runtimeEngine"]["containersCreated"] >= 2, h_compose.get("runtimeEngine")
            assert h_compose.get("storage") is not None and h_compose["storage"]["totalBytes"] > 0, h_compose.get("storage")
            assert h_compose["hypervisor"]["publishedConns"] >= 1, h_compose["hypervisor"]
            assert h_compose["hypervisor"]["blkWriteOps"] > health_timeline["boot_idle"]["hypervisor"]["blkWriteOps"]
            assert h_compose["hypervisor"]["fsRequests"] > health_timeline["boot_idle"]["hypervisor"]["fsRequests"]
            # Also scrape unified Prometheus & OTLP while Compose Postgres+API are actively running!
            prom_active = run_cmd([str(MP_CLI), "telemetry", "metrics", "--format", "prometheus"], env=env).stdout
            for expected_metric in (
                "micropod_container_cpu_usage_seconds_total{",
                "micropod_container_memory_usage_bytes{",
                "micropod_container_memory_peak_bytes{",
                "micropod_container_memory_oom_kills_total{",
                "micropod_container_network_bytes_total{",
                "micropod_container_pids_current{",
                "micropod_runtime_containers_created_total{",
                "micropod_runtime_phase_duration_milliseconds_total{",
                "micropod_runtime_dns_queries_total{",
                "micropod_storage_bytes{",
            ):
                assert expected_metric in prom_active, f"Missing {expected_metric} in Prometheus output:\n{prom_active}"
            otlp_active = json.loads(run_cmd([str(MP_CLI), "telemetry", "metrics", "--format", "otlp"], env=env).stdout)
            otlp_names = {
                m["name"]
                for rm in otlp_active.get("resourceMetrics", [])
                for sm in rm.get("scopeMetrics", [])
                for m in sm.get("metrics", [])
            }
            for req_otlp in (
                "micropod.container.cpu.usage_ns",
                "micropod.container.memory.peak",
                "micropod.container.network.rx",
                "micropod.runtime.containers.created",
                "micropod.storage.used",
            ):
                assert req_otlp in otlp_names, f"Missing {req_otlp} in OTLP metrics: {sorted(otlp_names)}"
            compose_ms = round((time.perf_counter() - t0) * 1000.0, 1)
        finally:
            run_cmd(
                [str(MP_CLI), "ci", "docker", "compose", "-f", str(compose_repo / "compose.yml"),
                 "down", "-v"],
                env=env, timeout=60, check=False,
            )
        h_after_down = sample_health("after_compose_down", env)
        health_timeline["after_compose_down"] = h_after_down
        assert h_after_down["workloads"]["runningCount"] == 0, f"Leaked running container after compose down: {h_after_down['workloads']}"
        print(
            f"  [PASS] Compose Postgres+API integration test passed in {compose_ms} ms "
            f"(live health surfaced {h_compose['workloads']['runningCount']} running workloads with live mem/ports -> 0 after down)",
            flush=True,
        )

        # Deliberate OOM fault injection to verify engine health surfaces degraded verdict & oomKills counter!
        run_cmd(
            [str(MP_CLI), "ci", "docker", "run", "--rm", "--memory", "32m", "alpine:3.23",
             "awk", 'BEGIN{s="A"; for(i=0;i<27;i++) s=s s; print length(s)}'],
            env=env, timeout=20, check=False,
        )
        h_oom = sample_health("after_oom_fault", env, allow_degraded=True)
        health_timeline["after_oom_fault"] = h_oom
        assert h_oom["verdict"] == "degraded", f"Expected degraded verdict after OOM kill: {h_oom}"
        assert (h_oom.get("kernel", {}).get("oomKills") or 0) >= 1, f"Expected kernel.oomKills >= 1: {h_oom}"
        assert any("OOM" in w for w in h_oom["warnings"]), f"Expected OOM warning: {h_oom['warnings']}"
        print(f"  [PASS] Fault visibility: OOM fault surfaced verdict=degraded, warnings={h_oom['warnings']}", flush=True)

        # Collect pre-restart cache & native OCI metrics
        metrics_before = json.loads(run_cmd([str(MP_CLI), "ci", "metrics"], env=env).stdout)

        # =====================================================================
        # 5. Graceful Restart Cache Persistence Test (runner-stop -> runner-start)
        # =====================================================================
        print("[5/6] Testing cache persistence across graceful runner-stop -> runner-start...", flush=True)
        t_stop = time.perf_counter()
        run_cmd([str(MP_CLI), "ci", "runner-stop"], env=env, timeout=30)
        stop_ms = round((time.perf_counter() - t_stop) * 1000.0, 1)

        # Restart with MICROPOD_CI_HVF_CAPTURE_SNAPSHOT AND tracing enabled so snapshot & boot spans are captured!
        warm_snap_dir = work / "managed-warm-snap"
        run_cmd([str(MP_CLI), "telemetry", "enable", "tracing"], env=env)
        env_restart = base_ci_env(
            ci_home,
            workspace=ws_root,
            extra={
                "MICROPOD_CI_HVF_CAPTURE_SNAPSHOT": str(warm_snap_dir),
                "MICROPOD_OBSERVABILITY_CONFIG": str(obs_yaml_main),
            },
        )
        t_rs = time.perf_counter()
        run_cmd([str(MP_CLI), "ci", "runner-start"], env=env_restart, timeout=90)
        restart_with_snap_ms = round((time.perf_counter() - t_rs) * 1000.0, 1)

        # Inspect live bottleneck spans recorded during boot + snapshot capture!
        boot_snap_traces = run_cmd([str(MP_CLI), "telemetry", "trace", "dump", "--summary"], env=env).stdout
        assert "vmm.snapshot.save" in boot_snap_traces and "vmm.boot.setup" in boot_snap_traces, boot_snap_traces

        # Verify post-reboot health returns to clean `healthy` (fresh kernel boot resets oomKills=0!)
        for _ in range(15):
            h_try = json.loads(run_cmd([str(MP_CLI), "ci", "runner-health"], env=env).stdout)
            if h_try.get("verdict") == "healthy":
                break
            time.sleep(0.15)
        health_timeline["post_reboot"] = sample_health("post_reboot", env)

        # Verify ALL 4 caches survived graceful restart intact!
        # 5a. Image store persisted (demo-app:v2 runs with 0 pull)
        r_img_after = run_cmd([str(MP_CLI), "ci", "docker", "run", "--rm", "demo-app:v2"], env=env)
        assert "APP_VERSION=1.0.1-edited CHECKSUM=15150" in r_img_after.stdout

        # 5b. BuildKit layer cache persisted across reboot!
        t0 = time.perf_counter()
        r_bk_reboot = run_cmd(
            [str(MP_CLI), "ci", "docker", "buildx", "build", "--load", "--progress=plain",
             "-t", "demo-app:v2", str(bk_repo)],
            env=env, timeout=120,
        )
        bk_post_reboot_s = round(time.perf_counter() - t0, 3)
        reboot_cached = (r_bk_reboot.stdout + r_bk_reboot.stderr).count("CACHED")
        assert reboot_cached >= 3, f"BuildKit cache did not survive reboot: {r_bk_reboot.stderr}"

        # 5c. Scoped Docker volume caches + native OCI scope cache survived reboot!
        r_npm_after = run_cmd(
            [str(MP_CLI), "ci", "run", "--cache", "npm", "--cache-scope", "scope-alpha",
             "node:24-alpine", "sh", "-c", "cat \"$npm_config_cache/marker.txt\""],
            env=env,
        )
        assert r_npm_after.stdout.strip() == "ALPHA_CACHED_V1"
        r_py_after = run_cmd(
            [str(MP_CLI), "ci", "run", "--cache", "python", "--cache-scope", "scope-py",
             "alpine:3.23", "sh", "-c", "cat \"$PYTHONPYCACHEPREFIX/ok.txt\""],
            env=env,
        )
        assert r_py_after.stdout.strip() == "PY_CACHE_READY"
        r_native_after = run_cmd(
            [str(MP_CLI), "ci", "job", "trusted", "docker.io/library/alpine:3.23",
             "sh", "-c", "cat \"$GOCACHE/key.txt\""],
            env=env_native_cache,
        )
        assert "NATIVE_GO_CACHE_OK" in r_native_after.stdout

        # Stop the base worker cleanly before testing CoW forks (and capture final snapshot after BuildKit warm!)
        # Actually warm_snap_dir was captured right at restart_with_snap_ms with ALL images + BuildKit + volume caches already on disk!
        assert (warm_snap_dir / "READY").exists() and (warm_snap_dir / "micropod-snapshot.json").exists()
        run_cmd([str(MP_CLI), "ci", "runner-stop"], env=env, timeout=30)
        active_homes.remove(env)

        print(
            f"  [PASS] Restart persistence: stop={stop_ms}ms, restart+snap={restart_with_snap_ms}ms, "
            f"BuildKit post-reboot={bk_post_reboot_s}s ({reboot_cached} CACHED), all scoped caches intact!",
            flush=True,
        )

        # =====================================================================
        # 6. Managed APFS CoW Warm Snapshot Pool: 3 Parallel Workers Inherit Warm Caches & Isolate Writes
        # =====================================================================
        print("[6/6] Launching 3 parallel managed CoW workers from warm snapshot to test cache inheritance & isolation...", flush=True)
        fork_envs = []
        for idx in range(3):
            fhome = work / f"ci-home-fork-{idx}"
            fenv = base_ci_env(
                fhome,
                workspace=ws_root,
                extra={
                    "MICROPOD_CI_HVF_RESTORE_FROM": str(warm_snap_dir),
                    "MICROPOD_OBSERVABILITY_CONFIG": str(obs_yaml_pool),
                },
            )
            fork_envs.append(fenv)
            active_homes.append(fenv)

        def start_and_verify_fork(idx: int, fenv: dict[str, str]) -> dict:
            t_s = time.perf_counter()
            run_cmd([str(MP_CLI), "ci", "runner-start"], env=fenv, timeout=60)
            start_ms = round((time.perf_counter() - t_s) * 1000.0, 1)

            # 1. Verify inherited warm image + BuildKit cache + scoped volume cache!
            r_img = run_cmd([str(MP_CLI), "ci", "docker", "run", "--rm", "demo-app:v2"], env=fenv)
            assert "APP_VERSION=1.0.1-edited CHECKSUM=15150" in r_img.stdout

            r_cache = run_cmd(
                [str(MP_CLI), "ci", "run", "--cache", "npm", "--cache-scope", "scope-alpha",
                 "node:24-alpine", "sh", "-c",
                 f"old=$(cat \"$npm_config_cache/marker.txt\"); "
                 f"echo FORK_{idx}_PRIVATE > \"$npm_config_cache/fork_{idx}.txt\"; "
                 f"echo $old"],
                env=fenv,
            )
            assert r_cache.stdout.strip() == "ALPHA_CACHED_V1", r_cache.stdout

            # 2. Verify inherited warm BuildKit cache on each fork!
            t_b = time.perf_counter()
            r_bk = run_cmd(
                [str(MP_CLI), "ci", "docker", "buildx", "build", "--load", "--progress=plain",
                 "-t", f"demo-app:fork-{idx}", str(bk_repo)],
                env=fenv, timeout=120,
            )
            bk_s = round(time.perf_counter() - t_b, 3)
            c_steps = (r_bk.stdout + r_bk.stderr).count("CACHED")
            assert c_steps >= 3, f"fork {idx} lost BuildKit cache: {r_bk.stderr}"
            h_fork = sample_health(f"fork_{idx}", fenv)
            return {
                "fork": idx,
                "managed_runner_start_ms": start_ms,
                "buildkit_cached_rebuild_s": bk_s,
                "buildkit_cached_steps": c_steps,
                "health_verdict": h_fork["verdict"],
                "host_phys_footprint_mib": h_fork["hypervisor"]["hostPhysFootprintMib"],
                "clock_sync_count": h_fork["hypervisor"]["clockSyncCount"],
            }

        t_pool = time.perf_counter()
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as ex:
            futs = [ex.submit(start_and_verify_fork, i, fenv) for i, fenv in enumerate(fork_envs)]
            fork_results = [f.result() for f in futs]
        pool_wall_ms = round((time.perf_counter() - t_pool) * 1000.0, 1)

        # Verify strict APFS CoW cache isolation across all 3 live forks!
        for idx, fenv in enumerate(fork_envs):
            r_iso = run_cmd(
                [str(MP_CLI), "ci", "run", "--cache", "npm", "--cache-scope", "scope-alpha",
                 "node:24-alpine", "sh", "-c", "ls \"$npm_config_cache\" | sort | tr '\\n' ','"],
                env=fenv,
            )
            files = [x for x in r_iso.stdout.strip().split(",") if x]
            assert f"fork_{idx}.txt" in files, f"fork {idx} missing own cache write: {files}"
            for other in range(3):
                if other != idx:
                    assert f"fork_{other}.txt" not in files, f"CoW cache leak: fork {idx} saw fork_{other}.txt ({files})"

        # Cleanly stop all 3 forked managed workers
        for fenv in list(fork_envs):
            run_cmd([str(MP_CLI), "ci", "runner-stop"], env=fenv, timeout=30)
            active_homes.remove(fenv)

        print(
            f"  [PASS] 3x Managed CoW Pool: all 3 inherited warm images+BuildKit+scoped caches with 100% CoW isolation "
            f"(start={ [r['managed_runner_start_ms'] for r in fork_results] } ms, total_wall={pool_wall_ms} ms)",
            flush=True,
        )

        # Verify live OTLP/HTTP Collector received BOTH resourceMetrics AND resourceSpans (VMM + Swift CLI)!
        otlp_batches = otlp_collector.snapshot()
        metrics_batches = [b for b in otlp_batches if b["path"] == "/v1/metrics"]
        trace_batches = [b for b in otlp_batches if b["path"] == "/v1/traces"]
        assert len(metrics_batches) >= 2, f"Expected >=2 live OTLP metrics batches, got {len(metrics_batches)}"
        assert len(trace_batches) >= 2, f"Expected >=2 live OTLP trace batches, got {len(trace_batches)}"
        services_seen = set()
        spans_seen: dict[str, list[float]] = {}
        for batch in metrics_batches:
            for rm in batch["payload"].get("resourceMetrics", []):
                for a in rm.get("resource", {}).get("attributes", []):
                    if a.get("key") == "service.name":
                        services_seen.add(a.get("value", {}).get("stringValue"))
        for batch in trace_batches:
            for rs in batch["payload"].get("resourceSpans", []):
                for ss in rs.get("scopeSpans", []):
                    for sp in ss.get("spans", []):
                        name = sp.get("name", "")
                        s_ns = int(sp.get("startTimeUnixNano", "0"))
                        e_ns = int(sp.get("endTimeUnixNano", "0"))
                        dur_ms = round(max(0, e_ns - s_ns) / 1_000_000.0, 3)
                        spans_seen.setdefault(name, []).append(dur_ms)
        assert "micropod-b7-e2e" in services_seen, f"Missing main OTLP service in {services_seen}"
        for req_span in ("vmm.tracing.enabled", "vmm.boot.setup", "vmm.snapshot.save", "vmm.restore.setup", "vmm.restore.cow_disk_clone", "vmm.restore.cow_ram_map", "vmm.restore.gic_and_virtio", "ci.worker.start"):
            assert req_span in spans_seen, f"Missing expected bottleneck span '{req_span}' in {sorted(spans_seen.keys())}"

        span_bottleneck_summary = {
            name: {
                "count": len(vals),
                "min_ms": min(vals),
                "max_ms": max(vals),
                "avg_ms": round(sum(vals) / len(vals), 3),
            }
            for name, vals in sorted(spans_seen.items())
        }

        report = {
            "label": "phase-b7-real-ci-and-caching",
            "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "cli_binary": str(MP_CLI),
            "zero_config_bundle_discovery": True,
            "observability": {
                "yaml_config_cli_managed": True,
                "metric_files_on_disk": 0,
                "prometheus_tcp_scrape_ok": True,
                "prometheus_unified_cli_ok": True,
                "otlp_unified_cli_ok": True,
                "live_runtime_tracing_toggle_ok": True,
                "otlp_live_metrics_batches_received": len(metrics_batches),
                "otlp_live_trace_batches_received": len(trace_batches),
                "otlp_services_observed": sorted(services_seen),
                "trace_bottleneck_spans_ms": span_bottleneck_summary,
            },
            "cold_worker_start_ms": cold_start_ms,
            "base_images_load_ms": load_ms,
            "kernel_metrics_available": bool(kernel_metrics),
            "buildkit_caching": {
                "cold_build_s": bk_cold_s,
                "warm_hit_build_s": bk_warm_s,
                "warm_cached_steps": warm_cached_steps,
                "warm_speedup_x": round(bk_cold_s / max(bk_warm_s, 0.001), 2),
                "partial_source_edit_build_s": bk_partial_s,
                "post_reboot_cached_build_s": bk_post_reboot_s,
                "post_reboot_cached_steps": reboot_cached,
                "ci_snapshot_cold_s": ci_snap_cold_s,
                "ci_snapshot_warm_s": ci_snap_warm_s,
            },
            "scoped_and_workspace_caching": {
                "node_tests_passed": True,
                "npm_scope_hit_ok": True,
                "npm_cross_scope_isolated": True,
                "python_scope_hit_ok": True,
                "native_oci_primed_and_gocache_hit_ok": True,
                "virtiofs_make_cold_17_files_ms": mk_cold_ms,
                "virtiofs_make_noop_0_files_ms": mk_noop_ms,
                "virtiofs_make_1_edited_file_ms": mk_inc_ms,
                "metrics_usage_before_restart": metrics_before,
            },
            "compose_postgres_api_integration": {
                "passed": True,
                "wall_ms": compose_ms,
                "http_status": http_status,
                "sql_rows_verified": 2,
            },
            "graceful_restart_persistence": {
                "runner_stop_ms": stop_ms,
                "runner_restart_with_snapshot_ms": restart_with_snap_ms,
                "all_4_caches_persisted": True,
            },
            "managed_cow_snapshot_pool": {
                "forks": 3,
                "all_inherited_warm_caches": True,
                "cow_cache_isolation_verified": True,
                "total_parallel_wall_ms": pool_wall_ms,
                "samples": fork_results,
            },
            "health_observability_timeline": health_timeline,
        }
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2) + "\n")
        print("\n=== ALL REAL CI JOBS & CACHING LAYERS PASSED ===", flush=True)
        print(json.dumps(report, indent=2), flush=True)
        print(f"\nSaved receipt to {args.out}", flush=True)
    finally:
        for aenv in active_homes:
            try:
                r = run_cmd([str(MP_CLI), "ci", "runner-stop"], env=aenv, timeout=15, check=False)
                if r.returncode != 0:
                    sess_path = Path(aenv["MICROPOD_CI_HOME"]) / "session.json"
                    if sess_path.exists():
                        pid = json.loads(sess_path.read_text()).get("owner", {}).get("pid")
                        if pid:
                            os.kill(pid, 15)
            except Exception:
                pass
        otlp_collector.close()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
