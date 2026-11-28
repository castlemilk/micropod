#!/usr/bin/env python3
"""Build a layered Go and npm cache-evaluation receipt for CI workloads.

The evaluator combines the repository's deterministic package-cache benchmark,
optional OCI engine measurements, the production Micropod worker qualification,
the realistic phase-B7 CI/cache suite, and the HVF cache qualification matrix.
It normalizes their evidence into one
JSON receipt and an optional Markdown scorecard. The host layer is fast and has
no Docker dependency; the other layers are opt-in because they boot or stop real
container infrastructure.
"""

import argparse
import csv
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = 1
KIND = "ci-cache-eval"
TOOLS = ("go", "npm")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def git_revision() -> str:
    result = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"],
                            capture_output=True, text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def load_json(path: Path):
    return json.loads(path.read_text())


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def rounded(value):
    if isinstance(value, float):
        return round(value, 6)
    return value


def metric(layer: str, name: str, value, unit: str, *, tool=None, clients=None, phase=None):
    row = {"layer": layer, "name": name, "value": rounded(value), "unit": unit}
    if tool is not None:
        row["tool"] = tool
    if clients is not None:
        row["clients"] = clients
    if phase is not None:
        row["phase"] = phase
    return row


def check(check_id: str, passed: bool, detail: str, *, status=None):
    return {"id": check_id, "passed": bool(passed), "status": status or ("pass" if passed else "fail"), "detail": detail}


def layer_result(assertions, metrics, evidence):
    failed = [a for a in assertions if a["passed"] is False]
    return {
        "status": "failed" if failed else "passed",
        "assertions": assertions,
        "metrics": metrics,
        "evidence": evidence,
    }


def integer_keys(value):
    return sorted(value, key=lambda item: int(item))


def evaluate_host(raw):
    assertions = []
    metrics = []
    seed = raw.get("seed") or {}
    medians = raw.get("median_seconds") or {}
    before = raw.get("before") or {}
    after = raw.get("after") or {}
    cold_compile = seed.get("go_cold_compiler_or_assembler_invocations")
    warm_compile = raw.get("warm_compiler_or_assembler_invocations")
    controls = set(raw.get("offline_negative_controls") or [])

    def add(name, condition, detail):
        assertions.append(check("host." + name, bool(condition), detail))

    add("completed", raw.get("passed") is True, raw.get("error") or "deterministic offline host benchmark completed")
    add("empty-cache-control", controls == {"go", "npm"},
        "empty offline npm and Go stores both fail closed" if controls else f"controls={sorted(controls)}")
    add("go.cold-compilation-observed", isinstance(cold_compile, int) and cold_compile > 0,
        f"cold build invoked compile/asm {cold_compile} times")
    add("go.warm-no-compilation", warm_compile == 0,
        f"warm checkouts invoked compile/asm {warm_compile} times")
    add("cache-footprint-stable", bool(before) and before == after,
        f"before={before} after={after}")
    add("payload-integrity-recorded", bool(raw.get("npm_integrity")) and bool(raw.get("go_zip_sha256")),
        "npm integrity and Go module zip digest are pinned in the receipt")
    add("independent-store-isolation", bool(raw.get("independent_store")),
        "an independently seeded control produced its own payload copies")

    evidence = {
        "workload": raw.get("profile", "package-manager-offline"),
        "versions": raw.get("versions", {}),
        "before": before,
        "after": after,
        "independent_store": raw.get("independent_store"),
        "npm_integrity": raw.get("npm_integrity"),
        "go_zip_sha256": raw.get("go_zip_sha256"),
        "warm_median_seconds": medians,
    }
    for key, unit in (
        ("npm_cache_add_seconds", "s"),
        ("go_download_seconds", "s"),
        ("go_cold_build_seconds", "s"),
    ):
        if isinstance(seed.get(key), (int, float)):
            metrics.append(metric("host", key, seed[key], unit, phase="cold"))
    if isinstance(cold_compile, int):
        metrics.append(metric("host", "go_cold_compiler_or_assembler_invocations", cold_compile, "count", tool="go", phase="cold"))
    for tool in TOOLS:
        for clients in integer_keys(medians.get(tool) or {}):
            value = medians[tool][clients]
            metrics.append(metric("host", "warm_batch_seconds_p50", value, "s", tool=tool, clients=int(clients), phase="warm"))
    try:
        cold = seed.get("go_cold_build_seconds")
        warm = (medians.get("go") or {}).get("1")
        if cold and warm:
            evidence["go_cold_to_warm_speedup_x"] = round(cold / warm, 3)
            metrics.append(metric("host", "go_cold_to_warm_speedup", cold / warm, "x", tool="go"))
    except (TypeError, ZeroDivisionError):
        pass
    return layer_result(assertions, metrics, evidence)


