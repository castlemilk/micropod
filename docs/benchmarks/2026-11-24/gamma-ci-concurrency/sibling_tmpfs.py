"""Compare native OverlayFS and private executable tmpfs for build scratch."""

import json
import os
import plistlib
import re
import shutil
from pathlib import Path

from qualify import LABEL, cli, require, terminal


MODES = ("overlay", "tmpfs")
SLOTS = range(8)
SIZE_KIB = 128 * 1024
TMP_OPTIONS = "rw,exec,nosuid,nodev,size=128m,mode=1777"
TMPFS_TESTS = ("TestDockerTmpfsConfig", "TestDockerTmpfsValidation", "TestDockerTmpfsOCISpec")
RUNNER_TESTS = (*TMPFS_TESTS, "TestDockerStopKeepsOriginalGeneration")
SMOKE_MOUNTS = {"/tmp": TMP_OPTIONS, "/scratch-ro": "ro,noexec,nosuid,nodev,size=1m,mode=0555",
                "/scratch-noexec": "rw,noexec,nosuid,nodev,size=1m,mode=1777", "/scratch-default": ""}
DIRECTORY = "go-scratch"
HOOK = "go-scratch-boot.sh"
DRIVER = "go-scratch-driver.py"
BOOT = "go-scratch-boot.txt"
BY_PHASE = "go-scratch-{}.json"
BOOT_ID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
RESTART_PROBE = """exec 2>&1
set -x
test ! -e /tmp/previous-start
test "$(stat -c %a /tmp)" = 1777
printf '#!/bin/sh\\nexit 0\\n' > /tmp/previous-start
chmod 0700 /tmp/previous-start
/tmp/previous-start
if touch /scratch-ro/write-test 2>/dev/null; then exit 31; fi
cp /tmp/previous-start /scratch-noexec/exec-test
chmod 0700 /scratch-noexec/exec-test
if /scratch-noexec/exec-test 2>/dev/null; then exit 32; fi
ram_kib=$(awk '$1=="MemTotal:" {print $2}' /proc/meminfo)
default_kib=$(df -Pk /scratch-default | awk 'NR==2 {print $2}')
page_kib=$(( $(getconf PAGESIZE) / 1024 ))
test "$default_kib" -ge "$((ram_kib / 2 - page_kib))"
test "$default_kib" -le "$((ram_kib / 2 + page_kib))"
stat_shmem() { awk '$1=="shmem" {print $2}' /sys/fs/cgroup/memory.stat; }
before=$(stat_shmem)
dd if=/dev/zero of=/tmp/memory-check bs=1048576 count=4 2>/dev/null
for try in 1 2 3 4 5; do
    after=$(stat_shmem)
    [ "$after" -ge "$((before + 4194304))" ] && break
    sleep 0.5
done
test "$after" -ge "$((before + 4194304))"
printf 'scratch %s %s %s %s\\n' "$ram_kib" "$default_kib" "$before" "$after"
"""

BOOT_HOOK = r'''
(
    set -eu
    root="${MICROPOD_ENGINE_WORKSPACE:?}/go-scratch"
    [ -d "$root" ] && [ ! -L "$root" ] && [ ! -e "$root/guest-mounts.txt" ] || exit 1
    IFS= read -r mode < "$root/mode"
    case "$mode" in overlay|tmpfs) ;; *) exit 1 ;; esac
    {
        printf 'boot=%s\nmode=%s\n' "$(cat /proc/sys/kernel/random/boot_id)" "$mode"
        awk '$5 == "/" {print "mount " $0}' /proc/self/mountinfo
    } > "$root/guest-mounts.tmp"
    mv "$root/guest-mounts.tmp" "$root/guest-mounts.txt"
) || exit 1
'''

