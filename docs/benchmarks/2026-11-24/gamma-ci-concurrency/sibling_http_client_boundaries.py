"""Measure HTTP client response boundaries in a separate unscored dense CI run."""

import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import shutil
import tempfile
from unittest.mock import patch

import build_file_fault_around as kernel
from qualify import HERE, require, terminal
import sibling_file_fault_around as fault
import sibling_file_fault_around_holdout as holdout
import sibling_file_fault_around_holdout_results as holdout_results
import sibling_http_response_phases as response_phases
import sibling_job_parent_evidence as parents
from sibling_log_burst import ARCHIVE, PRODUCTS
import sibling_output_polling as polling
from sibling_worker_volume import mounted_worker_volume


PREFIX = "sibling-http-client-boundaries"
SOURCE = Path(__file__).name
BASE = "quiet-http-boundaries-base.go"
PROBES = "http-client-boundary-probes.json"
PRODUCT = "http-client-boundary-product.json"
DEFAULT_SOURCE = HERE / "20261125T073536Z-sibling-log-notify-holdout-wkwsnm2q/quiet-http.go"
BASE_SHA = "5635d4bcae1b780d2a3cdf9523231300f843657d099d74044d98d217cf21bda2"
SEED = 250283
WINDOW = 65536
PHASES = ("dispatch_to_got_conn", "got_conn_to_wrote_request", "wrote_request_to_first_byte",
          "first_byte_to_do_return", "do_return_to_readall_return", "readall_return_to_close_return",
          "close_return_to_completion")
COMPONENTS = ("total", *PHASES)
TIMESTAMPS = ("got_conn_ns", "wrote_request_ns", "first_response_byte_ns", "do_return_ns",
              "readall_return_ns", "body_close_return_ns", "total_ns")
READBACK = "cat /proc/sys/kernel/random/boot_id\nexec sha256sum -- /mpcheck/quiet-http"


def probe_source(original):
    require(sha256(original).hexdigest() == BASE_SHA, "response boundary probe needs the sealed stock HTTP source")
    fields = b'\tFirstByteNS int64  `json:"first_response_byte_ns"`\n'
    extra = b'''\tDoReturnNS int64 `json:"do_return_ns"`
\tReadAllReturnNS int64 `json:"readall_return_ns"`
\tBodyCloseReturnNS int64 `json:"body_close_return_ns"`
'''
    edits = [(fields, fields + extra)]
    for line, field in (
        (b"\t\tresponse, err = client.Do(req)\n", b"DoReturnNS"),
        (b"\t\t\tbody, err = io.ReadAll(io.LimitReader(response.Body, int64(len(marker)+1)))\n", b"ReadAllReturnNS"),
        (b"\t\t\tresponse.Body.Close()\n", b"BodyCloseReturnNS"),
    ):
        indentation = line[:len(line) - len(line.lstrip(b"\t"))]
        edits.append((line, line + indentation + b"sample." + field + b" = time.Since(start).Nanoseconds()\n"))
    for before, after in edits:
        require(original.count(before) == 1, "unexpected stock HTTP source boundary")
        original = original.replace(before, after, 1)
    return original


def sample_phases(sample, arrival=None):
    values = [0, *(sample.get(key) for key in TIMESTAMPS)]
    require(all(type(value) is int for value in values) and 0 < values[1]
            and all(a <= b for a, b in zip(values, values[1:])), "invalid HTTP client boundary sequence")
    total = values[-1]
    if arrival is not None:
        require(total == arrival["completion_offset_ns"] - arrival["dispatch_offset_ns"],
                "HTTP client phase total disagrees with paced request edges")
    return total, *(b - a for a, b in zip(values, values[1:]))


def image(worker):
    arena, product_sha, runner_sha = PRODUCTS[worker]
    product = kernel.BASE / f"ci-published-link-{arena}" / "product.json"
    require(terminal.digest(product) == product_sha, "selected worker product differs")
    return product, product_sha, runner_sha


def capture_cli(cohort, slot=0):
    return ["exec", cohort.jobs[cohort.count + slot]["id"], "/bin/sh", "-ec", READBACK]


