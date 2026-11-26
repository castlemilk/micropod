"""Run the stock dense CI workload against the sealed output follower pair."""

import argparse
import os
from pathlib import Path
import re
import shutil
from unittest.mock import patch

import file_fault_around_common as knob
from qualify import HERE, require, terminal
import sibling_file_fault_around as fault
import sibling_file_fault_around_holdout as holdout
import sibling_group
import sibling_job_parent_evidence as parents
import sibling_output_polling_product as products
import sibling_tmpfs
from sibling_worker_volume import mounted_worker_volume


SEED_ORDER = {250271: products.MODES, 250273: products.MODES[::-1]}
PREFIX = "sibling-output-polling"
DRIVER = "sibling_output_polling.py"
PACKAGER = "sibling_output_polling_product.py"
RUNNER_READ = "output-polling-engine-read.sh"
START = "output-polling-start.sh"
START_SHA = "19515f373abf0a7775cb32457a8686cd20b9e43356936904a4faf968eea114e3"
TESTS = "linux-cri-output-tests.txt"
TEST_PATTERN = "^TestCRI(Output|Follow)"
TEST_NAMES = {"TestCRIOutputRecordBoundaries", "TestCRIOutputErrorsAndLimit", "TestCRIFollowStreamsWhileWaitingForTask",
              "TestCRIFollowWaitRechecksUncommittedExit", "TestCRIFollowCancelsTaskWait"}
SUBTESTS = {f"TestCRIFollowWaitRechecksUncommittedExit/{name}" for name in ("OK", "NotFound", "Unavailable")}
SOURCES = (DRIVER, PACKAGER, RUNNER_READ, START)
WINDOW = knob.DEFAULT_BYTES
JOB = "/opt/micropod-oci/runner/bin/job"
STOCK_HOOK = fault.boot_hook
ENGINE_READER = r'''set -eu
[ "$(id -u)" = 0 ]
boot=$(cat /proc/sys/kernel/random/boot_id)
candidate=
for pid in $(pidof job); do
    proc="/proc/$pid"
    exe=$(readlink "$proc/exe" 2>/dev/null) || continue
    [ "$exe" = /opt/micropod-oci/runner/bin/job ] || continue
    argv=$(tr '\000' ' ' < "$proc/cmdline") || continue
    [ "$argv" = "$exe engine " ] || continue
    [ -z "$candidate" ] || { echo "Ambiguous live native Docker engine" >&2; exit 1; }
    candidate=$pid
done
[ -n "$candidate" ] || { echo "Native Docker engine process missing" >&2; exit 1; }
proc="/proc/$candidate"
exe=$(readlink "$proc/exe")
argv=$(tr '\000' ' ' < "$proc/cmdline")
birth=$(awk '{print $22}' "$proc/stat")
hash=$(sha256sum "$proc/exe")
set -- $hash
[ "$exe" = /opt/micropod-oci/runner/bin/job ] && [ "$argv" = "$exe engine " ]
printf 'boot_id=%s\npid=%s\nbirth_ticks=%s\nexe=%s\nargv=%s\nrunner_sha256=%s\n' \
    "$boot" "$candidate" "$birth" "$exe" "$argv" "$1"
'''


def readback_name(phase):
    return f"output-polling-engine-{phase}.txt"


def boot_hook():
    anchor = '''        printf '%s\\n' "$result" > "$output-status.tmp"\n'''
    source = STOCK_HOOK()
    require(source.count(anchor) == 1, "unknown stock native root observer")
    extra = '''        if [ "$result" = 0 ]; then
            engine="$workspace/output-polling-engine-$phase.txt"
            /bin/sh "$workspace/probe/output-polling-engine-read.sh" > "$engine.tmp" || result=$?
            if [ "$result" = 0 ]; then mv "$engine.tmp" "$engine"; fi
        fi
'''
    return source.replace(anchor, extra + anchor, 1)


def engine_readback(path, boot, expected):
    pairs = [line.split("=", 1) for line in path.read_text().splitlines()]
    row = dict(pairs)
    require(len(row) == len(pairs) and row == {
        "boot_id": boot, "pid": row["pid"], "birth_ticks": row["birth_ticks"],
        "exe": JOB, "argv": JOB + " engine ", "runner_sha256": expected,
    } and re.fullmatch(knob.BOOT_ID, boot) and int(row["pid"]) > 1 and int(row["birth_ticks"]) > 0,
        "native process is not the sealed Docker engine")
    return row


def check_tests(output):
    lines = output.strip().splitlines()
    started = [line.removeprefix("=== RUN   ") for line in lines if line.startswith("=== RUN   ")]
    expected = TEST_NAMES | SUBTESTS
    require(set(started) == expected and len(started) == len(expected), "missing targeted CRI output or exit-wait tests")
    sibling_tmpfs.check_linux_tests(output, TEST_NAMES)
    passed = {m[1] for line in lines if (m := re.match(r"\s*--- PASS: (\S+) \(", line))}
    require(passed == expected, "one or more targeted CRI exit-repair subtests did not pass")
    return started