def evaluate_engine(raw):
    assertions = []
    metrics = []
    package = raw.get("package_caches") or {}
    blocks = package.get("blocks") or []
    medians = package.get("median_seconds") or {}

    def add(name, condition, detail):
        assertions.append(check("engine." + name, bool(condition), detail))

    add("completed", raw.get("passed") is True and package.get("passed") is True,
        raw.get("error") or "OCI package-cache measurement completed")
    add("kernel-and-architecture-verified", bool(raw.get("boot_sha256")) and bool(package.get("architecture")),
        f"architecture={package.get('architecture')} boot={raw.get('boot_sha256')}")
    add("empty-offline-controls", bool(blocks) and all(block.get("empty_offline_controls") for block in blocks),
        f"blocks={len(blocks)}")
    add("payload-inodes-stable", bool(blocks) and all(block.get("same_payload_inodes") for block in blocks),
        "npm tarball and Go module zip kept their seed inode in every block")
    add("cache-footprint-stable", bool(blocks) and all(block.get("before") == block.get("after") for block in blocks),
        "npm content, Go module and Go build cache sizes stayed unchanged after warm reuse")
    batches = [batch for block in blocks for batch in block.get("batches", [])]
    failed = sum(len(batch.get("errors") or []) for batch in batches)
    add("concurrent-jobs-all-passed", bool(batches) and failed == 0 and all(
        batch.get("passed") == batch.get("clients") for batch in batches),
        f"batches={len(batches)} failed_jobs={failed}")

    evidence = {
        "workload": package.get("workload"),
        "image_id": package.get("image_id"),
        "versions": (blocks[0].get("versions") if blocks else {}),
        "blocks": len(blocks),
        "cache_sizes": [{"before": block.get("before"), "after": block.get("after")} for block in blocks],
        "warm_median_seconds": medians,
        "container_launch_p50_seconds": raw.get("p50_seconds", {}),
    }
    for tool in TOOLS:
        for clients in integer_keys(medians.get(tool) or {}):
            metrics.append(metric("engine", "warm_batch_seconds_p50", medians[tool][clients], "s",
                                  tool=tool, clients=int(clients), phase="warm"))
    for clients, value in (raw.get("p50_seconds") or {}).items():
        if str(clients).isdigit():
            metrics.append(metric("engine", "container_batch_seconds_p50", value, "s", clients=int(clients)))
    cold = (blocks[0].get("cold") if blocks else {}) or {}
    for key in ("npm_cache_add_seconds", "go_download_seconds", "go_cold_build_seconds"):
        if isinstance(cold.get(key), (int, float)):
            metrics.append(metric("engine", key, cold[key], "s", phase="cold"))
    if isinstance(cold.get("go_cold_compiler_or_assembler_invocations"), int):
        metrics.append(metric("engine", "go_cold_compiler_or_assembler_invocations",
                              cold["go_cold_compiler_or_assembler_invocations"], "count", tool="go", phase="cold"))
    return layer_result(assertions, metrics, evidence)


def evaluate_worker(raw):
    assertions = []
    metrics = []
    caches = raw.get("cli_caches") or {}
    seed = caches.get("seed") or {}
    warm = caches.get("warm_seconds") or {}

    def add(name, condition, detail):
        assertions.append(check("worker." + name, bool(condition), detail))

    add("completed", raw.get("passed") is True, raw.get("error") or "production worker qualification completed")
    add("cache-seed-completed", bool(seed.get("lock")) and bool(seed.get("cache_sizes")),
        "the offline npm/Go fixture seeded through `micropod ci run --cache`")
    add("empty-scope-isolated", caches.get("empty_scope_verified") is True,
        "an empty sibling scope cannot satisfy the offline lock")
    add("warm-reuse-measured", all(isinstance(warm.get(tool), (int, float)) for tool in TOOLS),
        f"warm seconds={warm}")
    add("cache-footprint-stable", bool(seed.get("cache_sizes")) and seed.get("cache_sizes") == caches.get("after"),
        f"seed={seed.get('cache_sizes')} after={caches.get('after')}")
    add("restart-preserves-payloads", caches.get("restart_reused_payloads") is True,
        "the same npm and Go payload inodes are reused after a worker restart")
    repeat = ((raw.get("build_traces") or {}).get("repeat") or {}).get("outcomes") or {}
    add("buildkit-repeat-hit", repeat.get("cached", 0) > 0 and repeat.get("executed", 1) == 0,
        f"repeat BuildKit outcomes={repeat}")

    pipelines = raw.get("pipeline_seconds") or {}
    worker_pipeline = pipelines.get("worker") or {}
    if worker_pipeline:
        first = worker_pipeline.get("first")
        warm_pipeline = worker_pipeline.get("warm")
        add("full-pipeline-warm-reuse", isinstance(first, (int, float)) and isinstance(warm_pipeline, (int, float))
            and warm_pipeline < first,
            f"first={first}s warm={warm_pipeline}s")
    evidence = {
        "worker": raw.get("worker", {}),
        "warm_seconds": warm,
        "cache_sizes": caches.get("after"),
        "pipeline_seconds": worker_pipeline,
        "verified": raw.get("verified", []),
    }
    for tool in TOOLS:
        if isinstance(warm.get(tool), (int, float)):
            metrics.append(metric("worker", "warm_batch_seconds", warm[tool], "s",
                                  tool=tool, clients=caches.get("clients"), phase="warm"))
    cold = seed.get("cold") or {}
    for key in ("npm_cache_add_seconds", "go_download_seconds", "go_cold_build_seconds"):
        if isinstance(cold.get(key), (int, float)):
            metrics.append(metric("worker", key, cold[key], "s", phase="cold"))
    for phase, value in worker_pipeline.items():
        if isinstance(value, (int, float)):
            metrics.append(metric("worker", "full_ci_pipeline_seconds", value, "s", phase=phase))
    stages = ((raw.get("pipeline_stages_seconds") or {}).get("worker") or {})
    for phase, rows in stages.items():
        for stage, seconds in rows.items():
            metrics.append(metric("worker", "pipeline_stage_seconds", seconds, "s", phase=f"{phase}.{stage}"))
    return layer_result(assertions, metrics, evidence)


