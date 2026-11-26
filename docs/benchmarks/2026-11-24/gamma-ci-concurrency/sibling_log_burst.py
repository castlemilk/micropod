"""Check concurrent foreground log delivery on one fresh private native worker."""

import argparse
from contextlib import ExitStack
from datetime import UTC, datetime
from hashlib import sha256
import json
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import tempfile
import time
from types import SimpleNamespace

import build_file_fault_around as kernel
import build_ipvlan
import private_link
from qualify import CONFIG, HERE, IMAGE, check_baseline, cli, local_admission, require, terminal
from sibling_cgroup_hierarchy import load_go
import sibling_follow_lifecycle as lifecycle
import sibling_output_polling as polling
import sibling_sched
import sibling_worker_volume_results as volume


PREFIX = "sibling-log-burst"
RECEIPT = "log-burst.json"
PRODUCTS = {
    "tasks-wait": ("4c4106ce58d8120e", "28d82911155732e3208a64c99430740b85af6370666f1d061d15db416d0845b5",
                   "3e8abc928350bd4d384044dd87b8cc3ba67ba787581a922dd105b1e5c879ad0c"),
    "log-notify": ("6bd12bc5c593a999", "fb8ac000ac36940926475d22f6fbb5c6a2b39d9face4f28ed690771aad49aa8c",
                   "58846d9c91426bf22efdb37752d1d0f6bb9014ab33e8fdd00f16e829fe96726a"),
}
ARCHIVE = kernel.ROOT / ".build/local-fair-scheduler/go-ci-cb8603c283329181.tar"
SCHEDULER = "hrtick-250us"
CODES = (0, 7, 12, 19, 23, 37, 43, 61)
PADDING = {"out": "0123456789ABCDEF" * 28, "err": "fedcba9876543210" * 28}
STREAMS = ("out", "err")
PAYLOAD = r'''set -eu
slot=$1 code=$2 out=$3 err=$4
await_gate() {
    tries=0
    until [ -f "/burst/$1" ]; do
        tries=$((tries+1))
        [ "$tries" -lt 1200 ] || exit 98
        sleep .05
    done
}
printf 'ready-out-%02d\n' "$slot"
printf 'ready-err-%02d\n' "$slot" >&2
await_gate release
i=0
while [ "$i" -lt 256 ]; do
    printf 'slot=%02d seq=%03d stream=out %s\n' "$slot" "$i" "$out"
    printf 'slot=%02d seq=%03d stream=err %s\n' "$slot" "$i" "$err" >&2
    i=$((i+1))
    case "$i" in
        64) sleep .03;;
        128) sleep .23;;
        192) sleep .04;;
    esac
done
for double in 1 2 3 4 5 6; do
    out=$out$out err=$err$err
done
printf 'large-out-%02d %s\n' "$slot" "$out"
printf 'large-err-%02d %s\n' "$slot" "$err" >&2
printf 'drained-out-%02d\n' "$slot"
printf 'drained-err-%02d\n' "$slot" >&2
await_gate exit
printf 'tail-out-%02d' "$slot"
printf 'tail-err-%02d' "$slot" >&2
exit "$code"
'''
BOOT_HOOK = r'''
(
    set -eu
    dir="$MICROPOD_ENGINE_WORKSPACE/log-burst-engine"
    for phase in before after; do
        tries=0
        until [ -f "$dir/$phase.request" ]; do
            tries=$((tries+1))
            [ "$tries" -lt 2500 ] || exit 1
            sleep .25
        done
        /bin/sh "$dir/read.sh" > "$dir/$phase.tmp"
        mv "$dir/$phase.tmp" "$dir/$phase.txt"
    done
) </dev/null >>"$MICROPOD_ENGINE_WORKSPACE/log-burst-engine/guest.log" 2>&1 &
'''


def read(path):
    return json.loads(path.read_bytes())


def streams(slot, stream):
    suffix = f"{stream}-{slot:02d}"
    prefix = f"ready-{suffix}\n" + "".join(
        f"slot={slot:02d} seq={i:03d} stream={stream} {PADDING[stream]}\n" for i in range(256)
    ) + f"large-{suffix} {PADDING[stream] * 64}\ndrained-{suffix}\n"
    return prefix.encode(), f"tail-{suffix}".encode()


