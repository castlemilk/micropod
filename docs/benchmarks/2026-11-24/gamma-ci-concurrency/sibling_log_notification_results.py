"""Replay the stock Tasks.Wait and inotify log watcher crossover."""

import argparse
from hashlib import sha256
import json
from pathlib import Path
import re
from types import ModuleType
from unittest.mock import patch

from qualify import require, terminal
from sibling_results import read
import sibling_file_fault_around_holdout_results as holdout
import sibling_file_fault_around_results as trial
import sibling_log_notification as fixture
import sibling_output_polling as parent_fixture
import sibling_output_polling_results as polling


HERE = Path(__file__).resolve().parent
MODE = "log_notification"
MODES = ("stock", "notify")
ORDERS = {250277: MODES, 250279: MODES[::-1]}
WINDOW = trial.VALUES[0]
STOCK_SEEDS = {seed: (WINDOW,) for seed in ORDERS}
MODE_KEYS = (MODE, "log_notification_runner_sha256", "log_notification_product_sha256")
PARENT_RUNNER_SHA256 = "3e8abc928350bd4d384044dd87b8cc3ba67ba787581a922dd105b1e5c879ad0c"
PACKAGER_SHA256 = "bfad5ca8dc9b9ad366ed62eadabc36daa6b460dcce55a8591e3b7942f72d6f98"


def check_packages(manifest_path):
    raw = Path(manifest_path).read_bytes()
    receipt = json.loads(raw)
    product = Path(receipt["product"]).resolve()
    packager = product.parent / fixture.PACKAGER
    source = packager.read_bytes()
    require(product.name == "product.json" and product.parent.parent == polling.products.BASE and
            sha256(source).hexdigest() == receipt["identity"]["packager_sha256"] == PACKAGER_SHA256 and
            raw == (product.parent / "cri-log-watch-build.json").read_bytes(), "unexpected sealed log watcher kit or verifier")
    kit = ModuleType("_sealed_cri_log_watch_product")
    kit.__file__ = str(packager)
    exec(compile(source, str(packager), "exec"), kit.__dict__)
    base, stock, parent = kit.baseline()
    env, tools = kit.sealed_toolchain(parent)
    require(kit.verify(product, base, stock, parent, env, tools) == receipt and
            receipt["stock_rebuilt_sha256"] == stock["guest_runner_sha256"] == PARENT_RUNNER_SHA256 and
            terminal.digest(base) == fixture.PARENT_PRODUCT_SHA and receipt["kernel"]["default_window_bytes"] == WINDOW,
            "log watcher kit did not reproduce the qualified Tasks.Wait parent")
    descriptor, _ = trial.check_product()
    arms = {}
    for mode, path in (("stock", base), ("notify", product)):
        packaged = read(path.parent, path.name)
        runner = packaged["guest_runner_sha256"]
        require((runner == PARENT_RUNNER_SHA256) == (mode == "stock") and
                packaged["worker_executable_sha256"] == descriptor["host_sha256"] and
                packaged["guest_start_sha256"] == descriptor["new_bootstrap_sha256"],
                "runner arm changed the sealed host or bootstrap")
        arms[mode] = {"path": path, "package": packaged, "product_sha256": terminal.digest(path), "runner_sha256": runner,
                      "manifest": {**descriptor, "current_product": str(path), "new_guest_sha256": runner}}
    return raw, receipt, arms


def check_tests(raw, roots):
    lines = raw.strip().splitlines()
    expected = set(roots) | polling.TEST_SUBCASES
    started = [line.removeprefix("=== RUN   ") for line in lines if line.startswith("=== RUN   ")]
    passed = [match[1] for line in lines if (match := re.match(r"\s*--- PASS: (\S+) \(", line))]
    require(len(started) == len(passed) == len(expected) and set(started) == set(passed) == expected and
            lines[-1] == "PASS" and not any(marker in line for line in lines for marker in ("SKIP:", "FAIL:")),
            "Linux log watcher receipt is missing a test or exit-repair subcase")
    return started