PROBE = r'''
id=$1
tmp=$(realpath "${TMPDIR:-/tmp}")
go_tmp=$(realpath "${GOTMPDIR:-${TMPDIR:-/tmp}}")
printf 'boot=%s\npage_bytes=%s\nuid=%s\ngid=%s\n' "$(cat /proc/sys/kernel/random/boot_id)" "$(getconf PAGESIZE)" "$(id -u)" "$(id -g)"
printf 'tmp=%s\ngo_tmp=%s\ngoenv=%s\n' "$tmp" "$go_tmp" "${GOENV:-}"
printf 'gocache=%s\ngomodcache=%s\n' "$(realpath "${GOCACHE:?}")" "$(realpath "${GOMODCACHE:?}")"
printf 'cache_inode=%s\n' "$(stat -Lc '%d:%i' /cache)"
printf 'tmp_mode=%s\ntmp_capacity_kib=%s\n' "$(stat -Lc '%a' "$tmp")" "$(df -Pk "$tmp" | awk 'NR==2 {print $2}')"
awk '$5 == "/" || $5 == "/cache" || $5 == "/tmp" {print "mount " $0}' /proc/self/mountinfo
printf 'memory_peak_bytes=%s\n' "$(cat /sys/fs/cgroup/memory.peak)"
awk '$1=="oom" || $1=="oom_kill" {print $1 "=" $2}' /sys/fs/cgroup/memory.events
canary=$(mktemp "$tmp/mp-scratch.XXXXXX")
trap 'rm -f "$canary"' EXIT
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$1"' > "$canary"
chmod 0700 "$canary"
printf 'exec=%s\nexec_owner=%s\n' "$("$canary" "$id")" "$(stat -Lc '%u:%g' "$canary")"
'''


def stage(oci, work, folder, mode):
    require(mode in MODES, "unknown compiler scratch setting")
    root = work / DIRECTORY
    root.mkdir(mode=0o700)
    (root / "mode").write_text(mode + "\n")
    with (oci / "runner/fixture-facts.sh").open("a") as hook:
        hook.write(BOOT_HOOK)
    (folder / HOOK).write_text(BOOT_HOOK)
    shutil.copy2(Path(__file__), folder / DRIVER)
    return {"build_scratch": mode, "scratch_hook_sha256": terminal.digest(folder / HOOK),
            "scratch_driver_sha256": terminal.digest(folder / DRIVER), "scratch_tmpfs_kib": SIZE_KIB,
            "scratch_runner_tests": list(RUNNER_TESTS)}


def flags(arm, mode, slot):
    require(arm in ("A", "B") and mode in (None, *MODES) and slot in SLOTS, "wrong build scratch scope")
    if mode == "tmpfs" and arm == "A":
        return ["--tmpfs", "/tmp:" + TMP_OPTIONS]
    return []