def digest_record(data):
    return {"bytes": len(data), "sha256": sha256(data).hexdigest()}


def wait_for(runner, test, message, timeout=25):
    end = time.monotonic() + timeout
    while True:
        runner.guard()
        if value := test():
            return value
        require(time.monotonic() < end, message)
        time.sleep(.05)


def raw(folder, slot, stream):
    return folder / f"slot-{slot:02d}.{stream}"


def check_stream(path, expected):
    require(path.is_file() and path.stat().st_size == len(expected), f"unexpected byte count in {path.name}")
    data = path.read_bytes()
    require(data == expected, f"unexpected content in {path.name}")
    return digest_record(data)


def resources(docker):
    return {"containers": sorted(docker("ps", "-aq", "--no-trunc").split()),
            "networks": sorted(docker("network", "ls", "--no-trunc", "-q").split()),
            "volumes": sorted(docker("volume", "ls", "-q").split())}


def launch_args(cohort, gate, slot, name, token):
    return ["run", *lifecycle.flags(cohort, name, token), "--mount",
            f"type=bind,src={gate},dst=/burst,readonly", "--entrypoint", "/bin/sh", IMAGE,
            "-ec", PAYLOAD, "log-burst", str(slot), str(CODES[slot]), *PADDING.values()]


def work(runner, folder, engine, sock, workspace):
    owner = runner.root.name
    token = secrets.token_hex(6)
    names = [f"{owner}-burst-{token}-{i}" for i in range(len(CODES))]
    cohort = SimpleNamespace(owner=owner, cmd=lambda *args, timeout=20: cli(engine, *args, timeout=timeout))
    gate = workspace / "log-burst-gate"
    gate.mkdir(mode=0o755)
    receipts = {"owner": owner, "token": token, "socket": str(sock), "jobs": [], "complete": False}
    expected = [{stream: streams(i, stream) for stream in STREAMS} for i in range(len(names))]
    procs = []
    try:
        receipts["resources_before"] = resources(cohort.cmd)
        require(not receipts["resources_before"]["containers"], "worker contains a preexisting container")
        for i, name in enumerate(names):
            row = {"slot": i, "name": name, "argv": launch_args(cohort, gate, i, name, token)}
            receipts["jobs"].append(row)
            with raw(folder, i, "out").open("xb") as out, raw(folder, i, "err").open("xb") as err:
                row["host_started_unix_ns"] = time.time_ns()
                procs.append(subprocess.Popen([*engine, *row["argv"]], stdin=subprocess.DEVNULL, stdout=out, stderr=err))
        selector = ("ps", "--no-trunc", "-q", "--filter", "status=running", "--filter",
                    f"label={lifecycle.PROBE_LABEL}={token}")

        def running():
            ids = cohort.cmd(*selector).split()
            require(len(ids) <= len(names) and all(p.poll() is None for p in procs),
                    "foreground client exited before the common gate")
            return sorted(ids) if len(ids) == len(names) else None

        receipts["first_running_ids"] = wait_for(runner, running, "eight foreground containers were not simultaneously running")
        with ExitStack() as clients:
            waits = []
            for name, row in zip(names, receipts["jobs"], strict=True):
                before = row["before"] = lifecycle.inspect(sock, name, {name}, owner, token)
                require(before is not None and before["State"]["Running"], "missing running foreground job")
                path = row["wait_path"] = f'/containers/{before["Id"]}/wait?condition=next-exit'
                waits.append(clients.enter_context(lifecycle.api(sock, "POST", path)))
                row["wait_headers_unix_ns"] = time.time_ns()
            receipts["release_unix_ns"] = time.time_ns()
            (gate / "release").touch(exist_ok=False)

            def prefixes_written():
                require(all(p.poll() is None for p in procs), "foreground client exited during log burst")
                return all(raw(folder, i, stream).stat().st_size >= len(parts[0])
                           for i, job in enumerate(expected) for stream, parts in job.items())

            wait_for(runner, prefixes_written, "foreground burst bytes were not delivered before the exit gate")
            for i, row in enumerate(receipts["jobs"]):
                row["live_streams"] = {stream: check_stream(raw(folder, i, stream), parts[0])
                                       for stream, parts in expected[i].items()}
            receipts["last_running_ids"] = running()
            receipts["exit_release_unix_ns"] = time.time_ns()
            (gate / "exit").touch(exist_ok=False)
            wait_for(runner, lambda: all(p.poll() is not None for p in procs), "foreground exits did not complete")
            for i, (row, proc, response) in enumerate(zip(receipts["jobs"], procs, waits, strict=True)):
                row["host_reaped_unix_ns"], row["exit_code"] = time.time_ns(), proc.returncode
                row["wait"] = lifecycle.read_json(response)
                row["after"] = lifecycle.inspect(sock, row["before"]["Id"], {row["name"]}, owner, token)
                row["streams"] = {stream: check_stream(raw(folder, i, stream), b"".join(parts))
                                  for stream, parts in expected[i].items()}
    except BaseException as error:
        receipts["error"] = str(error) or type(error).__name__
        raise
    finally:
        try:
            try:
                for proc in procs:
                    if proc.poll() is None:
                        proc.kill()
                    proc.wait(5)
            finally:
                receipts["cleanup"] = lifecycle.clean(cohort, sock, set(names), token)
            receipts["resources_after"] = resources(cohort.cmd)
            require(receipts["resources_after"] == receipts["resources_before"], "native Docker left scoped resources")
            receipts["complete"] = "error" not in receipts
        finally:
            terminal.save(folder / RECEIPT, receipts)


