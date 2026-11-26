"""Compare 250 and 350 us guest-wide fair slices with native tmpfs and the worker cache."""

import argparse
import json
import re
import shutil
import signal
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import patch

import sibling_build
import sibling_ci
import sibling_group
import sibling_sched
import sibling_tmpfs
from qualify import HERE, LABEL, fanout, require, terminal
from sibling_ext4_cache import reserve_in_order


BASELINE = "hrtick-250us"
TARGETS = (250, 350)
SEEDS = (250191, 250193)
DRIVER = "slice-350-driver.py"
BEFORE_HOOK = "slice-350-before-work.sh"
STAGED_START = "slice-350-staged-start.sh"
BEFORE = "slice-350-before-work"
AFTER = "slice-350-after-work.json"
CLIENT_BOOTS = "slice-350-client-boots-{}.json"
READBACK_DIR = "slice-350-scheduler"
FILES = {"base_slice_ns": "/slice-350-base", "features": "/slice-350-features"}
BOOT_ID_PATH = "/proc/sys/kernel/random/boot_id"
POST_PROBE = r'''
printf 'boot=%s\neffective_ns=%s\nfeatures=%s\n' \
    "$(cat /proc/sys/kernel/random/boot_id)" "$(cat /slice-350-base)" "$(cat /slice-350-features)"
awk '$5 == "/slice-350-base" || $5 == "/slice-350-features" {print "mount " $0}' /proc/self/mountinfo
'''


def scheduler_profiles():
    return patch.dict(sibling_sched.FEATURES, {"base-350us": (None, 350000)})


def before_work_hook(target_us):
    require(target_us in TARGETS, "invalid suite slice")
    return r'''
(
    set -eu
    workspace="$MICROPOD_ENGINE_WORKSPACE"
    dir="$workspace/fair-scheduler"
    sched=/sys/kernel/debug/sched
    initial=$(cat "$dir/base-before") || exit 1
    effective=$(cat "$sched/base_slice_ns") || exit 1
    if [ "$(id -u)" != 0 ] || [ "$initial" != 250000 ] || [ "$effective" != EXPECTED_NS ] ||
        [ "$(cat "$dir/base-slice")" != "$effective" ] || ! cmp -s "$dir/before" "$dir/after" ||
        [ "$(cat "$dir/after")" != "$(cat "$sched/features")" ]; then
        echo 'Slice experiment failed the pre-work scheduler check' >&2
        exit 1
    fi
    readback="$workspace/slice-350-scheduler"
    mkdir -m 0700 "$readback" || exit 1
    for name in base_slice_ns features; do
        : > "$readback/$name" || exit 1
        mount --bind "$sched/$name" "$readback/$name" || exit 1
        mount -o remount,bind,ro "$sched/$name" "$readback/$name" || exit 1
    done
    boot=$(cat /proc/sys/kernel/random/boot_id) || exit 1
    printf 'boot=%s\ninitial_ns=%s\neffective_ns=%s\n' "$boot" "$initial" "$effective" > "$dir/slice-350-before-work"
) || exit 1
'''.replace("EXPECTED_NS", str(target_us * 1000))


def check_start_order(source):
    markers = ('if sh "$tools/runner/fixture-facts.sh"', '"$tools/runner/bin/job" recover',
               '"$tools/runner/bin/job" engine &', '"$tools/service" serve &')
    require(all(source.count(marker) == 1 for marker in markers), "unknown private bootstrap hook")
    positions = [source.index(marker) for marker in markers]
    require(positions == sorted(positions), "scheduler hook must run before recovery and API startup")


def verify_before_work(folder, plan):
    target = plan["slice_350_target_us"]
    start = folder / STAGED_START
    guard = folder / BEFORE_HOOK
    require(target in TARGETS and plan["guest_fair"] == f"base-{target}us"
            and plan["worker_scheduler"] == BASELINE and plan["worker_next_buddy"] is True
            and plan.get("build_scratch") == "tmpfs", "unexpected slice fixture plan")
    for name, key in ((DRIVER, "slice_350_driver_sha256"), (BEFORE_HOOK, "slice_350_guard_sha256"),
                      (STAGED_START, "slice_350_staged_start_sha256")):
        require(terminal.digest(folder / name) == plan[key], "unexpected archived slice fixture source")
    require(guard.read_text() == before_work_hook(target), "unexpected pre-work scheduler guard")
    check_start_order(start.read_text())
    facts = (folder / "a/guest-facts.txt").read_text().splitlines()
    boot, = [line.removeprefix("boot=") for line in facts if line.startswith("boot=")]
    require(re.fullmatch(sibling_tmpfs.BOOT_ID, boot), "invalid slice fixture boot identity")
    directory = folder / "fair-scheduler"
    require((directory / "base-before").read_text().strip() == "250000"
            and (directory / BEFORE).read_text() == f"boot={boot}\ninitial_ns=250000\neffective_ns={target * 1000}\n",
            "pre-work scheduler check has the wrong boot or slice")
    with scheduler_profiles():
        receipt = sibling_sched.read(directory, plan["guest_fair"], BASELINE, True)
    return {"boot": boot, "effective_ns": receipt["base_slice_ns"], "features": receipt["after"]}


