"""Count actual native CRI status requests in a separate 64-container diagnostic."""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import shutil
import time
from unittest.mock import patch

from qualify import IMAGE, LABEL, ROOT, local_admission, require, terminal
import sibling_ci
import sibling_file_fault_around_holdout as holdout
import sibling_job_parent_evidence as parents
from sibling_worker_volume import mounted_worker_volume


HERE = Path(__file__).resolve().parent
SOURCE = "sibling_follow_rpcs_linux.go"
DRIVER = "sibling_follow_rpcs.py"
DIR = "follow-rpc-counters"
NAMES = ("idle-before", "positive", *(f"dense-{i}" for i in range(4)), "idle-after")
SEED = 250269


def read(path):
    return json.loads(path.read_bytes())


def await_file(work, name, timeout=25):
    until = time.monotonic() + timeout
    path = work / (name + ".json")
    while not path.is_file():
        if (work / "error.json").is_file():
            raise ValueError("guest CRI counter: " + str(read(work / "error.json")))
        if time.monotonic() > until:
            raise ValueError("no guest CRI counter receipt for " + name)
        time.sleep(.025)
    return read(path)


def summary(folder, expect_sha):
    identity = read(folder / DIR / "identity.json")
    kinds = set(identity["symbols"])
    phases = tuple(identity.get("probe_phases", NAMES))
    require(phases in (NAMES, (*NAMES[:2],"log-positive",*NAMES[2:])), "unknown RPC diagnostic schedule")
    require(identity["sha256"] == expect_sha and identity["boot"] == parents.boots(folder)["A"]
            and identity["online"] == "0-3" and identity["pid"] > 1
            and kinds in ({"status","stats"},{"status","stats","drain"}), "unmatched live RPC probe target")
    all_rows = {}
    last = 0
    birth = None
    for name in phases:
        record = read(folder / DIR / (name + ".json"))
        wall = record["duration_ns"]
        require(record["started_unix_ns"] > last and wall > 0 and record["before"]["pid"] == record["after"]["pid"] == identity["pid"]
                and record["before"]["birth_ticks"] == record["after"]["birth_ticks"], "engine or measurement lifetime changed")
        last = record["started_unix_ns"] + wall
        if birth is None:
            birth = record["before"]["birth_ticks"]
        require(record["before"]["birth_ticks"] == birth, "native Docker engine restarted between samples")
        counts = record["counters"]
        require(len(counts) == len(kinds)*4 and {(x["kind"], x["cpu"]) for x in counts} == {(k, i) for k in kinds for i in range(4)},
                "missing per-CPU uprobe counts")
        require(all(0 < x["running_ns"] <= x["enabled_ns"] and x["running_ns"] >= x["enabled_ns"] * .995
                    and x["enabled_ns"] >= wall * .98 and type(x["count"]) is int and x["count"] >= 0 for x in counts),
                "incomplete counter coverage")
        if name.startswith("idle") or name.startswith("dense"):
            require(wall >= 2_000_000_000, "short resident control or build envelope")
        if name.startswith("dense"):
            block = int(name.split("-")[1])
            builders = read(folder / f"grouped-{block}-all-A-go.json")
            require(len(builders) == 8 and all(x["code"] == 0 and x["stdout"].splitlines()[-1].split()[0::2] == ["end","0"]
                    and record["started_unix_ns"] < x["started_unix_ns"] < int(x["stdout"].splitlines()[-1].split()[1]) < last
                    for x in builders), "native builds fell outside the perf counter envelope")
        total = {k: sum(x["count"] for x in counts if x["kind"] == k) for k in sorted(kinds)}
        if name == "positive":
            require(total["stats"] == 8 and total["status"] >= 8, "real Docker stats requests did not reach the CRI client")
        elif name == "log-positive":
            observed = read(folder / DIR / "requested-log.json")
            require(total["stats"] == 0 and total["status"] > 0 and total["drain"] > 0
                    and observed == {"code":0, "stdout":"notify-out\n", "stderr":"notify-err\n", "retired":True},
                    "positive log control did not reach the compiled runner")
        else:
            require(total["stats"] == 0, "unrequested Docker stats in observed cohort")
        all_rows[name] = {**total, "duration_s": wall / 1e9, "status_per_s": total["status"] / (wall / 1e9),
                          "engine_read_syscalls": record["after"]["read_syscalls"]-record["before"]["read_syscalls"]}
    probe = read(folder / DIR / "requested-stats.json")
    jobs = read(folder / "grouped-inventory.json")["A"]["jobs"]
    require([x["id"] for x in probe] == [j["id"] for j in jobs[:8]] and all(
            row["cpu_online"] == 4 and row["memory_usage"] > 0 for row in probe), "unverified one-shot stats requests")
    require(read(folder / DIR / "retired.json") == {"counter_fds_closed": 4*len(kinds)*len(phases), "boot":identity["boot"]},
            "guest perf counter fds did not retire")
    if "containerd_initial_settings" in identity:
        settings = identity["containerd_initial_settings"]
        require(isinstance(settings, dict) and all(isinstance(k,str) and type(v) is int
                and 0 <= v < 2**32 for k,v in settings.items()), "invalid bundled containerd HTTP/2 settings")
    return {"archive":folder.name, "runner":identity, "counts":all_rows}