def engine_phase(runner, folder, workdir, boot, expected, phase):
    (workdir / f"{phase}.request").touch(exist_ok=False)
    source = workdir / f"{phase}.txt"
    wait_for(runner, source.is_file, f"native engine identity {phase} was not recorded", timeout=12)
    target = folder / f"engine-{phase}.txt"
    shutil.copyfile(source, target)
    return polling.engine_readback(target, boot, expected)


def study(folder, args):
    arena, product_sha, runner_sha = PRODUCTS[args.arm]
    product = kernel.BASE / f"ci-published-link-{arena}" / "product.json"
    require(terminal.digest(product) == product_sha and args.image_archive.is_file(), "pinned burst inputs unavailable")
    opts = terminal.parse_options(["--mode", "host-role", "--socket-evidence", "route", "--run"])
    files = terminal.fixture_files(opts)
    build = private_link.select(files, product)
    pages = build_ipvlan.select(kernel.IPVLAN_KERNEL, kernel.STOCK_KERNEL, files, folder)
    require(build["guest_runner_sha256"] == runner_sha and build["worker_executable_sha256"] == polling.products.HOST_SHA
            and pages["kernel_image_sha256"] == kernel.EXPECTED_IMAGE,
            "burst requires the sealed runner and pinned 16 KiB kernel")
    terminal.check_archives(files)
    terminal.verify_cache()
    admission = local_admission.Admission(folder)
    admission.check(force=True)
    runner = terminal.Run(opts, folder, admission)
    try:
        workspace, oci, _ = terminal.stage(runner.root, files)
        require(terminal.digest(oci / "runner/start.sh") == polling.START_SHA, "private staged bootstrap changed")
        observer = workspace / "log-burst-engine"
        observer.mkdir(mode=0o700)
        (observer / "read.sh").write_text(polling.ENGINE_READER)
        (folder / "engine-read.sh").write_text(polling.ENGINE_READER)
        with (oci / "runner/fixture-facts.sh").open("a") as hook:
            hook.write(BOOT_HOOK)
        sibling_sched.stage(oci, folder, "inherit")
        shutil.copyfile(Path(__file__), folder / Path(__file__).name)
        shutil.copyfile(product, folder / "worker-build.json")
        require(check_baseline() == 24, "baseline preservation differs")
        terminal.save(folder / "plan.json", {"arm": args.arm, "scope": str(runner.root), "pages": pages,
                      "product_sha256": product_sha, "runner_sha256": runner_sha, "baseline_files": 24,
                      "source_sha256": terminal.digest(Path(__file__)), **runner.volume_policy})
        scope, facts = runner.arm("a", 4, files, workspace, oci, process_type="Standard", publication_mtu=9000,
                                  product_mtu=True, relay_mode="kqueue-throughput", published_rps=True,
                                  ci_scheduler=SCHEDULER, ci_next_buddy=True)
        facts = facts.read_text().splitlines()
        boot, = [line.removeprefix("boot=") for line in facts if line.startswith("boot=")]
        require("config_sha256=" + pages["kernel_config_sha256"] in facts, "guest kernel config differs")
        sibling_sched.verify(workspace, folder, "inherit", SCHEDULER, True)
        identity, engine = private_link.service_preflight.identity(scope, build, 9000)
        sock = runner.root / "a/docker.sock"
        require(sock.is_socket() and engine == ["docker", "--host", "unix://" + str(sock)], "unexpected native socket")
        terminal.save(folder / "worker-identity.json", identity)
        before = engine_phase(runner, folder, observer, boot, runner_sha, "before")
        load_go(folder, runner, engine, args.image_archive)
        cli(engine, "rm", "-f", identity["container"])
        runner.arms[0]["cid"] = None
        work(runner, folder, engine, sock, workspace)
        require(before == engine_phase(runner, folder, observer, boot, runner_sha, "after"), "live engine changed")
        runner.guard()
    finally:
        runner.cleanup()
        terminal.save(folder / "verification.json", {"baseline_files": check_baseline(), "extra_cleanup_errors": runner.errors})
    require(not runner.root.exists() and not runner.errors and not runner.watch.is_alive() and not runner.contention,
            "private worker retirement or admission did not complete")