def check_restart(proof, owner, image):
    require(re.fullmatch(r"[a-f0-9]{64}", proof["id"]) and proof["removed"] is True
            and len(proof["starts"]) == len(proof["logs"]) == 2, "incomplete Docker tmpfs restart proof")
    times = []
    for row, log in zip(proof["starts"], proof["logs"], strict=True):
        state, config = row["State"], row["Config"]
        request = row["HostConfig"].get("Tmpfs") or {}
        measured = re.fullmatch(r"scratch (\d+) (\d+) (\d+) (\d+)", log.splitlines()[-1])
        require(measured and int(measured[4]) - int(measured[3]) >= 4 << 20 and
                abs(int(measured[1]) // 2 - int(measured[2])) <= 16, "incorrect tmpfs memory accounting or default capacity")
        require(row["Id"] == proof["id"] and row["Name"].lstrip("/") == owner + "-scratch-restart"
                and config["Labels"].get(LABEL) == owner and config["Image"] == image
                and config["Entrypoint"] == ["/bin/sh"] and config["Cmd"] == ["-ec", RESTART_PROBE]
                and request.keys() == SMOKE_MOUNTS.keys()
                and all(set(request[target].split(",")) == set(options.split(",")) for target, options in SMOKE_MOUNTS.items())
                and state["Running"] is False and state["ExitCode"] == 0 and not state.get("OOMKilled")
                and state["StartedAt"] and not state["StartedAt"].startswith("0001-"),
                "wrong container, tmpfs request or exit status on restart")
        times.append(state["StartedAt"])
    require(times[0] != times[1], "tmpfs lifecycle proof requires two different starts")


def restart_smoke(engine, folder, owner, image):
    name = owner + "-scratch-restart"
    cid = ""
    proof = {"starts": [], "logs": [], "removed": False}
    try:
        mounts = [arg for target, options in SMOKE_MOUNTS.items()
                  for arg in ("--tmpfs", target + (":" + options if options else ""))]
        cid = cli(engine, "create", "--pull=never", "--name", name, "--label", f"{LABEL}={owner}",
                  "--network", "none", "--memory", "128m", "--pids-limit", "64",
                  *mounts, "--entrypoint", "/bin/sh", image, "-ec", RESTART_PROBE)
        require(re.fullmatch(r"[a-f0-9]{64}", cid), "wrong scratch probe container ID")
        proof["id"] = cid
        for _ in range(2):
            cli(engine, "start", cid)
            code = cli(engine, "wait", cid)
            row, = json.loads(cli(engine, "inspect", cid))
            proof["starts"].append(row)
            proof["logs"].append(cli(engine, "logs", cid))
            require(code == "0", f"scratch start exited with {code}")
    finally:
        ids = cli(engine, "ps", "-aq", "--no-trunc", "--filter", f"label={LABEL}={owner}").split()
        for item in ids:
            row, = json.loads(cli(engine, "inspect", item))
            require(row["Name"].lstrip("/") == name and row["Config"]["Labels"].get(LABEL) == owner
                    and (not cid or item == cid), "ambiguous scratch restart cleanup")
        if ids:
            cli(engine, "rm", "-f", *ids)
        proof["removed"] = not cli(engine, "ps", "-aq", "--filter", f"label={LABEL}={owner}")
        terminal.save(folder / "go-scratch-restart.json", proof)
    check_restart(proof, owner, image)


def check_cli(folder, boot):
    cli_proof = json.loads((folder / "go-scratch-cli.json").read_bytes())
    worker = json.loads((folder / "worker-build.json").read_bytes())["worker_executable"]
    require(cli_proof["argv"][:5] == [worker, "ci", "run", "--scratch-mib", "128"]
            and cli_proof["code"] == 0 and cli_proof["auto_removed"] is True
            and cli_proof["stdout"] == f"native-cli {boot} {SIZE_KIB}", "public CLI scratch smoke differs")


def cli_smoke(engine, folder, owner, image):
    job = plistlib.loads((folder / "a/job.plist").read_bytes())
    env = job["EnvironmentVariables"]
    home = Path(env["MICROPOD_CI_HOME"]).resolve()
    require(home.parent.name == owner and home.name == "a" and env["MICROPOD_CI_ENGINE"] == "containerd",
            "CLI scratch check requires the disposable native worker")
    name = owner + "-scratch-cli"
    args = [job["ProgramArguments"][0], "ci", "run", "--scratch-mib", "128", "--pull=never", "--name", name,
            "--label", f"{LABEL}={owner}", "--network", "none", "--memory", "128m", "--pids-limit", "64",
            "--entrypoint", "/bin/sh", image, "-ec",
            """test "$(stat -f -c %T /tmp)" = tmpfs
test "$(stat -c %a /tmp)" = 1777
printf '#!/bin/sh\\nexit 0\\n' >/tmp/cli-check
chmod 0700 /tmp/cli-check
/tmp/cli-check
printf 'native-cli %s %s\\n' "$(cat /proc/sys/kernel/random/boot_id)" "$(df -Pk /tmp | awk 'NR==2 {print $2}')" """]
    receipt = {}
    try:
        outcome = terminal.invoke(*args, timeout=40, check=False, env={**os.environ, **env})
        receipt.update(argv=args, code=outcome.returncode, stdout=outcome.stdout.strip(), stderr=outcome.stderr[-1200:])
    finally:
        ids = cli(engine, "ps", "-aq", "--no-trunc", "--filter", f"label={LABEL}={owner}").split()
        receipt["auto_removed"] = not ids
        for cid in ids:
            row, = json.loads(cli(engine, "inspect", cid))
            require(row["Name"].lstrip("/") == name and row["Config"]["Labels"].get(LABEL) == owner,
                    "ambiguous CLI scratch cleanup")
            cli(engine, "rm", "-f", cid)
        terminal.save(folder / "go-scratch-cli.json", receipt)
    boot = read_fields((folder / BOOT).read_text())[0]["boot"]
    check_cli(folder, boot)
    return receipt


def read_fields(text):
    values, mounts = {}, {}
    for line in text.splitlines():
        if line.startswith("mount "):
            before, after = line.removeprefix("mount ").split(" - ", 1)
            mount_id, _, device, root, target, options, *_ = before.split()
            fs, source, super_options = after.split()
            target = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), target)
            require(target not in mounts and re.fullmatch(r"[0-9]+:[0-9]+", device), "invalid scratch mount identity")
            mounts[target] = {"id": int(mount_id), "device": device, "root": root, "fs": fs, "source": source,
                              "options": options.split(","), "super_options": super_options.split(",")}
        else:
            key, value = line.split("=", 1)
            require(key not in values, "duplicate scratch observation")
            values[key] = value
    require(re.fullmatch(BOOT_ID, values["boot"]), "invalid scratch boot identity")
    return values, mounts