def post_readback(raw):
    values, mounts = sibling_tmpfs.read_fields(raw)
    require(set(mounts) == set(FILES.values()), "missing private scheduler file mounts")
    for name, destination in FILES.items():
        m = mounts[destination]
        require(m["fs"] == "debugfs" and m["root"] == f"/sched/{name}" and "ro" in m["options"]
                and "rw" not in m["options"], "post-work scheduler file has the wrong mount or access")
    return {"boot": values["boot"], "effective_ns": int(values["effective_ns"]),
            "features": sorted(values["features"].split())}


def verify_after_work(folder, plan, inventory):
    read = lambda name: json.loads((folder / name).read_bytes())
    expected = verify_before_work(folder, plan)
    after = read(AFTER)
    require(after == {**expected, "raw": after["raw"]} and post_readback(after["raw"]) == expected,
            "live scheduler changed across the suite")
    prime = {a: fanout.parse_job(line, 0) for a, line in read("grouped-prime.json").items()}
    require(prime["A"]["boot"] == expected["boot"] and prime["A"]["boot"] != prime["B"]["boot"],
            "measured builders have the wrong guest boots")
    client_proof = {}
    for arm in "AB":
        jobs = inventory[arm]["jobs"]
        require(len(jobs) == 64, "missing measured clients for the boot check")
        client_proof[arm] = [{"id": j["id"], "boot": prime[arm]["boot"]} for j in jobs[32:]]
    for phase in ("before", "after"):
        require(read(CLIENT_BOOTS.format(phase)) == client_proof, "measured clients changed guest boots")
    return expected


def check_group_mapping(inventory):
    expected = {sibling_group.group_name(i): str(i % 4) for i in range(32)}
    require(inventory["placement"]["groups"] == expected, "the slice fixture needs the fixed native vCPU map")


def client_boot(cohort, job):
    raw = cohort.cmd("exec", job["id"], "/mpcheck/netbench", "-net-info")
    boot = json.loads(raw).get(BOOT_ID_PATH)
    require(isinstance(boot, str) and re.fullmatch(sibling_tmpfs.BOOT_ID, boot),
            "missing Linux boot ID from the measured client")
    return {"id": job["id"], "boot": boot}


def workload(args):
    return argparse.Namespace(
        product=args.product.resolve(), page_kernel_pair=args.page_kernel_pair.resolve(),
        ipvlan_kernel=args.ipvlan_kernel.resolve(), quiet_source=args.quiet_source.resolve(),
        image_archive=args.image_archive.resolve() if args.image_archive else None,
        seed=args.seed, rounds=4, layouts=["grouped"], page_kib=16, tick_kernel=None,
        mthp_kernel=None, mthp_64k=None, buddy_kernel=None, process_type="Standard",
        worker_scheduler=BASELINE, worker_next_buddy=True, guest_fair=f"base-{args.target_us}us",
        network_driver="ipvlan", network_topology="per-job", cpu_groups=True, pairs=32, requests=200,
        builders=8, build_nice=0, build_slice_us=None, build_policy=None, build_scratch="tmpfs",
        dense_ms=1500, offered_rps=64_000, slice_us=None, slice_target="all", builder_shares=None,
        timer_counters=False, trace_sockets=False, job_network_smoke=False, ipam_route_product=None,
    )


