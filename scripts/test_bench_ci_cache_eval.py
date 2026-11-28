import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from bench_ci_cache_eval import evaluate_engine, evaluate_host, evaluate_hvf, evaluate_suite, evaluate_worker, finish_receipt, markdown_report
from qualify_ci_worker import bootstrap


class CacheEvalTests(unittest.TestCase):
    def host_receipt(self, **updates):
        row = {
            "passed": True,
            "profile": "package-manager-offline",
            "versions": {"go": "go version", "npm": "11", "node": "v24"},
            "seed": {
                "npm_cache_add_seconds": 0.2,
                "go_download_seconds": 0.01,
                "go_cold_build_seconds": 2.0,
                "go_cold_compiler_or_assembler_invocations": 100,
            },
            "before": {"npm_content": {"files": 1, "logical_bytes": 10}},
            "after": {"npm_content": {"files": 1, "logical_bytes": 10}},
            "median_seconds": {"npm": {"1": 0.12, "4": 0.2}, "go": {"1": 0.08, "4": 0.1}},
            "offline_negative_controls": ["npm", "go"],
            "npm_integrity": "sha512-test",
            "go_zip_sha256": "abc",
            "independent_store": {"npm_content": {"files": 1}},
            "warm_compiler_or_assembler_invocations": 0,
        }
        row.update(updates)
        return row

    def test_host_evaluation_extracts_warm_metrics_and_reuse_assertions(self):
        result = evaluate_host(self.host_receipt())
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["evidence"]["go_cold_to_warm_speedup_x"], 25.0)
        warm = [m for m in result["metrics"] if m["name"] == "warm_batch_seconds_p50"]
        self.assertEqual(len(warm), 4)
        self.assertIn(("go", 4, 0.1), {(m["tool"], m["clients"], m["value"]) for m in warm})

    def test_host_evaluation_fails_when_warm_go_compiles(self):
        result = evaluate_host(self.host_receipt(warm_compiler_or_assembler_invocations=3))
        self.assertEqual(result["status"], "failed")
        self.assertIn("host.go.warm-no-compilation", {a["id"] for a in result["assertions"] if not a["passed"]})

    def test_engine_evaluation_requires_complete_parallel_batches(self):
        raw = {
            "passed": True,
            "boot_sha256": "boot",
            "p50_seconds": {"1": 0.5},
            "package_caches": {
                "passed": True,
                "architecture": "arm64",
                "workload": "offline-npm-go-oci-v1",
                "median_seconds": {"go": {"1": 0.6}, "npm": {"1": 0.9}},
                "blocks": [{
                    "empty_offline_controls": True,
                    "same_payload_inodes": True,
                    "versions": {"go": "go version"},
                    "cold": {"go_cold_build_seconds": 2.0, "go_cold_compiler_or_assembler_invocations": 90},
                    "batches": [
                        {"tool": "go", "clients": 1, "passed": 1, "errors": []},
                        {"tool": "npm", "clients": 1, "passed": 1, "errors": []},
                    ],
                }],
            },
        }
        result = evaluate_engine(raw)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(len([m for m in result["metrics"] if m["name"] == "warm_batch_seconds_p50"]), 2)
        raw["package_caches"]["blocks"][0]["batches"][0]["errors"] = ["boom"]
        self.assertEqual(evaluate_engine(raw)["status"], "failed")

    def test_worker_bootstrap_matches_the_shipped_swift_source(self):
        image, script = bootstrap()
        self.assertRegex(image, r"^docker\.io/library/docker:.*@sha256:[a-f0-9]{64}$")
        self.assertIn("dockerd-entrypoint.sh", script)
        self.assertIn("io.micropod.ci.worker", script)

    def test_worker_evaluation_extracts_scoped_cache_and_pipeline_evidence(self):
        sizes = {"npm_content": {"files": 1, "logical_bytes": 10}, "go_build": {"files": 2, "logical_bytes": 20}}
        raw = {
            "passed": True,
            "verified": ["offline BuildKit cache after restart"],
            "worker": {"worker": "w"},
            "cli_caches": {
                "clients": 4,
                "seed": {
                    "lock": {"npm_integrity": "sha512-test"},
                    "cache_sizes": sizes,
                    "cold": {"npm_cache_add_seconds": 0.2, "go_download_seconds": 0.01, "go_cold_build_seconds": 2.0},
                },
                "warm_seconds": {"npm": 1.2, "go": 0.8},
                "after": sizes,
                "empty_scope_verified": True,
                "restart_reused_payloads": True,
            },
            "build_traces": {"repeat": {"outcomes": {"cached": 2, "executed": 0}}},
            "pipeline_seconds": {"worker": {"first": 40.0, "warm": 12.0, "warm_1": 12.0}},
            "pipeline_stages_seconds": {"worker": {"1": {"npm-test": 2.0}}},
        }
        result = evaluate_worker(raw)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(len(result["assertions"]), 8)
        self.assertTrue(any(m["tool"] == "go" and m["clients"] == 4 and m["value"] == 0.8 for m in result["metrics"]))
        self.assertTrue(any(m["name"] == "full_ci_pipeline_seconds" and m["phase"] == "first" for m in result["metrics"]))
        raw["passed"] = False
        self.assertEqual(evaluate_worker(raw)["status"], "failed")

    def test_suite_evaluation_covers_real_ci_buildkit_and_scoped_caches(self):
        raw = {
            "label": "phase-b7-real-ci-and-caching",
            "buildkit_caching": {
                "cold_build_s": 8.0, "warm_hit_build_s": 1.0, "warm_cached_steps": 6,
                "warm_speedup_x": 8.0, "partial_source_edit_build_s": 1.1,
                "post_reboot_cached_build_s": 2.0, "post_reboot_cached_steps": 6,
                "ci_snapshot_cold_s": 2.1, "ci_snapshot_warm_s": 1.0,
            },
            "scoped_and_workspace_caching": {
                "npm_scope_hit_ok": True, "npm_cross_scope_isolated": True,
                "native_oci_primed_and_gocache_hit_ok": True,
                "virtiofs_make_cold_17_files_ms": 200, "virtiofs_make_noop_0_files_ms": 70,
                "virtiofs_make_1_edited_file_ms": 120,
            },
            "graceful_restart_persistence": {"all_4_caches_persisted": True, "runner_stop_ms": 300,
                                             "runner_restart_with_snapshot_ms": 400},
            "managed_cow_snapshot_pool": {"forks": 3, "all_inherited_warm_caches": True,
                                          "cow_cache_isolation_verified": True, "total_parallel_wall_ms": 3000},
            "compose_postgres_api_integration": {"passed": True, "http_status": 200, "wall_ms": 2000,
                                                 "sql_rows_verified": 2},
        }
        result = evaluate_suite(raw)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(len(result["assertions"]), 8)
        self.assertTrue(any(m["name"] == "buildkit_cold_to_warm_speedup" and m["value"] == 8.0 for m in result["metrics"]))
        raw["scoped_and_workspace_caching"]["npm_cross_scope_isolated"] = False
        self.assertEqual(evaluate_suite(raw)["status"], "failed")

    def test_hvf_parser_combines_checks_probe_results_and_latency(self):
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            (root / "environment.txt").write_text("run=1 root=/tmp/x manual=0 sections=T1 tools=go\n")
            (root / "checks.tsv").write_text(
                "pass\tT4\tauto\tt4-go-warm: the warm rerun hits fully\trc=0 compiles=0\trc=0\n"
                "skip\tT6\tbuild\tskipped build\tmissing\tpresent\n"
            )
            (results / "job.res").write_text(
                "name=job\ntool=go\naction=build\nvariant=a\nuid=0\nrc=0\ncompiles=0\ndownloads=0\n"
                "start=10\nend=12\nQUAL-SENTINEL job\n"
            )
            (results / "job.inspect.json").write_text(json.dumps([{
                "State": {"StartedAt": "2026-01-01T00:00:10.000000000Z", "FinishedAt": "2026-01-01T00:00:12.250000000Z"}
            }]))
            (results / "t7-series.json").write_text(json.dumps({
                "off": {"p50": 100.0}, "on": {"p50": 104.0}, "delta_p50": 4.0, "delta_p95": 7.0
            }))
            (results / "t7-first-on.json").write_text(json.dumps({"total_ms": 130.0, "create_ms": 20.0}))
            result = evaluate_hvf(root)
            self.assertEqual(result["status"], "passed")
            (root / "environment.txt").write_text("run=1 root=/tmp/x manual=1 sections=T1 tools=go\n")
            manual = evaluate_hvf(root)
            self.assertEqual(manual["status"], "failed")
            self.assertIn("hvf.automatic-cache-attachment", {a["id"] for a in manual["assertions"] if a["passed"] is False})
        self.assertEqual(result["evidence"]["checks"]["pass"], 1)
        self.assertTrue(result["evidence"]["coverage"]["go_warm_hit"])
        stats = result["evidence"]["operation_stats"]["go.build"]
        self.assertEqual(stats["container_duration_ms_p50"], 2250.0)
        self.assertEqual(stats["guest_duration_ms_p50"], 2000)
        self.assertTrue(any(m["name"] == "cache_attach_create_start_delta_p95" and m["value"] == 7.0 for m in result["metrics"]))
        self.assertTrue(any(m["name"] == "first_container_of_image_ms" and m["value"] == 130.0 for m in result["metrics"]))

    def test_finish_and_markdown_keep_layer_details_and_flattened_evidence(self):
        layer = evaluate_host(self.host_receipt())
        receipt = {"run": "r", "captured_utc": "now", "revision": "rev", "passed": False,
                   "layers": {"host": layer}, "metrics": [], "assertions": []}
        finish_receipt(receipt)
        self.assertTrue(receipt["passed"])
        self.assertIn("metrics", receipt["layers"]["host"])
        self.assertEqual(receipt["layers"]["host"]["assertion_summary"]["failed"], 0)
        self.assertTrue(receipt["metrics"])
        report = markdown_report(receipt)
        self.assertIn("| host | passed |", report)
        self.assertIn("Go speedup 25.0x", report)


if __name__ == "__main__":
    unittest.main()