def compare(folders, manifest):
    from sibling_worker_volume_results import verify_volume

    product = read(manifest)
    arms = {}
    signature = None
    for folder in map(Path, folders):
        plan = read(folder / "plan.json")
        mode = plan["follow_rpc_diagnostic"]
        require(mode in ("stock","optimized") and mode not in arms and plan["seed"] == SEED
                and plan["file_fault_around_bytes"] == 65536 and plan["builders"] == 8 and plan["offered_rps"] == 64000,
                "unexpected diagnostic mode or workload")
        arm = product["arms"][mode]
        require(terminal.digest(folder / "worker-build.json") == arm["product_sha256"]
                and read(folder / "status.json") == {"complete": True}, "unexpected diagnostic worker")
        facts = summary(folder, arm["runner_sha256"])
        require(facts == read(folder / "follow-rpc-summary.json")
                and "containerd_initial_settings" in facts["runner"] and "drain" in facts["runner"]["symbols"], "diagnostic replay differs")
        inventory = read(folder / "grouped-inventory.json")
        require(all(len(inventory[a]["jobs"]) == 64 and len(inventory[a]["network_creates"]) == 32 for a in ("A","B")),
                "diagnostic lost resident jobs or their networks")
        source = {n:terminal.digest(folder / n) for n in (DRIVER,SOURCE)}
        life = read(folder / "follow-lifecycle.json")
        require(source == plan["follow_rpc_sources"] and plan["lifecycle_check_sha256"] ==
                terminal.digest(folder / "sibling_follow_lifecycle.py") and plan["lifecycle_extra_residents"] == 48,
                "diagnostic or lifecycle code differs from its plan")
        require(life["complete"] and life["cleanup"]["all_absent"] and life["residents"]["expected_total"] == 112
                and life["owner"] == Path(plan["scope"]).name, "incomplete high-density lifecycle")
        original = [job["id"] for job in inventory["A"]["jobs"]]
        extra = [job["id"] for job in life["residents"]["launches"]]
        residents = life["residents"]["inventory"]
        require(len(set(original + extra)) == len(residents) == 112 and [r["id"] for r in residents] == original + extra
                and all(r["state"]["Running"] and r["state"]["Status"] == "running" and not r["state"]["OOMKilled"]
                        for r in residents), "112 native containers were not simultaneously running")
        gate, kill, fast = life["gated"], life["killed"], life["foreground_exits"]
        require(gate["start_requested_unix_ns"] >= max(x["host_unix_ns"] for x in gate["wait_headers"])
                and gate["start_requested_unix_ns"] <= gate["ready_observed_unix_ns"] <= gate["released_unix_ns"]
                and gate["running_state"]["Running"] and gate["ready_output"] == {"stdout":"ready-out\n","stderr":"ready-err\n"}
                and gate["final_output"] == {"stdout":"final-out","stderr":"final-err"} and gate["exit_state"]["ExitCode"] == 43
                and gate["wait_results"] == [{"StatusCode":43}]*2 and kill["wait_result"] == {"StatusCode":137}
                and kill["exit_state"]["ExitCode"] == 137, "Docker wait acknowledgment or log playback differs")
        require([r["code"] for r in fast] == [0,7,12,19,23,37] and all(
                (row["stdout"],row["stderr"]) == (f"fast-out-{i}",f"fast-err-{i}") for i,row in enumerate(fast))
                and max(r["host_started_unix_ns"] for r in fast) < min(r["host_finished_unix_ns"] for r in fast)
                and life["automatically_removed"] == [r["name"] for r in fast]
                and set(life["cleanup"]["removed"]) == set(extra) | {gate["id"],kill["id"]},
                "native concurrent foreground exits or exact cleanup differ")
        require(life["started_unix_ns"] > max(x["host_finished_unix_ns"] for x in read(folder / holdout.WINDOWS))
                and life["finished_unix_ns"] > life["started_unix_ns"], "extra residents started during a measured wave")
        matched = source, plan["follow_rpc_probe_sha256"], plan["lifecycle_check_sha256"], facts["runner"]["containerd_initial_settings"]
        require(signature is None or signature == matched, "diagnostic treatment used different instrumentation or stream settings")
        signature = matched
        disk = verify_volume(folder)
        intervals = {}
        for key in ("idle","dense"):
            rows = [r for k,r in facts["counts"].items() if k.startswith(key)]
            duration = sum(r["duration_s"] for r in rows)
            intervals[key] = {"seconds":duration, "status_calls":sum(r["status"] for r in rows),
                              "status_per_s":sum(r["status"] for r in rows)/duration,
                              "cri_log_drains_per_s":sum(r["drain"] for r in rows)/duration,
                              "engine_read_syscalls_per_s":sum(r["engine_read_syscalls"] for r in rows)/duration}
        arms[mode] = {"archive":folder.name, "runner":facts["runner"], "intervals":intervals,
                      "requested_stats":facts["counts"]["positive"], "lifecycle":life, "storage":disk["persisted_policy"]}
    require(set(arms) == {"stock","optimized"} and arms["stock"]["runner"]["boot"] != arms["optimized"]["runner"]["boot"],
            "expected two fresh workers")
    return arms