def run(args):
    profile = workload(args)
    files = (profile.product, profile.page_kernel_pair, profile.ipvlan_kernel, profile.quiet_source, profile.image_archive)
    require(all(p is None or p.exists() for p in files), "slice fixture needs its pinned input files")
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-sibling-slice350-"), dir=HERE))
    print(folder, flush=True)
    signal.signal(signal.SIGTERM, terminal.exit_on_signal)
    create, parallel = sibling_ci.Siblings.create, sibling_ci.parallel
    stage, stage_build, qualify = sibling_sched.stage, sibling_build.stage, sibling_tmpfs.qualify

    def create_fixed(cohort):
        if cohort.arm != "A":
            return create(cohort)
        with patch.object(sibling_ci, "parallel", lambda *a: reserve_in_order(parallel, *a)):
            inventory = create(cohort)
        check_group_mapping(inventory)
        return inventory

    def stage_scheduler(oci, output, feature):
        stage(oci, output, feature)
        start = (oci / "runner/start.sh").read_text()
        check_start_order(start)
        guard = before_work_hook(args.target_us)
        with (oci / "runner/fixture-facts.sh").open("a") as hook:
            hook.write(guard)
        shutil.copyfile(__file__, output / DRIVER)
        (output / BEFORE_HOOK).write_text(guard)
        shutil.copyfile(oci / "runner/start.sh", output / STAGED_START)

    def stage_build_receipts(*pos, **kw):
        return {**stage_build(*pos, **kw), "slice_350_target_us": args.target_us,
                "slice_350_driver_sha256": terminal.digest(folder / DRIVER),
                "slice_350_guard_sha256": terminal.digest(folder / BEFORE_HOOK),
                "slice_350_staged_start_sha256": terminal.digest(folder / STAGED_START)}

    def observe_scratch(output, cohorts, mode, phase):
        qualify(output, cohorts, mode, phase)
        client_boots = {}
        for arm, cohort in cohorts.items():
            client_boots[arm] = parallel(8, lambda job: client_boot(cohort, job), cohort.jobs[cohort.count:])
        terminal.save(output / CLIENT_BOOTS.format(phase), client_boots)
        if phase == "after":
            native = cohorts["A"]
            name = native.owner + "-slice350-readback"
            mounts = [arg for file, target in FILES.items() for arg in
                      ("--mount", f"type=bind,src={native.work / READBACK_DIR / file},dst={target},readonly")]
            selector = ("ps", "-aq", "--no-trunc", "--filter", f"name={name}", "--filter", f"label={LABEL}={native.owner}")
            try:
                raw = native.cmd("run", "--rm", "--pull=never", "--name", name, "--network", "none",
                                 "--memory", "64m", "--pids-limit", "24", "--cpus", "1",
                                 "--label", f"{LABEL}={native.owner}", *mounts, "--entrypoint", "/bin/sh",
                                 sibling_build.IMAGE, "-ec", POST_PROBE, timeout=20)
            finally:
                rows = json.loads(terminal.invoke(*native.engine, "inspect", name, check=False, timeout=8).stdout or "[]")
                if rows:
                    row, = rows
                    require(row["Name"].lstrip("/") == name and row["Config"]["Labels"].get(LABEL) == native.owner,
                            "ambiguous post-work probe cleanup")
                    terminal.invoke(*native.engine, "rm", "-f", row["Id"], check=False, timeout=10)
                require(not native.cmd(*selector, timeout=8), "post-work probe remains")
            terminal.save(output / AFTER, {**post_readback(raw), "raw": raw})

    status = {"complete": False}
    try:
        with terminal.terminal_lock(), scheduler_profiles(), patch.object(sibling_ci.Siblings, "create", create_fixed), \
                patch.object(sibling_sched, "stage", stage_scheduler), patch.object(sibling_build, "stage", stage_build_receipts), \
                patch.object(sibling_tmpfs, "qualify", observe_scratch):
            sibling_ci.study(folder, profile)
            plan = json.loads((folder / "plan.json").read_bytes())
            inventory = json.loads((folder / "grouped-inventory.json").read_bytes())
            verify_after_work(folder, plan, inventory)
        status["complete"] = True
    except BaseException as exc:
        status["error"] = str(exc) or type(exc).__name__
        raise
    finally:
        terminal.save(folder / "status.json", status)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target-us", type=int, required=True, choices=TARGETS)
    parser.add_argument("--seed", type=int, required=True, choices=SEEDS)
    for argument in ("product", "page-kernel-pair", "ipvlan-kernel", "quiet-source"):
        parser.add_argument("--" + argument, type=Path, required=True)
    parser.add_argument("--image-archive", type=Path)
    run(parser.parse_args())


if __name__ == "__main__":
    main()