def evaluate_suite(raw):
    assertions = []
    metrics = []
    buildkit = raw.get("buildkit_caching") or {}
    scoped = raw.get("scoped_and_workspace_caching") or {}
    restart = raw.get("graceful_restart_persistence") or {}
    pool = raw.get("managed_cow_snapshot_pool") or {}
    compose = raw.get("compose_postgres_api_integration") or {}

    def add(name, condition, detail):
        assertions.append(check("suite." + name, bool(condition), detail))

    add("completed", raw.get("label") == "phase-b7-real-ci-and-caching" and bool(buildkit),
        "real CI and caching suite receipt is present")
    add("npm-scope-hit", scoped.get("npm_scope_hit_ok") is True,
        "a marker in the scoped npm cache survived into a later job")
    add("npm-cross-scope-isolated", scoped.get("npm_cross_scope_isolated") is True,
        "the sibling npm scope did not see that marker")
    add("native-go-cache-hit", scoped.get("native_oci_primed_and_gocache_hit_ok") is True,
        "the native OCI job primed and reused its Go cache")
    warm_steps = buildkit.get("warm_cached_steps")
    add("buildkit-warm-hit", isinstance(warm_steps, int) and warm_steps >= 3
        and buildkit.get("warm_hit_build_s", 1e9) < buildkit.get("cold_build_s", 0),
        f"cold={buildkit.get('cold_build_s')}s warm={buildkit.get('warm_hit_build_s')}s cached_steps={warm_steps}")
    reboot_steps = buildkit.get("post_reboot_cached_steps")
    add("restart-preserves-buildkit-and-scoped-caches", isinstance(reboot_steps, int) and reboot_steps >= 3
        and restart.get("all_4_caches_persisted") is True,
        f"post_reboot_cached_steps={reboot_steps} scoped_persisted={restart.get('all_4_caches_persisted')}")
    add("snapshot-forks-inherit-and-isolate-caches", pool.get("all_inherited_warm_caches") is True
        and pool.get("cow_cache_isolation_verified") is True,
        f"forks={pool.get('forks')}")
    add("compose-ci-workload-passed", compose.get("passed") is True and compose.get("http_status") == 200,
        f"postgres/API status={compose.get('http_status')} rows={compose.get('sql_rows_verified')}")

    for key, phase in (
        ("cold_build_s", "buildkit.cold"), ("warm_hit_build_s", "buildkit.warm-hit"),
        ("partial_source_edit_build_s", "buildkit.partial-edit"),
        ("post_reboot_cached_build_s", "buildkit.post-restart-hit"),
        ("ci_snapshot_cold_s", "snapshot.cold"), ("ci_snapshot_warm_s", "snapshot.warm"),
    ):
        if isinstance(buildkit.get(key), (int, float)):
            metrics.append(metric("suite", "build_or_restore_seconds", buildkit[key], "s", phase=phase))
    if isinstance(buildkit.get("warm_speedup_x"), (int, float)):
        metrics.append(metric("suite", "buildkit_cold_to_warm_speedup", buildkit["warm_speedup_x"], "x"))
    for key, phase in (
        ("virtiofs_make_cold_17_files_ms", "make.cold-17-files"),
        ("virtiofs_make_noop_0_files_ms", "make.noop-warm"),
        ("virtiofs_make_1_edited_file_ms", "make.one-edited-file"),
    ):
        if isinstance(scoped.get(key), (int, float)):
            metrics.append(metric("suite", "workspace_build_duration_ms", scoped[key], "ms", phase=phase))
    for key, name, unit in (
        ("runner_restart_with_snapshot_ms", "worker_restart_with_snapshot_ms", "ms"),
        ("runner_stop_ms", "worker_stop_ms", "ms"),
    ):
        if isinstance(restart.get(key), (int, float)):
            metrics.append(metric("suite", name, restart[key], unit, phase="restart"))
    if isinstance(compose.get("wall_ms"), (int, float)):
        metrics.append(metric("suite", "compose_postgres_api_wall_ms", compose["wall_ms"], "ms", phase="integration"))
    if isinstance(pool.get("total_parallel_wall_ms"), (int, float)):
        metrics.append(metric("suite", "snapshot_pool_parallel_wall_ms", pool["total_parallel_wall_ms"], "ms",
                              phase="snapshot-pool"))

    evidence = {
        "buildkit": buildkit,
        "scoped_cache_flags": {k: scoped.get(k) for k in (
            "node_tests_passed", "npm_scope_hit_ok", "npm_cross_scope_isolated",
            "python_scope_hit_ok", "native_oci_primed_and_gocache_hit_ok")},
        "restart": restart,
        "snapshot_pool": {k: pool.get(k) for k in ("forks", "all_inherited_warm_caches", "cow_cache_isolation_verified")},
        "compose": compose,
    }
    return layer_result(assertions, metrics, evidence)