def verify_volume(folder, plan, scope):
    policy = read(folder / "host-volume-policy.json")
    require(all(plan.get(key) == value for key, value in policy.items()) and policy[volume.VOLUME_FIELD] == volume.POLICY
            and policy[volume.FINAL_HISTORY] is True and policy[volume.SIZE_FIELD] == volume.VOLUME_GIB
            and set(policy["host_volume_sources"]) == {"local_worker_drive.py", "worker_apfs_drive.py"}
            and all(terminal.digest(folder / name) == digest for name, digest in policy["host_volume_sources"].items()),
            "private APFS worker-drive policy differs")
    created, live, post, detached = (read(folder / name) for name in volume.RECEIPTS)
    mount, image = scope / "a", scope / "a-worker.sparseimage"
    identity = volume.volume_identity(created, mount, image)
    require(all(volume.volume_identity(row["volume"], mount, image) == identity for row in (live, post)),
            "private APFS attachment changed")
    raw_disk = volume.raw_identity(live["disk"], identity, mount)
    require(volume.raw_identity(post["disk"], identity, mount) == raw_disk, "worker disk changed")
    journal = volume.journal_state(post["volume"]["fsevents"], mount, identity["volume_st_dev"])
    retirement = volume.check_detach(detached, identity, mount, image)
    volume.verify_persisted_history(retirement, post["volume"], raw_disk, journal, mount, image)


