"""Compare home-pinned and migratable Go process trees with unchanged HTTP placement."""

import argparse
import shutil
import signal
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import sibling_build
from qualify import HERE, ROOT, require, terminal


MODES = ("home", "pool")
SEEDS = (250201, 250203)
DRIVER = "sibling-compiler-affinity.py"
SOURCE = sibling_build.POLICY_SOURCE
PROBE = sibling_build.POLICY_PROBE
DISPATCH_FILE = sibling_build.AFFINITY_DISPATCH_FILE
DISPATCH = sibling_build.AFFINITY_DISPATCH


def stage(folder, work, mode, env):
    require(mode in MODES, "unknown compiler affinity mode")
    archived = folder / SOURCE
    shutil.copyfile(Path(__file__).with_name(SOURCE), archived)
    binary = work / "probe" / Path(PROBE).name
    terminal.invoke("go", "-C", ROOT / "guest/runner", "build", "-trimpath", "-buildvcs=false", "-o", binary,
                    archived, env={**env, "GOPROXY": "off"})
    (work / "probe" / DISPATCH_FILE).write_text(DISPATCH)
    (folder / DISPATCH_FILE).write_text(DISPATCH)
    shutil.copyfile(__file__, folder / DRIVER)
    return {"compiler_affinity": mode, "compiler_affinity_driver_sha256": terminal.digest(folder / DRIVER),
            "compiler_affinity_source_sha256": terminal.digest(archived),
            "compiler_affinity_probe_sha256": terminal.digest(binary),
            "compiler_affinity_dispatch_sha256": terminal.digest(folder / DISPATCH_FILE)}


def run(args):
    import sibling_ci
    import sibling_compiler_affinity_evidence as evidence
    import sibling_slice_350
    import sibling_tmpfs
    from sibling_ext4_cache import reserve_in_order

    profile = sibling_slice_350.workload(SimpleNamespace(**vars(args), target_us=250))
    profile.guest_fair = None
    profile.compiler_affinity = args.compiler_affinity
    files = (profile.product, profile.page_kernel_pair, profile.ipvlan_kernel, profile.quiet_source, profile.image_archive)
    require(all(p is None or p.exists() for p in files), "compiler affinity fixture needs its pinned inputs")
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-sibling-compiler-affinity-"), dir=HERE))
    print(folder, flush=True)
    signal.signal(signal.SIGTERM, terminal.exit_on_signal)
    create, parallel = sibling_ci.Siblings.create, sibling_ci.parallel
    wave = sibling_ci.Siblings.run_wave
    stage_build, qualify_scratch = sibling_build.stage, sibling_tmpfs.qualify

    def create_fixed(cohort):
        if cohort.arm == "A":
            with patch.object(sibling_ci, "parallel", lambda *a: reserve_in_order(parallel, *a)):
                inventory = create(cohort)
        else:
            inventory = create(cohort)
        sibling_slice_350.check_group_mapping(inventory)
        return inventory

    def prepare(output, runner, work, engine, archive, *, build_policy=None, build_slice_us=None, env=None):
        standard = stage_build(output, runner, work, engine, archive, build_policy=build_policy,
                               build_slice_us=build_slice_us, env=env)
        return {**standard, **stage(output, work, args.compiler_affinity, env), **evidence.stage(output)}

    def qualify(output, cohorts, mode, phase):
        qualify_scratch(output, cohorts, mode, phase)
        if phase == "before":
            evidence.qualify(output, cohorts, args.compiler_affinity)

    status = {"complete": False}
    try:
        with terminal.terminal_lock(), patch.object(sibling_ci.Siblings, "create", create_fixed), \
                patch.object(sibling_build, "stage", prepare), patch.object(sibling_tmpfs, "qualify", qualify), \
                patch.object(sibling_ci.Siblings, "run_wave", lambda *a: evidence.observe_wave(wave, *a)):
            sibling_ci.study(folder, profile)
        status["complete"] = True
    except BaseException as exc:
        status["error"] = str(exc) or type(exc).__name__
        raise
    finally:
        terminal.save(folder / "status.json", status)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler-affinity", choices=MODES, required=True)
    parser.add_argument("--seed", type=int, choices=SEEDS, required=True)
    for argument in ("product", "page-kernel-pair", "ipvlan-kernel", "quiet-source"):
        parser.add_argument("--" + argument, type=Path, required=True)
    parser.add_argument("--image-archive", type=Path)
    run(parser.parse_args())


if __name__ == "__main__":
    main()