def parse_key_value_file(path: Path):
    row = {}
    try:
        for line in path.read_text(errors="replace").splitlines():
            if line.startswith("QUAL-SENTINEL ") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            row[key] = value
    except OSError:
        pass
    return row


def parse_docker_time(value: str):
    if not value or value.startswith("0001-01-01"):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def inspect_duration_ms(path: Path):
    try:
        rows = json.loads(path.read_text())
        state = (rows[0] if rows else {}).get("State") or {}
        start = parse_docker_time(state.get("StartedAt", ""))
        finish = parse_docker_time(state.get("FinishedAt", ""))
        if start is not None and finish is not None and finish >= start:
            return round((finish - start) * 1000, 3)
    except (OSError, ValueError):
        pass
    return None


def parse_hvf_results(directory: Path):
    checks_path = directory / "checks.tsv"
    if not checks_path.is_file():
        raise ValueError(f"HVF qualification checks not found: {checks_path}")
    metadata = {}
    environment = directory / "environment.txt"
    if environment.is_file():
        first = environment.read_text(errors="replace").splitlines()[0]
        for part in first.split():
            if "=" in part:
                key, value = part.split("=", 1)
                metadata[key] = value
    checks = []
    with checks_path.open(newline="") as stream:
        for row in csv.reader(stream, delimiter="\t"):
            if len(row) >= 6:
                checks.append({"status": row[0], "section": row[1], "requirement": row[2],
                               "label": row[3], "got": row[4], "want": row[5]})
    results = directory / "results"
    operations = []
    if results.is_dir():
        for path in sorted(results.glob("*.res")):
            row = parse_key_value_file(path)
            if not row.get("tool"):
                continue
            name = path.stem
            op = {"name": name, "tool": row.get("tool"), "action": row.get("action"), "variant": row.get("variant"),
                  "uid": row.get("uid"), "rc": row.get("rc")}
            for key in ("compiles", "downloads", "downloaded", "reused", "eacces", "verify_ok"):
                if key in row and str(row[key]).isdigit():
                    op[key] = int(row[key])
            for key in ("start", "end"):
                if key in row and str(row[key]).isdigit():
                    op[key] = int(row[key])
            if isinstance(op.get("start"), int) and isinstance(op.get("end"), int) and op["end"] >= op["start"]:
                op["guest_duration_ms"] = (op["end"] - op["start"]) * 1000
            inspect = results / (name + ".inspect.json")
            if inspect.is_file():
                duration = inspect_duration_ms(inspect)
                if duration is not None:
                    op["container_duration_ms"] = duration
            operations.append(op)
    latency = {}
    latency_path = results / "t7-series.json"
    if latency_path.is_file():
        try:
            latency = json.loads(latency_path.read_text())
        except ValueError:
            latency = {}
    for side in ("off", "on"):
        first_path = results / f"t7-first-{side}.json"
        if first_path.is_file():
            try:
                latency["first_" + side] = json.loads(first_path.read_text())
            except ValueError:
                pass
    return checks, operations, latency, metadata