def check_tmpfs(mount):
    options = set(mount["options"])
    require(mount["fs"] == "tmpfs" and mount["root"] == "/" and {"rw", "nosuid", "nodev"} <= options
            and not options & {"noexec", "ro"} and f"size={SIZE_KIB}k" in mount["super_options"],
            "wrong size, filesystem or flags for executable scratch")


def check_boot(raw, work, mode, facts):
    values, mounts = read_fields(raw)
    require(mode in MODES and values["mode"] == mode and "boot=" + values["boot"] in facts.splitlines(),
            "wrong private guest for scratch mounts")
    require(set(mounts) == {"/"} and mounts["/"]["fs"] == "ext4", "unexpected guest root filesystem")
    return values["boot"], mounts


def capture_boot(work, folder, mode, facts):
    source = work / DIRECTORY / "guest-mounts.txt"
    check_boot(source.read_text(), work, mode, facts.read_text())
    shutil.copy2(source, folder / BOOT)


def check_jobs(rows, inventory, work, arm, mode, boot, worker_mounts):
    count = len(inventory["jobs"]) // 2
    jobs = inventory["jobs"][count:count + len(SLOTS)]
    require(len(rows) == len(jobs) == len(SLOTS), "scratch qualification needs eight builder receipts")
    results = []
    for slot, (row, job) in enumerate(zip(rows, jobs, strict=True)):
        cid = job["id"]
        values, mounts = read_fields(row["readback"])
        require(row["id"] == cid == values["exec"] and values["uid"] == values["gid"] == "0"
                and values["exec_owner"] == "0:0" and values["tmp_mode"] == "1777"
                and values["tmp"] == values["go_tmp"] == "/tmp" and values["goenv"] == "off"
                and values["gocache"] == "/cache/build" and values["gomodcache"] == "/cache/mod"
                and values["page_bytes"] == ("16384" if arm == "A" else "4096") and mounts["/"]["fs"] == "overlay",
                "scratch execution, ownership or Go paths differ")
        require(int(values["memory_peak_bytes"]) > 0 and values["oom"] == values["oom_kill"] == "0",
                "scratch builder exhausted its memory allocation")
        cache = mounts["/cache"]
        require(cache["fs"] == ("ext4" if arm == "A" else "btrfs") and "rw" in cache["options"]
                and (arm == "B" or (values["boot"] == boot and cache["device"] == worker_mounts["/"]["device"]
                                    and cache["super_options"] == worker_mounts["/"]["super_options"])),
                "shared cache filesystem differs")
        argv = job["create_argv"]
        tmpfs_args = [argv[i + 1] for i, flag in enumerate(argv) if flag == "--tmpfs"]
        require(tmpfs_args == flags(arm, mode, slot)[1:] and not any(arg.endswith(",dst=/tmp") for arg in argv),
                "unexpected Docker scratch mount request")
        docker_tmpfs = job["docker_inspect"]["HostConfig"].get("Tmpfs") or {}
        if mode == "tmpfs" and arm == "A":
            require(set(docker_tmpfs) == {"/tmp"} and set(docker_tmpfs["/tmp"].split(",")) == set(TMP_OPTIONS.split(",")),
                    "native Docker inspect lost the requested scratch configuration")
            temp = mounts["/tmp"]
            check_tmpfs(temp)
            require(temp["device"] not in (cache["device"], mounts["/"]["device"])
                    and int(values["tmp_capacity_kib"]) == SIZE_KIB, "wrong private scratch capacity or device")
        else:
            require(not docker_tmpfs and "/tmp" not in mounts and "noexec" not in mounts["/"]["options"],
                    "control scratch did not use the container's writable overlay")
        results.append({"boot": values["boot"], "uid": values["uid"], "gid": values["gid"],
                        "cache_inode": values["cache_inode"], "cache_device": cache["device"], "cache_root": cache["root"],
                        "scratch_mount": mounts.get("/tmp", mounts["/"])["id"],
                        "scratch_device": mounts.get("/tmp", mounts["/"])["device"]})
    require(len({(row["boot"], row["cache_inode"], row["cache_device"], row["cache_root"]) for row in results}) == 1,
            "builders do not share one persistent Go cache and guest boot")
    if mode == "tmpfs" and arm == "A":
        require(len({r["scratch_device"] for r in results}) == len(SLOTS), "two live builders share a scratch superblock")
    return results