def verify(folder, plan, boots, manifest, product, receipt):
    mode = plan["output_polling"]
    require(mode in SEED_ORDER.get(plan["seed"], ()) and plan["file_fault_around_bytes"] == WINDOW and
            plan["host_worker_volume"] == "apfs-no-index" and plan["host_worker_volume_final_history"] is True and
            "ttwu_queue" not in plan and "ttwu_diagnostic" not in plan and
            plan["output_polling_runner_sha256"] == receipt["runner_sha256"] and
            plan["output_polling_product_sha256"] == receipt["product_sha256"] and
            plan["output_polling_manifest_sha256"] == terminal.digest(folder / products.MANIFEST) and
            plan["output_polling_build_manifest_sha256"] == terminal.digest(folder / products.ARM) and
            plan["output_polling_test_product_sha256"] == manifest["arms"]["optimized"]["product_sha256"] and
            products.read(folder / products.MANIFEST) == manifest and products.read(folder / products.ARM) == receipt and
            terminal.digest(folder / products.DELTA) == receipt["delta_sha256"] and
            parents.read(folder, "worker-build.json") == product, "wrong worker, output polling arm or build receipt")
    require(plan["output_polling_sources"] == {name: terminal.digest(folder / name) for name in SOURCES}
            and plan["output_polling_sources"][START] == START_SHA
            and (folder / RUNNER_READ).read_text() == ENGINE_READER and
            (folder / parents.BOOT_HOOK).read_text() == boot_hook() and
            all(terminal.digest(folder / "output-polling-src" / name) == product["compiled_sources"][name]
                for name in products.ALLOWED), "output follower or live boot observer source differs")
    before, after = (engine_readback(folder / readback_name(phase), boots["A"], receipt["runner_sha256"])
                     for phase in ("before", "after"))
    require(before == after, "native Docker engine exited or changed during stock CI")
    tests = check_tests((folder / TESTS).read_text())
    return {"output_polling": mode, "native_engine": before, "linux_tests": tests}


def run(args):
    mode = args.output_polling
    manifest = products.read(args.manifest)
    path, product, receipt = products.check_arm(manifest, mode)
    test_product, _, _ = products.check_arm(manifest, "optimized")
    go = Path(manifest["toolchain"]["path"])
    _, compiler = products.toolchain(go)
    require(compiler == manifest["toolchain"], "live fixture Go toolchain differs from the sealed build")
    args.product, args.fault_around_bytes = path, WINDOW
    env = {**os.environ, "PATH": f"{go.parent}:{os.environ['PATH']}"}
    env.pop("GOROOT", None)
    stage, capture, verify_holdout, group_stage = holdout.stage, parents.capture, holdout.verify, sibling_group.stage

    def setup(oci, work, folder, selected):
        fields = stage(oci, work, folder, selected)
        for source, name in ((Path(__file__), DRIVER), (Path(products.__file__), PACKAGER),
                             (args.manifest, products.MANIFEST), (path.with_name(products.ARM), products.ARM),
                             (path.with_name(products.DELTA), products.DELTA), (oci / "runner/start.sh", START)):
            shutil.copyfile(source, folder / name)
        require(terminal.digest(folder / START) == START_SHA, "ordinary staged guest startup changed")
        for name in products.ALLOWED:
            target = folder / "output-polling-src" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path.parent / "src" / name, target)
        for output in (folder, work / "probe"):
            (output / RUNNER_READ).write_text(ENGINE_READER)
        return {**fields, "output_polling": mode, "output_polling_runner_sha256": receipt["runner_sha256"],
                "output_polling_product_sha256": receipt["product_sha256"],
                "output_polling_manifest_sha256": terminal.digest(folder / products.MANIFEST),
                "output_polling_build_manifest_sha256": terminal.digest(folder / products.ARM),
                "output_polling_test_product_sha256": manifest["arms"]["optimized"]["product_sha256"],
                "output_polling_sources": {name: terminal.digest(folder / name) for name in SOURCES}}

    def observe(folder, cohorts, phase):
        capture(folder, cohorts, phase)
        native = cohorts["A"]
        boot = parents.boots(folder)["A"]
        name = readback_name(phase)
        shutil.copyfile(native.work / name, folder / name)
        observed = engine_readback(folder / name, boot, receipt["runner_sha256"])
        if phase == "before":
            builder = native.jobs[native.count]
            output = native.cmd("exec", builder["id"], "/mpcheck/group-runner.test",
                                "-test.v", "-test.run", TEST_PATTERN, timeout=20)
            (folder / TESTS).write_text(output + "\n")
            check_tests(output)
        else:
            require(observed == engine_readback(folder / readback_name("before"), boot, receipt["runner_sha256"]),
                    "native Docker engine changed during workload")

    def complete(folder, plan, inventory, boots):
        value = verify_holdout(folder, plan, inventory, boots)
        return {**value, **verify(folder, plan, boots, manifest, product, receipt)}

    with patch.dict(os.environ, env, clear=True), mounted_worker_volume(), \
            patch.object(holdout, "PREFIX", PREFIX), \
            patch.object(holdout, "SEED_ORDER", {seed: (WINDOW,) for seed in SEED_ORDER}), \
            patch.object(holdout, "stage", setup), patch.object(holdout, "verify", complete), \
            patch.object(parents, "capture", observe), patch.object(fault, "boot_hook", boot_hook), \
            patch.object(sibling_group, "stage", lambda folder, probe, _, env: group_stage(folder, probe, test_product, env)):
        holdout.run(args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    live = parser.add_subparsers(dest="command", required=True).add_parser("run")
    live.add_argument("--output-polling", required=True, choices=products.MODES)
    live.add_argument("--seed", required=True, choices=SEED_ORDER, type=int)
    live.add_argument("--manifest", type=Path, default=HERE / products.MANIFEST)
    for name in ("page-kernel-pair", "ipvlan-kernel", "quiet-source"):
        live.add_argument("--" + name, type=Path, required=True)
    live.add_argument("--image-archive", type=Path)
    run(parser.parse_args())


if __name__ == "__main__":
    main()