def check_capture(row, job, boot, digest):
    require(row["argv"] == ["exec", job["id"], "/bin/sh", "-ec", READBACK]
            and row["stdout"].splitlines() == [boot, f"{digest}  /mpcheck/quiet-http"],
            "guest did not see the staged observer binary")


def run(args):
    args.product, product_sha, runner_sha = image(args.worker)
    args.fault_around_bytes = WINDOW
    original = args.quiet_source.read_bytes()
    derived = probe_source(original)
    selected = args.ipvlan_kernel / "full-16k"
    require(terminal.digest(selected / "Image") == kernel.EXPECTED_IMAGE
            and terminal.digest(selected / "config") == kernel.EXPECTED_CONFIG, "expected the sealed 16 KiB kernel")
    manifest = polling.products.read(HERE / polling.products.MANIFEST)
    go = Path(manifest["toolchain"]["path"])
    _, tools = polling.products.toolchain(go)
    require(tools == manifest["toolchain"], "protected HTTP study needs the sealed Go toolchain")
    env = {**os.environ, "PATH": f"{go.parent}:{os.environ['PATH']}"}
    env.pop("GOROOT", None)
    base_stage, base_capture = holdout.stage, parents.capture
    witnessed = {}

    def stage(oci, work, folder, selected):
        fields = base_stage(oci, work, folder, selected)
        shutil.copyfile(Path(__file__), folder / SOURCE)
        shutil.copyfile(args.product, folder / PRODUCT)
        (folder / BASE).write_bytes(original)
        for location in (folder, work / "probe"):
            (location / polling.RUNNER_READ).write_text(polling.ENGINE_READER)
        require(terminal.digest(oci / "runner/start.sh") == polling.START_SHA, "private worker bootstrap changed")
        return {**fields, "http_client_boundary_diagnostic": True, "http_client_boundary_worker": args.worker,
                "http_client_boundary_toolchain": tools, "http_client_boundary_product_sha256": product_sha,
                "http_client_boundary_sources": {name: terminal.digest(folder / name)
                                                 for name in (SOURCE, BASE, polling.RUNNER_READ)}}

    def capture(folder, cohorts, phase):
        base_capture(folder, cohorts, phase)
        boots = parents.boots(folder)
        native = cohorts["A"]
        name = polling.readback_name(phase)
        shutil.copyfile(native.work / name, folder / name)
        engine = polling.engine_readback(folder / name, boots["A"], runner_sha)
        if phase == "after":
            require(engine == polling.engine_readback(folder / polling.readback_name("before"), boots["A"], runner_sha),
                    "native engine changed during the HTTP boundary diagnostic")
        digest = parents.read(folder, "plan.json")["quiet_sha256"]
        witnessed[phase] = {}
        for arm, cohort in cohorts.items():
            argv = capture_cli(cohort)
            row = {"argv": argv, "stdout": cohort.cmd(*argv, timeout=12)}
            check_capture(row, cohort.jobs[cohort.count], boots[arm], digest)
            witnessed[phase][arm] = row
        terminal.save(folder / PROBES, witnessed)

    with tempfile.TemporaryDirectory(prefix="http-client-boundaries-") as temp:
        args.quiet_source = Path(temp) / "quiet-http.go"
        args.quiet_source.write_bytes(derived)
        with patch.dict(os.environ, env, clear=True), mounted_worker_volume(), \
                patch.object(holdout, "PREFIX", PREFIX), patch.object(holdout, "SEED_ORDER", {args.seed: (WINDOW,)}), \
                patch.object(holdout, "stage", stage), patch.object(parents, "capture", capture), \
                patch.object(fault, "boot_hook", polling.boot_hook):
            holdout.run(args)