def check_linux_tests(output, expected):
    passed = set(re.findall(r"^--- PASS: (\w+) \(", output, flags=re.MULTILINE))
    missing = sorted(set(expected) - passed)
    require(not missing and output.rstrip().splitlines()[-1:] == ["PASS"],
            f"native scratch runner tests did not pass in Linux, missing {missing}")


def qualify(folder, cohorts, mode, phase):
    """Qualify the actual build clients outside the scored windows."""
    require(phase in ("before", "after"), "invalid scratch observation phase")
    work = cohorts["A"].work
    boot, mounts = check_boot((folder / BOOT).read_text(), work, mode, (folder / "a/guest-facts.txt").read_text())
    if phase == "before":
        native = cohorts["A"]
        output = native.cmd("exec", native.jobs[native.count]["id"], "/mpcheck/group-runner.test",
                            "-test.v", "-test.run", "^(TestDockerTmpfs.*|TestDockerStopKeepsOriginalGeneration)$")
        check_linux_tests(output, RUNNER_TESTS)
        (folder / "linux-docker-scratch-tests.txt").write_text(output + "\n")
    proof = {}
    for arm, cohort in cohorts.items():
        rows = []
        for job in cohort.jobs[cohort.count:cohort.count + cohort.builders]:
            cid = job["id"]
            rows.append({"id": cid, "readback": cohort.cmd("exec", cid, "sh", "-ec", PROBE, "sh", cid)})
        check_jobs(rows, {"jobs": cohort.jobs}, work, arm, mode, boot, mounts)
        proof[arm] = rows
    terminal.save(folder / BY_PHASE.format(phase), proof)


def verify_archived(folder, plan, inventories):
    import sibling_build

    mode = plan["build_scratch"]
    work = Path(plan["scope"]) / "workspace"
    require(mode in MODES and plan["scratch_tmpfs_kib"] == SIZE_KIB
            and (folder / HOOK).read_text() == BOOT_HOOK and terminal.digest(folder / HOOK) == plan["scratch_hook_sha256"]
            and terminal.digest(folder / DRIVER) == plan["scratch_driver_sha256"], "compiler scratch provenance differs")
    boot, mounts = check_boot((folder / BOOT).read_text(), work, mode, (folder / "a/guest-facts.txt").read_text())
    check_cli(folder, boot)
    check_restart(json.loads((folder / "go-scratch-restart.json").read_bytes()), Path(plan["scope"]).name, sibling_build.IMAGE)
    tests = (folder / "linux-docker-scratch-tests.txt").read_text()
    declared = plan.get("scratch_runner_tests")
    require(declared is None or declared == list(RUNNER_TESTS), "unexpected native scratch runner test list")
    check_linux_tests(tests, declared if declared is not None else TMPFS_TESTS)
    before, after = [json.loads((folder / BY_PHASE.format(phase)).read_bytes()) for phase in ("before", "after")]
    for arm in ("A", "B"):
        require(check_jobs(before[arm], inventories[arm], work, arm, mode, boot, mounts)
                == check_jobs(after[arm], inventories[arm], work, arm, mode, boot, mounts),
                "build scratch or cache changed during the run")