def slug(text: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return value[:96] or "check"


def evaluate_hvf(directory: Path):
    checks, operations, latency, metadata = parse_hvf_results(directory)
    assertions = []
    metrics = []
    counts = {"pass": 0, "fail": 0, "skip": 0}
    for row in checks:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
        passed = row["status"] == "pass"
        item = check("hvf." + row["section"].lower() + "." + slug(row["label"]), passed,
                     f"{row['label']}: got {row['got']}, want {row['want']}",
                     status=row["status"])
        item["requirement"] = row["requirement"]
        item["section"] = row["section"]
        # A skipped manual-wiring substitute is explicit non-evidence, not a failure.
        if row["status"] == "skip":
            item["passed"] = None
        assertions.append(item)

    def add(name, condition, detail):
        assertions.append(check("hvf." + name, bool(condition), detail))

    add("no-failed-checks", counts.get("fail", 0) == 0,
        f"pass={counts.get('pass', 0)} fail={counts.get('fail', 0)} skip={counts.get('skip', 0)}")
    add("results-sentinel-coverage", bool(operations),
        f"parsed {len(operations)} package-manager operation receipts")
    add("automatic-cache-attachment", metadata.get("manual") != "1",
        "QUAL_MANUAL_WIRING=1 is a harness self-test, not engine qualification" if metadata.get("manual") == "1"
        else "the qualification used the engine's automatic cache attachment")

    labels = [row["label"].lower() for row in checks if row["status"] == "pass"]
    coverage = {
        "go_warm_hit": any("go" in label and ("fully warm" in label or "hits fully" in label) for label in labels),
        "npm_offline_hit": any("npm" in label and ("offline" in label or "hits" in label) for label in labels),
        "go_concurrency": any("concurrent" in label and "go" in label for label in labels),
        "npm_concurrency": any("concurrent" in label and "npm" in label for label in labels),
        "restart_or_crash": any("restart" in label or "crash" in label or "after" in label for label in labels),
    }

    grouped = {}
    for op in operations:
        key = (op["tool"], op["action"])
        grouped.setdefault(key, []).append(op)
    operation_stats = {}
    for (tool, action), rows in sorted(grouped.items()):
        durations = [op["container_duration_ms"] for op in rows if "container_duration_ms" in op]
        guest = [op["guest_duration_ms"] for op in rows if "guest_duration_ms" in op]
        stats = {"operations": len(rows)}
        if durations:
            stats["container_duration_ms_p50"] = round(statistics.median(durations), 3)
            metrics.append(metric("hvf", "container_operation_duration_ms_p50", stats["container_duration_ms_p50"],
                                  "ms", tool=tool, phase=str(action)))
        if guest:
            stats["guest_duration_ms_p50"] = round(statistics.median(guest), 3)
        for key in ("compiles", "downloads", "downloaded", "eacces"):
            total = sum(op.get(key, 0) for op in rows)
            if total:
                stats[key + "_total"] = total
                metrics.append(metric("hvf", key + "_total", total, "count", tool=tool, phase=str(action)))
        operation_stats[f"{tool}.{action}"] = stats
    if latency:
        for key in ("delta_p50", "delta_p95"):
            if isinstance(latency.get(key), (int, float)):
                metrics.append(metric("hvf", "cache_attach_create_start_" + key, latency[key], "ms", phase="create-start"))
        for side in ("off", "on"):
            if isinstance((latency.get(side) or {}).get("p50"), (int, float)):
                metrics.append(metric("hvf", "create_start_seconds_p50", latency[side]["p50"] / 1000.0,
                                      "s", phase=side))
            first = latency.get("first_" + side) or {}
            if isinstance(first.get("total_ms"), (int, float)):
                metrics.append(metric("hvf", "first_container_of_image_ms", first["total_ms"], "ms",
                                      phase="first-" + side))

    evidence = {
        "checks": counts,
        "run_metadata": metadata,
        "coverage": coverage,
        "operation_stats": operation_stats,
        "operations": operations,
        "create_start_latency": {k: latency.get(k) for k in
                                  ("off", "on", "delta_p50", "delta_p95", "first_off", "first_on")} if latency else {},
    }
    return layer_result(assertions, metrics, evidence)


def execute_command(argv, *, env=None, timeout=None):
    print("+ " + " ".join(str(part) for part in argv), flush=True)
    started = time.perf_counter()
    try:
        proc = subprocess.run([str(part) for part in argv], env=env, timeout=timeout)
        error = None if proc.returncode == 0 else f"exited {proc.returncode}"
        code = proc.returncode
    except (OSError, subprocess.TimeoutExpired) as exc:
        error = str(exc)
        code = None
    return {"returncode": code, "error": error, "elapsed_seconds": round(time.perf_counter() - started, 3)}


def execute_json(argv, output: Path, *, env=None, timeout=None):
    result = execute_command(argv, env=env, timeout=timeout)
    error = result["error"]
    data = None
    if output.is_file():
        try:
            data = load_json(output)
        except (OSError, ValueError) as exc:
            error = (error + "; " if error else "") + f"invalid JSON receipt: {exc}"
    elif error is None:
        error = f"receipt missing: {output}"
    result.update(error=error, receipt=data)
    return result


def docker_socket_path(value: str) -> str:
    path = value.removeprefix("unix://")
    if not path.startswith("/"):
        raise ValueError("Docker socket must be an absolute path or unix:// URI")
    return path


def markdown_report(receipt) -> str:
    lines = [
        "# CI cache evaluation",
        "",
        f"- Run: `{receipt['run']}`",
        f"- Captured: `{receipt['captured_utc']}`",
        f"- Revision: `{receipt['revision']}`",
        f"- Overall: **{'PASS' if receipt['passed'] else 'FAIL'}**",
        "",
        "| Layer | Status | Go warm batch | npm warm batch | Key evidence |",
        "| --- | --- | ---: | ---: | --- |",
    ]
    for name, layer in sorted(receipt["layers"].items()):
        warm = {}
        for row in layer["metrics"]:
            if row["name"].startswith("warm_batch_seconds") and row.get("tool") in TOOLS:
                clients = row.get("clients")
                label = str(clients) if clients is not None else "batch"
                warm.setdefault(row["tool"], []).append((label, row["value"], row["unit"]))
        def fmt(tool):
            rows = warm.get(tool) or []
            if not rows:
                return "—"
            return "; ".join(f"{clients}: {value} {unit}" for clients, value, unit in rows)
        evidence = layer.get("evidence") or {}
        keys = []
        if evidence.get("go_cold_to_warm_speedup_x"):
            keys.append(f"Go speedup {evidence['go_cold_to_warm_speedup_x']}x")
        if evidence.get("coverage"):
            cov = evidence["coverage"]
            keys.append("coverage " + ",".join(k for k, v in cov.items() if v))
        if evidence.get("cache_sizes"):
            keys.append("payloads stable")
        if evidence.get("blocks") is not None:
            keys.append(f"{evidence['blocks']} blocks")
        if (evidence.get("buildkit") or {}).get("warm_speedup_x"):
            keys.append(f"BuildKit warm speedup {evidence['buildkit']['warm_speedup_x']}x")
        lines.append(f"| {name} | {layer['status']} | {fmt('go')} | {fmt('npm')} | {'; '.join(keys) or '—'} |")
    lines += ["", "| Layer | Assertions passed | Failed | Skipped/inconclusive |", "| --- | ---: | ---: | ---: |"]
    for name, layer in sorted(receipt["layers"].items()):
        passed = sum(1 for a in layer["assertions"] if a["passed"] is True)
        failed = sum(1 for a in layer["assertions"] if a["passed"] is False)
        skipped = sum(1 for a in layer["assertions"] if a["passed"] is None)
        lines.append(f"| {name} | {passed} | {failed} | {skipped} |")
    failures = [a for layer in receipt["layers"].values() for a in layer["assertions"] if a["passed"] is False]
    if failures:
        lines += ["", "## Failures", ""]
        for row in failures[:30]:
            lines.append(f"- `{row['id']}` — {row['detail']}")
    lines += ["", "The JSON receipt contains the complete assertion list, per-operation timings, cache sizes, payload digests and raw evidence references.", ""]
    return "\n".join(lines)


def initialise_receipt(args) -> dict:
    run = args.run_id or uuid.uuid4().hex
    return {
        "schema": SCHEMA,
        "kind": KIND,
        "run": run,
        "captured_utc": utc_now(),
        "revision": git_revision(),
        "host_platform": platform.platform(),
        "machine": platform.machine(),
        "parameters": {
            "layers": args.layer_names,
            "clients": args.clients,
            "rounds": args.rounds,
        },
        "passed": False,
        "layers": {},
        "metrics": [],
        "assertions": [],
    }


def finish_receipt(receipt):
    all_metrics = []
    all_assertions = []
    passed = bool(receipt["layers"])
    for layer in receipt["layers"].values():
        all_metrics.extend(layer["metrics"])
        assertions = layer["assertions"]
        layer["assertion_summary"] = {
            "passed": sum(1 for row in assertions if row["passed"] is True),
            "failed": sum(1 for row in assertions if row["passed"] is False),
            "inconclusive": sum(1 for row in assertions if row["passed"] is None),
        }
        all_assertions.extend(assertions)
        if layer["status"] != "passed":
            passed = False
    receipt["metrics"] = all_metrics
    receipt["assertions"] = all_assertions
    receipt["passed"] = passed
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--layers", default="host",
                        help="comma-separated subset of host,engine,worker,suite,hvf (default: host)")
    parser.add_argument("--clients", type=int, nargs="+", default=[1, 4])
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--run-id")
    parser.add_argument("--database", type=Path, help="also append the receipt to this benchmark SQLite database")

    parser.add_argument("--host-receipt", type=Path, help="ingest an existing bench_package_caches receipt")
    parser.add_argument("--engine-receipt", type=Path, help="ingest an existing bench_live_kernel receipt")
    parser.add_argument("--worker-receipt", type=Path, help="ingest an existing qualify_ci_worker receipt")
    parser.add_argument("--suite-receipt", type=Path, help="ingest an existing phase-B7 real CI/cache receipt")
    parser.add_argument("--hvf-results", type=Path, help="ingest an existing e2e_hvf_caches output directory")

    parser.add_argument("--engine-socket", help="Docker socket for the engine layer")
    parser.add_argument("--engine-name", help="bench_live_kernel profile such as linux-docker, orbstack, or micropod-worker")
    parser.add_argument("--engine-image", help="small native Linux image used for launch checks")
    parser.add_argument("--package-image", help="offline Go/Node/Python toolchain image")
    parser.add_argument("--build-package-image", action="store_true",
                        help="build scripts/bench_cache_image on the selected engine before measuring")

    parser.add_argument("--micropod", default=None, help="Micropod CLI for the worker layer")
    parser.add_argument("--orbstack-socket", help="optional OrbStack socket for paired worker evidence")
    parser.add_argument("--worker-pipelines", action="store_true", help="include full Go/npm application pipelines")
    parser.add_argument("--pipeline-rounds", type=int, default=2)
    parser.add_argument("--worker-build-package-image", action="store_true",
                        help="let qualify_ci_worker build the offline package image")

    parser.add_argument("--hvf-sections", default="T0 T1 NC T2 T3 T4 T5 T6 T7")
    parser.add_argument("--hvf-tools", default="go npm")
    args = parser.parse_args()

    args.layer_names = [part.strip() for part in args.layers.split(",") if part.strip()]
    valid = {"host", "engine", "worker", "suite", "hvf"}
    if not args.layer_names or any(name not in valid for name in args.layer_names):
        parser.error("--layers must contain only host,engine,worker,suite,hvf")
    if not (1 <= args.rounds <= 20 and all(1 <= n <= 64 for n in args.clients)):
        parser.error("use 1..20 rounds and client counts from 1..64")

    receipt = initialise_receipt(args)
    if args.work_dir:
        work = args.work_dir.resolve()
    else:
        work = args.output.resolve().parent / (args.output.stem + "-" + receipt["run"][:12] + "-evidence")
    work.mkdir(parents=True, exist_ok=True)
    cleanup = None
    receipt["evidence_directory"] = str(work)
    try:
        if "host" in args.layer_names:
            try:
                if args.host_receipt:
                    raw = load_json(args.host_receipt)
                else:
                    out = work / "host-package-caches.json"
                    result = execute_json([sys.executable, ROOT / "scripts/bench_package_caches.py",
                                           "--clients", *args.clients, "--rounds", args.rounds, "--json", out], out)
                    raw = result["receipt"] or {"passed": False, "error": result["error"]}
                receipt["layers"]["host"] = evaluate_host(raw)
                receipt["layers"]["host"]["source_receipt"] = str(args.host_receipt or work / "host-package-caches.json")
            except Exception as exc:
                receipt["layers"]["host"] = layer_result([check("host.evaluator", False, str(exc))], [], {})

        if "engine" in args.layer_names:
            try:
                if args.engine_receipt:
                    raw = load_json(args.engine_receipt)
                else:
                    if not args.engine_socket or not args.engine_image or not args.engine_name or \
                            not (args.package_image or args.build_package_image):
                        raise ValueError("engine layer needs --engine-name, --engine-socket, --engine-image and --package-image (or --build-package-image)")
                    socket = docker_socket_path(args.engine_socket)
                    image = args.package_image
                    if args.build_package_image:
                        tag = args.package_image or "micropod-offline-cache:bench"
                        build = subprocess.run(["docker", "--host", "unix://" + socket, "build",
                                                "--build-arg", "SOURCE_DATE_EPOCH=0", "-t", tag,
                                                str(ROOT / "scripts/bench_cache_image")], timeout=900)
                        if build.returncode:
                            raise RuntimeError(f"package image build exited {build.returncode}")
                        image = tag
                    out = work / "engine-package-caches.json"
                    argv = [sys.executable, ROOT / "scripts/bench_live_kernel.py",
                            "--engine", args.engine_name, "--socket", socket,
                            "--image", args.engine_image, "--package-image", image,
                            "--clients", *args.clients, "--rounds", args.rounds, "--json", out]
                    if args.engine_name == "micropod-worker":
                        if not args.micropod:
                            raise ValueError("engine profile micropod-worker needs --micropod")
                        argv += ["--worker-cli", args.micropod]
                    result = execute_json(argv, out)
                    raw = result["receipt"] or {"passed": False, "error": result["error"]}
                receipt["layers"]["engine"] = evaluate_engine(raw)
                receipt["layers"]["engine"]["source_receipt"] = str(args.engine_receipt or work / "engine-package-caches.json")
            except Exception as exc:
                receipt["layers"]["engine"] = layer_result([check("engine.evaluator", False, str(exc))], [], {})

        if "worker" in args.layer_names:
            try:
                if args.worker_receipt:
                    raw = load_json(args.worker_receipt)
                else:
                    micropod = args.micropod
                    if micropod is None:
                        for candidate in (ROOT / ".build/release/micropod", ROOT / ".build/debug/micropod",
                                          Path(shutil.which("micropod") or "")):
                            if candidate and Path(candidate).is_file():
                                micropod = str(candidate)
                                break
                    if not micropod:
                        raise ValueError("worker layer needs --micropod or a built micropod CLI")
                    out = work / "worker-qualification.json"
                    argv = [sys.executable, ROOT / "scripts/qualify_ci_worker.py", "apple-worker",
                            "--micropod", micropod, "--clients", *args.clients, "--rounds", args.rounds,
                            "--json", out]
                    if args.orbstack_socket:
                        argv += ["--orbstack-socket", args.orbstack_socket]
                    if args.worker_pipelines:
                        argv += ["--pipelines", "--pipeline-rounds", args.pipeline_rounds]
                    if args.worker_build_package_image:
                        argv += ["--packages"]
                    elif args.package_image:
                        argv += ["--package-image", args.package_image]
                    else:
                        raise ValueError("worker layer needs --package-image or --worker-build-package-image")
                    result = execute_json(argv, out)
                    raw = result["receipt"] or {"verified": [], "error": result["error"]}
                receipt["layers"]["worker"] = evaluate_worker(raw)
                receipt["layers"]["worker"]["source_receipt"] = str(args.worker_receipt or work / "worker-qualification.json")
            except Exception as exc:
                receipt["layers"]["worker"] = layer_result([check("worker.evaluator", False, str(exc))], [], {})

        if "suite" in args.layer_names:
            try:
                if args.suite_receipt:
                    raw = load_json(args.suite_receipt)
                else:
                    out = work / "real-ci-cache-suite.json"
                    result = execute_json([sys.executable, ROOT / "scripts/run_real_ci_and_cache_suite.py",
                                           "--out", out], out, timeout=7200)
                    raw = result["receipt"] or {"error": result["error"]}
                receipt["layers"]["suite"] = evaluate_suite(raw)
                receipt["layers"]["suite"]["source_receipt"] = str(args.suite_receipt or work / "real-ci-cache-suite.json")
            except Exception as exc:
                receipt["layers"]["suite"] = layer_result([check("suite.evaluator", False, str(exc))], [], {})

        if "hvf" in args.layer_names:
            try:
                if args.hvf_results:
                    directory = args.hvf_results
                else:
                    directory = work / "hvf-qualification"
                    env = dict(os.environ, QUAL_OUT=str(directory), QUAL_SECTIONS=args.hvf_sections,
                               QUAL_TOOLSET=args.hvf_tools)
                    result = execute_command(["bash", ROOT / "scripts/e2e_hvf_caches.sh"], env=env, timeout=7200)
                    if result["error"] and not (directory / "checks.tsv").is_file():
                        raise RuntimeError(result["error"])
                receipt["layers"]["hvf"] = evaluate_hvf(directory)
                receipt["layers"]["hvf"]["source_receipt"] = str(directory)
            except Exception as exc:
                receipt["layers"]["hvf"] = layer_result([check("hvf.evaluator", False, str(exc))], [], {})
    finally:
        finish_receipt(receipt)
        write_json(args.output, receipt)
        if args.markdown:
            args.markdown.parent.mkdir(parents=True, exist_ok=True)
            args.markdown.write_text(markdown_report(receipt))
        if args.database:
            from ci_benchmark_store import store
            store(args.database, receipt["run"], KIND, receipt)

    print(json.dumps({"run": receipt["run"], "passed": receipt["passed"], "output": str(args.output),
                      "layers": {name: layer["status"] for name, layer in receipt["layers"].items()}}, sort_keys=True))
    return 0 if receipt["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