def replay(folder):
    plan = parents.read(folder, "plan.json")
    worker = plan["http_client_boundary_worker"]
    _, product_sha, runner_sha = PRODUCTS[worker]
    require(plan["http_client_boundary_diagnostic"] is True and plan["file_fault_around_bytes"] == WINDOW
            and plan["rounds"] == 4 and plan["offered_rps"] == 64_000 and plan["dense_ms"] == 1500
            and plan["network_topology"] == "per-job" and plan["worker_scheduler"] == "hrtick-250us"
            and plan["pages"]["kernel_image_sha256"] == kernel.EXPECTED_IMAGE
            and plan["pages"]["kernel_config_sha256"] == kernel.EXPECTED_CONFIG
            and plan["http_client_boundary_product_sha256"] == terminal.digest(folder / PRODUCT) == product_sha
            and plan["http_client_boundary_sources"] == {name: terminal.digest(folder / name)
                                                         for name in (SOURCE, BASE, polling.RUNNER_READ)}
            and parents.read(folder, "worker-build.json") == parents.read(folder, PRODUCT)
            and (folder / polling.RUNNER_READ).read_text() == polling.ENGINE_READER
            and (folder / "quiet-http.go").read_bytes() == probe_source((folder / BASE).read_bytes()),
            "unexpected HTTP response boundary protocol or changes outside the time stamps")
    boots = parents.boots(folder)
    before, after = (polling.engine_readback(folder / polling.readback_name(phase), boots["A"], runner_sha)
                     for phase in ("before", "after"))
    require(before == after, "running native engine changed")
    inventory = parents.read(folder, "grouped-inventory.json")
    probes = parents.read(folder, PROBES)
    require(set(probes) == {"before", "after"}, "missing HTTP probe readback")
    for values in probes.values():
        require(set(values) == {"A", "B"}, "probe needs both guest boot and binary readbacks")
        for arm, row in values.items():
            check_capture(row, inventory[arm]["jobs"][32], boots[arm], plan["quiet_sha256"])

    collector = response_phases.TraceCollector(folder)

    def read_wire(path, tag):
        rows = collector.read_wire(path, tag)
        for row in rows:
            receipt = row["receipt"]
            sample_phases(receipt["warmup"])
            if not response_phases.DENSE.fullmatch(tag):
                for sample in receipt["samples"]:
                    sample_phases(sample)
        return rows

    with patch.multiple(response_phases, PHASES=PHASES, COMPONENTS=COMPONENTS, sample_phases=sample_phases), \
            patch.object(response_phases.PACED, "read_wire", read_wire):
        qualified = holdout_results.verified_run(folder, plan)
        require(not collector.pending and collector.breakdown.keys() == set(range(4)), "missing paired dense HTTP waves")
        waves = []
        for index, wave in enumerate(qualified["rows"]):
            groups = collector.breakdown[index]
            require(all(groups["all"]["service_p95_request"][engine]["duration_ns"]["total"] / 1_000
                        == wave[arm]["service_p95_us"] for arm, engine in response_phases.ENGINES.items()),
                    "HTTP phase rank does not agree with warmed-socket replay")
            waves.append({"round": index, "engine_order": wave["order"], "groups": groups})
        aggregate = response_phases.pool(waves)
    return {"diagnostic_only": True, "archive": folder.name, "worker": worker, "runner_sha256": runner_sha,
            "boot_ids": boots, "completed_offers": qualified["run"]["totals"]["completed_requests"],
            "stock_build_jobs": qualified["run"]["totals"]["jobs"], "components": COMPONENTS,
            "phase_selection": {"own_p95_band": "Independent 94th–96th percentile by engine and group",
                                "same_offers_slowest_5pct_union": "Same offer ordinal in both engines, worst in either"},
            "aggregate": aggregate, "windows": waves, "raw_http_sha256": collector.hashes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    live = commands.add_parser("run")
    live.add_argument("--worker", choices=PRODUCTS, default="log-notify")
    live.add_argument("--seed", type=int, default=SEED)
    live.add_argument("--quiet-source", type=Path, default=DEFAULT_SOURCE)
    live.add_argument("--image-archive", type=Path, default=ARCHIVE)
    live.add_argument("--page-kernel-pair", type=Path, default=kernel.STOCK_KERNEL)
    live.add_argument("--ipvlan-kernel", type=Path, default=kernel.IPVLAN_KERNEL)
    offline = commands.add_parser("replay")
    offline.add_argument("folder", type=Path)
    args = parser.parse_args()
    if args.command == "run":
        run(args)
    else:
        print(json.dumps(replay(args.folder.resolve()), indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
