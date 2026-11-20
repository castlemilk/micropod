#!/usr/bin/env python3
"""Append local CI benchmark receipts to SQLite and query all measured batches with SQL."""
import argparse
from contextlib import nullcontext
from datetime import datetime, timezone
import gzip
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import sys

DEFAULT_DB = Path.home() / ".micropod" / "benchmarks" / "measurements.sqlite3"


def store(path, run, kind, record):
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path, timeout=30) as db:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS measurements (
                run TEXT NOT NULL, kind TEXT NOT NULL, captured_utc TEXT NOT NULL,
                receipt TEXT NOT NULL CHECK(json_valid(receipt)), PRIMARY KEY(run, kind)
            );
            CREATE VIEW IF NOT EXISTS go_batches AS
                SELECT run, b.value->>'round' AS round, b.value->>'mode' AS mode,
                       b.value->>'clients' AS clients, b.value->>'seconds' AS seconds, b.value AS batch
                FROM measurements, json_each(receipt, '$.batches') b WHERE kind='go-kernel-profile';
            CREATE VIEW IF NOT EXISTS go_jobs AS
                SELECT run, round, mode, clients, j.value->>'job' AS job, j.value->>'client_s' AS client_s,
                       j.value->>'build_s' AS build_s, j.value AS detail
                FROM go_batches, json_each(batch,'$.jobs') j;
            CREATE VIEW IF NOT EXISTS go_phases AS
                SELECT run, round, mode, clients, job, client_s, build_s,
                       ((detail->>'build_start_ns') - (detail->>'python_entry_ns')) / 1e9 AS harness_s,
                       detail->>'verify_s' AS verify_s, detail->>'cleanup_s' AS cleanup_s,
                       detail->>'$.engine_phase_s.create_to_start' AS create_to_start_s,
                       detail->>'$.engine_phase_s.die_to_destroy' AS remove_s,
                       detail->>'$.cpu_stat.throttled_usec' AS build_throttled_us
                FROM go_jobs;
            CREATE VIEW IF NOT EXISTS fresh_go_runs AS
                SELECT run, captured_utc, receipt->>'passed' AS passed, receipt->>'error' AS error,
                       coalesce(receipt->>'suite','oci') AS suite, receipt->>'cli_sha256' AS cli_sha256
                FROM measurements WHERE kind='fresh-go';
            CREATE VIEW IF NOT EXISTS fresh_go_batches AS
                SELECT run, b.value->>'engine' AS engine, b.value->>'mode' AS mode, b.value->>'round' AS round,
                       b.value->>'clients' AS clients, b.value->>'seconds' AS seconds,
                       b.value->>'host_wall_s' AS host_wall_s, b.value AS batch
                FROM measurements, json_each(receipt, '$.batches') b WHERE kind='fresh-go';
            CREATE VIEW IF NOT EXISTS fresh_go_jobs AS
                SELECT run, engine, mode, round, clients, j.value->>'container' AS container,
                       j.value->>'client_s' AS client_s, j.value->>'link' AS linker_invocations,
                       ((j.value->>'$.lifecycle_ns.start') - (j.value->>'$.lifecycle_ns.create'))/1e9 AS create_start_s,
                       ((j.value->>'$.lifecycle_ns.die') - (j.value->>'$.lifecycle_ns.start'))/1e9 AS running_s,
                       ((j.value->>'$.lifecycle_ns.destroy') - (j.value->>'$.lifecycle_ns.die'))/1e9 AS remove_s
                FROM fresh_go_batches, json_each(batch,'$.jobs') j;
            CREATE VIEW IF NOT EXISTS native_go_batches AS
                SELECT run, b.value->>'mode' AS mode, b.value->>'round' AS round, b.value->>'clients' AS clients,
                       b.value->>'seconds' AS seconds, b.value->>'prepare_s' AS prepare_s, b.value->>'links' AS links
                FROM measurements, json_each(receipt, '$.batches') b WHERE kind='fresh-go-ubuntu';
            CREATE VIEW IF NOT EXISTS go_preparation_batches AS
                SELECT run, b.value->>'round' AS round, b.value->>'clients' AS clients, b.value->>'seconds' AS seconds,
                       b.value->>'repeat_s' AS repeat_s, json_array_length(b.value,'$.creates') AS builds,
                       b.value->>'$.jobs[0].image' AS image
                FROM measurements, json_each(receipt, '$.batches') b WHERE kind='go-output-preparation';
            CREATE VIEW IF NOT EXISTS startup_batches AS
                SELECT run,receipt->>'mode' AS series,receipt->>'passed' AS passed,b.value->>'engine' AS engine,
                       b.value->>'round' AS round,b.value->>'clients' AS clients,b.value->>'seconds' AS seconds,b.value AS batch
                FROM measurements,json_each(receipt,'$.batches') b WHERE kind='source-startup';
            CREATE VIEW IF NOT EXISTS startup_jobs AS
                SELECT run,series,passed,engine,round,clients,j.value->>'container' AS container,j.value->>'link' AS links,
                       ((j.value->>'$.phases_ns.task_create')-(j.value->>'$.phases_ns.metadata'))/1e9 AS metadata_to_task_s,
                       ((j.value->>'$.phases_ns.task_start')-(j.value->>'$.phases_ns.task_create'))/1e9 AS task_start_s,
                       j.value->>'$.lifecycle.setup_ns'/1e9 AS oci_setup_s,j.value->>'$.lifecycle.runtime_ns'/1e9 AS oci_runtime_and_job_s,
                       j.value->>'$.lifecycle.cleanup_ns'/1e9 AS oci_cleanup_s,j.value->'$.runc' AS sampled_runc
                FROM startup_batches,json_each(batch,'$.jobs') j;
            CREATE VIEW IF NOT EXISTS direct_oci_profile AS
                SELECT run,round,clients,j.value->>'container' AS container,
                       ((j.value->>'entry')-(j.value->>'$.lifecycle.begin_ns')-(j.value->>'$.lifecycle.setup_ns'))/1e9 AS runtime_to_entry_s,
                       j.value->>'$.cgroup.usage_usec'/1e6 AS cpu_s,
                       j.value->>'$.cgroup.cpu_pressure_usec'/1e6 AS cpu_stall_s,
                       j.value->>'$.cgroup.io_pressure_usec'/1e6 AS io_stall_s,
                       j.value->>'$.cgroup.throttled_usec'/1e6 AS throttled_s
                FROM startup_batches,json_each(batch,'$.jobs') j WHERE series='direct-trace';
            CREATE VIEW IF NOT EXISTS native_oci_jobs AS
                SELECT run,series,engine,round,clients,seconds AS batch_s,
                       j.value->>'container' AS container,j.value->>'link' AS links,
                       coalesce(j.value->>'$.lifecycle.queue_ns',0)/1e6 AS admission_ms,
                       ((j.value->>'$.lifecycle.setup_ns')-coalesce(j.value->>'$.lifecycle.queue_ns',0))/1e6 AS setup_ms,
                       ((j.value->>'entry')-(j.value->>'$.lifecycle.begin_ns')-(j.value->>'$.lifecycle.setup_ns'))/1e6 AS runtime_to_entry_ms,
                       j.value->>'$.cgroup.cpu_pressure_usec'/1e3 AS cpu_stall_ms,
                       j.value->>'$.cgroup.io_pressure_usec'/1e3 AS io_stall_ms,
                       j.value->>'$.cgroup.usage_usec'/1e3 AS cpu_ms,
                       j.value->>'$.cgroup.nr_throttled' AS throttled,j.value->>'cpuset' AS cpuset,
                       j.value->>'scheduler' AS scheduler,j.value->>'$.lifecycle.cleanup_ns'/1e6 AS cleanup_ms
                FROM startup_batches,json_each(batch,'$.jobs') j
                WHERE passed AND series IN ('native-tune','native-paired') AND engine LIKE 'direct-%';
            CREATE VIEW IF NOT EXISTS kernel_batches AS
                SELECT run, round, mode, clients, seconds, batch->>'$.kernel_delta.sampled_s' AS sampled_s,
                       batch->>'$.kernel_delta.tracepoints.ext4_sync_file_enter' AS ext4_syncs,
                       batch->>'$.kernel_delta.tracepoints.lost_events' AS lost_trace_events,
                       (batch->>'$.kernel_delta.disk.vdb.write_sectors') * 512 AS disk_write_bytes,
                       batch->>'$.kernel_delta.disk.vdb.flushes' AS disk_flushes,
                       batch->>'$.kernel_delta.pressure_us.cpu.some' AS cpu_stall_us,
                       batch->>'$.kernel_delta.pressure_us.io.some' AS io_stall_us
                FROM go_batches;
            CREATE VIEW IF NOT EXISTS kernel_samples AS
                SELECT run, s.value->>'client_s' AS elapsed_s, s.value AS counters
                FROM measurements, json_each(receipt, '$.samples') s WHERE kind='go-kernel-profile';
            CREATE VIEW IF NOT EXISTS cache_stores AS
                SELECT run, receipt->>'timestamp' AS sampled, receipt->>'boot' AS boot,
                       s.value->>'scope' AS scope, s.value->>'store' AS store,
                       s.value->>'activeContainers' AS active_containers, s.value->>'bytes' AS bytes
                FROM measurements, json_each(receipt, '$.cacheStores') s WHERE kind='worker-metrics';
            CREATE VIEW IF NOT EXISTS native_oci_cache AS
                SELECT run,receipt->>'timestamp' AS sampled,receipt->>'boot' AS boot,
                       receipt->>'$.nativeOCI.openedSessions' AS session_requests,
                       receipt->>'$.nativeOCI.activeSessions' AS active_sessions,
                       receipt->>'$.nativeOCI.prepareHits' AS warm_prepares,
                       receipt->>'$.nativeOCI.prepareLoads' AS cold_prepares,
                       receipt->'$.nativeOCI.sessionsByScope' AS active_by_scope
                FROM measurements WHERE kind='worker-metrics' AND json_type(receipt,'$.nativeOCI')='object';
            CREATE VIEW IF NOT EXISTS build_steps AS
                SELECT run, s.value->>'digest' AS digest, s.value->>'position' AS position,
                       s.value->>'operation' AS operation, s.value->>'outcome' AS outcome,
                       s.value->>'started' AS started, s.value->>'completed' AS completed
                FROM measurements, json_each(receipt, '$.steps') s WHERE kind='buildkit-trace';
            CREATE VIEW IF NOT EXISTS full_ci_stages AS
                SELECT run, receipt->>'passed' AS passed, b.value->>'round' AS round, b.value->>'engine' AS engine,
                       b.value->>'revision' AS revision, b.value->>'mode' AS mode, b.value->>'seconds' AS batch_s,
                       s.key AS stage, s.value AS stage_s
                FROM measurements, json_each(receipt,'$.batches') b, json_each(b.value,'$.stages') s
                WHERE kind='full-ci-pipeline';
            CREATE VIEW IF NOT EXISTS go_suite_batches AS
                SELECT run, receipt->>'passed' AS passed, b.value->>'round' AS round, b.value->>'engine' AS engine,
                       b.value->>'mode' AS mode, b.value->>'clients' AS clients, b.value->>'seconds' AS seconds,
                       b.value AS batch
                FROM measurements, json_each(receipt,'$.batches') b WHERE kind='go-ci-suite';
            CREATE VIEW IF NOT EXISTS go_suite_jobs AS
                SELECT run, engine, mode, round, clients, seconds AS batch_s, j.value->>'job' AS job,
                       j.value->>'tests' AS tests, j.value->>'sha256' AS product,
                       j.value->>'$.phase_s.vet' AS vet_s, j.value->>'$.phase_s.tests' AS tests_s,
                       j.value->>'$.phase_s.build' AS build_s, j.value->>'$.phase_s.verified' AS verify_s,
                       j.value->>'$.lifecycle.setup_ns'/1e6 AS setup_ms,
                       j.value->>'$.lifecycle.cleanup_ns'/1e6 AS cleanup_ms
                FROM go_suite_batches, json_each(batch,'$.jobs') j WHERE passed;
            CREATE VIEW IF NOT EXISTS go_suite_first_revisions AS
                SELECT run, b.value->>'round' AS round, b.value->>'mode' AS mode, b.value->>'clients' AS clients,
                       b.value->>'seconds' AS total_s, b.value->>'snapshot_s' AS snapshot_s,
                       b.value->>'prepare_s' AS prepare_s, b.value->>'handle_s' AS handle_s,
                       b.value->>'session_s' AS session_s, b.value->>'jobs_s' AS jobs_s
                FROM measurements, json_each(receipt,'$.batches') b
                WHERE kind='go-ci-first-revision' AND receipt->>'passed';
            CREATE VIEW IF NOT EXISTS go_suite_kernel_jobs AS
                SELECT run, b.value->>'mode' AS mode, b.value->>'clients' AS clients, j.value->>'job' AS job,
                       j.value->>'$.cgroup.scheduler' AS scheduler, j.value->>'$.cgroup.usage_usec'/1e3 AS cpu_ms,
                       j.value->>'$.cgroup.cpu_pressure_usec'/1e3 AS cpu_stall_ms,
                       j.value->>'$.cgroup.io_pressure_usec'/1e3 AS io_stall_ms,
                       j.value->>'$.cgroup.nr_throttled' AS quota_throttles
                FROM measurements, json_each(receipt,'$.traces') b, json_each(b.value,'$.jobs') j
                WHERE kind='go-ci-first-revision' AND receipt->>'passed';
            CREATE VIEW IF NOT EXISTS pipeline_stages AS
                SELECT run, engine.key AS engine, phase.key AS phase, stage.key AS stage, stage.value AS seconds
                FROM measurements, json_each(receipt, '$.pipeline_stages_seconds') engine,
                     json_each(engine.value) phase, json_each(phase.value) stage;
            CREATE VIEW IF NOT EXISTS paired_runs AS
                SELECT run, captured_utc, receipt->>'$.blocks[0].package_caches.workload' AS cache_workload
                FROM measurements WHERE kind='apple-pair';
            CREATE VIEW IF NOT EXISTS paired_batches AS
                SELECT run, e.value->>'engine' AS engine, e.value->>'block' AS round, 'launch' AS workload,
                       b.value->>'clients' AS clients, b.value->>'seconds' AS seconds
                FROM measurements, json_each(receipt,'$.blocks') e, json_each(e.value,'$.batches') b
                WHERE kind='apple-pair'
                UNION ALL
                SELECT run, e.value->>'engine', e.value->>'block', b.value->>'tool',
                       b.value->>'clients', b.value->>'seconds'
                FROM measurements, json_each(receipt,'$.blocks') e,
                     json_each(e.value,'$.package_caches.blocks') p, json_each(p.value,'$.batches') b
                WHERE kind='apple-pair';
        """)
        payload = json.dumps(record, separators=(",", ":"), sort_keys=True)
        saved = db.execute("INSERT INTO measurements VALUES (?, ?, ?, ?) ON CONFLICT(run, kind) DO NOTHING",
                           (run, kind, datetime.now(timezone.utc).isoformat(), payload))
        if saved.rowcount == 0:
            existing, = db.execute("SELECT receipt FROM measurements WHERE run=? AND kind=?", (run, kind)).fetchone()
            if json.loads(existing) != json.loads(payload):
                raise ValueError("A different receipt already uses this run ID")


def read_buildkit_trace(stream):
    """Read Dockerfile step outcomes from buildx rawjson, omitting command output and arguments."""
    source = hashlib.sha256()
    steps = {}
    saw_vertex = False
    dockerfile_step = re.compile(r"^\[([^\]]*?\d+/\d+)\] ([A-Z]+)\b")
    for line in stream:
        source.update(line)
        if not line.strip():
            continue
        for v in json.loads(line).get("vertexes", []):
            saw_vertex = True
            match = dockerfile_step.match(v.get("name", ""))
            if not match or match[2] == "FROM":
                continue
            step = steps.setdefault(v["digest"], dict(digest=v["digest"], position=match[1],
                                                     operation=match[2], outcome="pending"))
            if v.get("started"):
                step["started"] = v["started"]
            if v.get("completed"):
                step["completed"] = v["completed"]
                step["outcome"] = "cached" if v.get("cached") else "executed"
            if v.get("error"):
                step["outcome"] = "failed"
    if not saw_vertex:
        raise ValueError("Expected Docker Buildx --progress=rawjson solve events")
    run = source.hexdigest()
    record = dict(steps=list(steps.values()),
                  outcomes={state: sum(step["outcome"] == state for step in steps.values())
                            for state in ("cached", "executed", "failed", "pending")})
    return run, record


def store_receipt(path, kind, data):
    record = json.loads(data)
    run = record.get("run") or hashlib.sha256(data).hexdigest()
    store(path, run, kind, record)
    if kind == "apple-qualification" and record.get("paired", {}).get("blocks"):
        store(path, run, "apple-pair", record["paired"])
    return run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", help="For example apple-pair, worker-metrics, buildkit-trace, or ubuntu-reference")
    parser.add_argument("files", type=Path, nargs="+")
    parser.add_argument("--database", type=Path, default=DEFAULT_DB)
    args = parser.parse_args()
    for path in args.files:
        if path == Path("-"):
            source = nullcontext(sys.stdin.buffer)
        elif path.suffix == ".gz":
            source = gzip.open(path, "rb")
        else:
            source = path.open("rb")
        with source as stream:
            if args.kind == "buildkit-trace":
                run, record = read_buildkit_trace(stream)
                store(args.database, run, args.kind, record)
            else:
                run = store_receipt(args.database, args.kind, stream.read())
        print(run, args.kind, args.database)


if __name__ == "__main__":
    main()