def verify(folder, *, completed=True):
    plan, receipt = (read(folder / name) for name in ("plan.json", RECEIPT))
    _, product_sha, runner_sha = PRODUCTS[plan["arm"]]
    scope = Path(plan["scope"])
    owner, token = receipt["owner"], receipt["token"]
    require(scope.parent == Path("/private/tmp") and scope.name == owner and re.fullmatch(r"mp-t-[a-z0-9_]{8}", owner)
            and re.fullmatch(r"[a-f0-9]{12}", token) and receipt["socket"] == str(scope / "a/docker.sock"),
            "burst did not use its native worker socket")
    require((not completed or read(folder / "status.json") == {"complete": True}) and receipt["complete"] is True
            and not scope.exists() and read(folder / "cleanup.json") == {"scope": str(scope), "retained": False, "errors": []}
            and plan["baseline_files"] == 24 and read(folder / "verification.json") == {
                "baseline_files": 24, "extra_cleanup_errors": []}, "burst or private worker cleanup incomplete")
    require(terminal.digest(folder / "worker-build.json") == plan["product_sha256"] == product_sha
            and plan["runner_sha256"] == runner_sha and plan["pages"]["kernel_image_sha256"] == kernel.EXPECTED_IMAGE
            and terminal.digest(folder / Path(__file__).name) == plan["source_sha256"]
            and (folder / "engine-read.sh").read_text() == polling.ENGINE_READER, "sealed inputs differ")
    facts = (folder / "a/guest-facts.txt").read_text().splitlines()
    boot, = [line.removeprefix("boot=") for line in facts if line.startswith("boot=")]
    require(plan["pages"]["kernel_config_sha256"] == kernel.EXPECTED_CONFIG
            and "config_sha256=" + kernel.EXPECTED_CONFIG in facts
            and read(folder / "worker-identity.json")["candidate_sha256"] == polling.products.HOST_SHA,
            "live native host executable or guest kernel differs")
    before, after = [polling.engine_readback(folder / f"engine-{phase}.txt", boot, runner_sha) for phase in ("before", "after")]
    require(before == after, "native engine changed")
    verify_volume(folder, plan, scope)
    jobs, ids, output = receipt["jobs"], [], []
    require(len(jobs) == len(CODES), "missing foreground jobs")
    for i, job in enumerate(jobs):
        name = f"{owner}-burst-{token}-{i}"
        initial, final = job["before"], job["after"]
        cid = lifecycle.owned(initial, {name}, owner, token)
        ids.append(cid)
        code = CODES[i]
        argv = launch_args(SimpleNamespace(owner=owner), scope / "workspace/log-burst-gate", i, name, token)
        require(job["slot"] == i and job["name"] == name and lifecycle.owned(final, {name}, owner, token) == cid
                and job["argv"] == argv and initial["Config"]["Cmd"] == final["Config"]["Cmd"] == argv[argv.index(IMAGE) + 1:]
                and initial["Config"]["Entrypoint"] == final["Config"]["Entrypoint"] == ["/bin/sh"]
                and initial["Image"] == final["Image"] == "sha256:" + CONFIG
                and initial["State"]["Status"] == "running" and initial["State"]["Running"] is True
                and final["State"]["Status"] == "exited" and final["State"]["Running"] is False
                and final["State"]["OOMKilled"] is False and initial["State"]["StartedAt"] == final["State"]["StartedAt"]
                and job["exit_code"] == final["State"]["ExitCode"] == code and job["wait"] == {"StatusCode": code}
                and job["wait_path"] == f"/containers/{cid}/wait?condition=next-exit"
                and job["host_started_unix_ns"] <= job["wait_headers_unix_ns"] <= receipt["release_unix_ns"]
                < receipt["exit_release_unix_ns"] <= job["host_reaped_unix_ns"], "foreground launch, wait or inspect differs")
        files = {stream: check_stream(raw(folder, i, stream), b"".join(streams(i, stream))) for stream in STREAMS}
        require(job["streams"] == files and job["live_streams"] == {
            stream: digest_record(streams(i, stream)[0]) for stream in STREAMS}, "log stream receipt differs from expected bytes")
        output.append({"slot": i, "exit_code": code, "streams": files})
    require(len(set(ids)) == len(CODES) and receipt["first_running_ids"] == receipt["last_running_ids"] == sorted(ids)
            and receipt["cleanup"]["all_absent"] is True and set(receipt["cleanup"]["removed"]) == set(ids)
            and receipt["resources_after"] == receipt["resources_before"] and not receipt["resources_after"]["containers"],
            "foreground overlap or owned resource retirement differs")
    return {"arm": plan["arm"], "scope": str(scope), "boot": boot, "runner_sha256": runner_sha,
            "archive": folder.name, "jobs": output}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    live = commands.add_parser("run")
    live.add_argument("--arm", choices=PRODUCTS, required=True)
    live.add_argument("--image-archive", type=Path, default=ARCHIVE)
    replay = commands.add_parser("replay")
    replay.add_argument("folders", type=Path, nargs="+")
    args = parser.parse_args()
    if args.command == "replay":
        results = [verify(folder.resolve()) for folder in args.folders]
        require(1 <= len(results) <= 2 and all(len({row[key] for row in results}) == len(results)
                                               for key in ("arm", "scope", "boot")), "expected independent fresh arms")
        print(json.dumps(results, indent=2))
        return
    folder = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime(f"%Y%m%dT%H%M%SZ-{PREFIX}-{args.arm}-"), dir=HERE))
    print(folder, flush=True)
    signal.signal(signal.SIGTERM, terminal.exit_on_signal)
    status = {"complete": False}
    try:
        with terminal.terminal_lock():
            study(folder, args)
            replay = verify(folder, completed=False)
            terminal.save(folder / "summary.json", replay)
        status["complete"] = True
    except BaseException as error:
        status["error"] = str(error) or type(error).__name__
        raise
    finally:
        terminal.save(folder / "status.json", status)


if __name__ == "__main__":
    main()