def validated_archive(folder, plan, raw, kit, arm):
    require(plan[MODE] in MODES and plan[trial.TREATMENT] == WINDOW and
            plan["log_notification_product_sha256"] == arm["product_sha256"] and
            plan["log_notification_runner_sha256"] == arm["runner_sha256"] and
            plan["group_runner_test_sha256"] == kit["tests"]["sha256"] and
            "ttwu_queue" not in plan and "ttwu_diagnostic" not in plan and "output_polling" not in plan,
            "log notification archive changed the selected engine, test binary or workload")
    require(plan["log_notification_sources"] == {name: terminal.digest(folder / name) for name in fixture.SOURCE_NAMES} and
            (folder / fixture.MANIFEST).read_bytes() == raw and
            (folder / "worker-build.json").read_bytes() == arm["path"].read_bytes() and
            terminal.digest(folder / fixture.PACKAGER) == PACKAGER_SHA256 and
            terminal.digest(folder / fixture.DELTA) == kit["delta_sha256"] and
            terminal.digest(folder / parent_fixture.START) == polling.STAGED_START and
            (folder / parent_fixture.RUNNER_READ).read_text() == parent_fixture.ENGINE_READER,
            "log notification archive changed the sealed product or staged launcher inputs")
    with patch.object(holdout, "SEED_ORDER", STOCK_SEEDS), \
            patch.object(trial.fixture, "boot_hook", return_value=parent_fixture.boot_hook()):
        (seed, _), settings, protocol = holdout.validated_archive(folder, plan, arm["manifest"], arm["package"])
    package, job, *other = settings
    require(job["ProgramArguments"] == [package["worker_executable"], "ci", "serve"],
            "native launch selected a different signed product")
    init, = [line for line in (folder / "a/service.stderr").read_text().splitlines()
             if line.startswith("using ghcr.io/apple/containerization/vminit:")]
    stable_launch = {key: value for key, value in job.items() if key != "ProgramArguments"}
    return (seed, plan[MODE]), [stable_launch, *other, init], {key: value for key, value in protocol.items() if key not in MODE_KEYS}


def verified_run(folder, plan, kit, arm):
    with patch.object(trial.shared, "check_admission", polling.check_admission):
        context = trial.qualified_context(folder, plan)
    before, after = (parent_fixture.engine_readback(folder / parent_fixture.readback_name(phase), context["boots"]["A"], arm["runner_sha256"])
                     for phase in ("before", "after"))
    require(before == after, "native Docker engine restarted or changed during the log notification workload")
    tests = check_tests((folder / fixture.TESTS).read_text(), kit["tests"]["roots"])
    last_wave, stock = holdout.verify_stock(folder, plan, context)
    mapping = trial.check_mapping(folder, context, WINDOW, last_wave=last_wave)
    run, rows = trial.replay_paced(folder, plan, context)
    worker = run["worker"]
    require(worker["guest"] == arm["runner_sha256"] and "TTWU_QUEUE" in worker["scheduler"]["after"],
            "actual paced workload used a different engine or scheduler")
    result = trial.run_identity(folder, plan, context, run, rows)
    result["worker_invariants"] = {key: value for key, value in worker.items() if key != "guest"}
    result["receipt"].update(native_engine=before, linux_tests=tests, stock_builds=stock, off_timing_go_mapping=mapping,
                             mode=plan[MODE])
    return result


def compare(folders, *, manifest=HERE / fixture.MANIFEST):
    """Verify and score the four counterbalanced log notification archives."""
    paths = [Path(path).resolve() for path in folders]
    expected = {(seed, mode) for seed, modes in ORDERS.items() for mode in modes}
    require(len(paths) == len(set(paths)) == len(expected), "log notification crossover needs four distinct completed boots")
    raw, kit, arms = check_packages(manifest)
    archives, scopes, common = {}, set(), None
    for folder in paths:
        plan = read(folder, "plan.json")
        mode = plan.get(MODE)
        require(mode in MODES, "unexpected log notification mode")
        key, settings, protocol = validated_archive(folder, plan, raw, kit, arms[mode])
        scope = Path(plan["scope"]).resolve()
        require(key in expected and key not in archives and scope not in scopes, "duplicate or unexpected log notification boot")
        require(common is None or common == (settings, protocol), "log notification crossover changed another stock workload setting")
        common = settings, protocol
        archives[key] = folder, plan
        scopes.add(scope)
    require(archives.keys() == expected, "log notification crossover is missing a prespecified boot")
    measured = {key: verified_run(folder, plan, kit, arms[key[1]]) for key, (folder, plan) in archives.items()}
    settings, protocol = common
    first = next(iter(measured.values()))
    fingerprint = trial.shared.fingerprint
    return {"product_manifest_sha256": sha256(raw).hexdigest(), "kernel": kit["kernel"], "vminit_selection": settings[-1],
            "protocol_sha256": fingerprint([protocol, first["launch"]]), "signed_settings_sha256": fingerprint(settings),
            "placements": trial.signed.PLACEMENT,
            "products": {mode: {"product": str(arm["path"]), "product_sha256": arm["product_sha256"], "runner_sha256": arm["runner_sha256"]}
                         for mode, arm in arms.items()},
            **polling.matched_identity(measured), **polling.summarize(measured, modes=MODES, orders=ORDERS)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=HERE / fixture.MANIFEST)
    parser.add_argument("folders", nargs=4, type=Path)
    args = parser.parse_args()
    print(json.dumps(compare(args.folders, manifest=args.manifest), indent=2, allow_nan=False))