def run(args):
    args.seed, args.fault_around_bytes = SEED, 65536
    product = read(args.product)
    state = {}
    staging, capture = holdout.stage, parents.capture
    original_wave, original_cleanup = sibling_ci.Siblings.run_wave, sibling_ci.Siblings.clean

    def stage(oci, work, folder, window):
        base = staging(oci, work, folder, window)
        data = work / DIR
        data.mkdir(mode=0o700)
        evidence = folder / DIR
        evidence.mkdir()
        state.update(data=data, evidence=evidence)
        for name in (DRIVER, SOURCE):
            shutil.copyfile(HERE / name, folder / name)
        if args.check_lifecycle:
            shutil.copyfile(HERE / "sibling_follow_lifecycle.py", folder / "sibling_follow_lifecycle.py")
        binary = work / "probe/follow-rpcs"
        env = {**os.environ, "GOOS":"linux", "GOARCH":"arm64", "CGO_ENABLED":"0", "GOPROXY":"off"}
        terminal.invoke("go", "-C", ROOT / "guest/runner", "build", "-trimpath", "-buildvcs=false", "-o", binary,
                        folder / SOURCE, env=env, timeout=120)
        with (oci / "runner/fixture-facts.sh").open("a") as script:
            extra = " log-positive" if args.profile == "log-notify" else ""
            script.write('\n"$MICROPOD_ENGINE_WORKSPACE/probe/follow-rpcs" "$MICROPOD_ENGINE_WORKSPACE/' + DIR
                         + '"' + extra + ' </dev/null >"$MICROPOD_ENGINE_WORKSPACE/' + DIR + '/observer.log" 2>&1 &\n')
        return {**base, "follow_rpc_diagnostic": args.profile, "follow_rpc_probe_sha256":terminal.digest(binary),
                "lifecycle_check_sha256": terminal.digest(folder / "sibling_follow_lifecycle.py") if args.check_lifecycle else None,
                "lifecycle_extra_residents": args.extra_residents,
                "follow_rpc_sources":{name:terminal.digest(folder / name) for name in (DRIVER,SOURCE)}}

    def begin(name):
        data = state["data"]
        (data / (name + ".start")).touch(exist_ok=False)
        await_file(data, name+"-armed")

    def finish(name):
        data = state["data"]
        (data / (name+".stop")).touch(exist_ok=False)
        await_file(data, name)
        for suffix in (".json","-armed.json"):
            shutil.copyfile(data / (name+suffix), state["evidence"] / (name+suffix))

    def observe(folder, cohorts, phase):
        capture(folder, cohorts, phase)
        name = "idle-"+phase
        begin(name)
        time.sleep(2.5)
        finish(name)
        data, dest = state["data"], state["evidence"]
        if phase == "before":
            shutil.copyfile(data/"identity.json",dest/"identity.json")
            native = cohorts["A"]
            sock, = [Path(str(item).removeprefix("unix://")) for item in native.engine if str(item).startswith("unix://")]
            require(sock.resolve() == Path(read(folder/"plan.json")["scope"]) / "a/docker.sock", "wrong scoped native socket")
            begin("positive")
            rows = []
            try:
                for job in native.jobs[:8]:
                    response = local_admission.read_json(sock, f'/v1.47/containers/{job["id"]}/stats?stream=false&one-shot=true')
                    require(response["id"]==job["id"], "one-shot stats returned the wrong container")
                    rows.append({"id":response["id"],"cpu_online":response["cpu_stats"]["online_cpus"],
                                 "memory_usage":response["memory_stats"]["usage"]})
            finally:
                finish("positive")
            terminal.save(dest/"requested-stats.json",rows)
            if args.profile == "log-notify":
                name = native.owner + "-log-positive"
                tag = "io.micropod.bench.follow-log-positive=" + native.owner
                begin("log-positive")
                try:
                    proc = terminal.invoke(*native.engine, "run", "--rm", "--pull=never", "--name", name,
                                           "--network", "none", "--memory", "32m", "--pids-limit", "16",
                                           "--label", f"{LABEL}={native.owner}", "--label", tag, "--entrypoint", "/bin/sh",
                                           IMAGE, "-ec", "echo notify-out; echo notify-err >&2", timeout=25, check=False)
                    retired = not native.cmd("ps","-aq","--filter","label="+tag,timeout=10)
                    terminal.save(dest/"requested-log.json", {"code":proc.returncode,"stdout":proc.stdout,
                                                              "stderr":proc.stderr,"retired":retired})
                finally:
                    finish("log-positive")
        else:
            await_file(data,"retired")
            shutil.copyfile(data/"retired.json",dest/"retired.json")
            if args.profile == "log-notify":
                shutil.copyfile(data/"engine-watches-after.json", dest/"engine-watches-after.json")
            terminal.save(folder/"follow-rpc-summary.json",summary(folder,product["guest_runner_sha256"]))
            if args.check_lifecycle:
                import sibling_follow_lifecycle
                sibling_follow_lifecycle.check(folder, cohorts["A"], extra_residents=args.extra_residents)
            if args.profile == "log-notify":
                cohort = cohorts["A"]
                job = cohort.jobs[cohort.count]
                output = cohort.cmd("exec", job["id"], "/bin/sh", "-ec",
                                    'export TMPDIR=/dev/shm MICROPOD_CRI_LOG_TEST_TMPFS=/dev/shm; exec /mpcheck/group-runner.test "$@"',
                                    "log-tests",
                                    "-test.v", "-test.run", args.notify_test_pattern, timeout=120)
                (folder / "linux-log-notify-tests.txt").write_text(output + "\n")
                roots = [line.removeprefix("=== RUN   ") for line in output.splitlines()
                         if line.startswith("=== RUN   ") and "/" not in line]
                require(bool(roots) and output.splitlines()[-1] == "PASS" and not any(
                        "SKIP:" in line for line in output.splitlines()), "candidate's Linux log tests did not run")
                require(any("watch" in name.lower() or "inotify" in name.lower() or "notify" in name.lower() for name in roots),
                        "candidate's real Linux tests were not selected")

    def wave(cohort, folder, block, indices, *args):
        if cohort.arm!="A" or len(indices)==1:
            return original_wave(cohort,folder,block,indices,*args)
        key=f"dense-{block}"
        begin(key)
        try:
            return original_wave(cohort,folder,block,indices,*args)
        finally:
            finish(key)

    def cleanup(cohort):
        try:
            if cohort.arm=="A" and state and state["data"].is_dir():
                data=state["data"]
                (data/"abort").touch()
                for path in data.iterdir():
                    if path.suffix==".json" or path.name=="observer.log":
                        shutil.copyfile(path,state["evidence"]/path.name)
        finally:
            original_cleanup(cohort)

    with ExitStack() as stack:
        stack.enter_context(mounted_worker_volume())
        prefix = "sibling-log-notify" if args.profile == "log-notify" else "sibling-follow-rpcs"
        for module,key,value in [(holdout,"PREFIX",prefix),(holdout,"SEED_ORDER",{SEED:(65536,)}),
                                 (holdout,"stage",stage),(parents,"capture",observe),(sibling_ci.Siblings,"run_wave",wave),
                                 (sibling_ci.Siblings,"clean",cleanup)]:
            stack.enter_context(patch.object(module,key,value))
        holdout.run(args)


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest="cmd",required=True)
    live=sub.add_parser("run")
    live.add_argument("--profile",choices=("stock","optimized","log-notify"),required=True)
    live.add_argument("--notify-test-pattern",default="^TestCRI(Log|Follow|Output)")
    live.add_argument("--check-lifecycle",action="store_true")
    live.add_argument("--extra-residents",type=int,choices=(0,48),default=0)
    for key in ("product","page-kernel-pair","ipvlan-kernel","quiet-source","image-archive"):
        live.add_argument("--"+key,type=Path,required=True)
    offline=sub.add_parser("replay")
    offline.add_argument("folder",type=Path)
    paired=sub.add_parser("compare")
    paired.add_argument("folders",nargs=2,type=Path)
    paired.add_argument("--manifest",type=Path,required=True)
    args=parser.parse_args()
    if args.cmd=="run":
        require(not args.extra_residents or args.check_lifecycle, "extra residents require a lifecycle check")
        run(args)
    elif args.cmd=="compare":
        print(json.dumps(compare(args.folders,args.manifest),indent=2))
    else:
        require(read(args.folder/"status.json")=={"complete":True}, "incomplete characterization")
        print(json.dumps(summary(args.folder,read(args.folder/"worker-build.json")["guest_runner_sha256"]),indent=2))
