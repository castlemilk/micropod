"""Exercise container CPU bandwidth on a disposable worker with a known scheduler."""
import argparse
from contextlib import ExitStack
import json
from pathlib import PurePosixPath
import subprocess
import sys
import uuid


# Measure the busy processes inside the cgroup. Docker startup is outside the window.
PROBE = r'''
set -eu
cg=/sys/fs/cgroup
scx=/sys/kernel/sched_ext
scheduler() {
    if [ -r "$scx/state" ]; then cat "$scx/state"; else echo unavailable; fi
    if [ -r "$scx/root/ops" ]; then cat "$scx/root/ops"; else echo -; fi
    if [ -r "$scx/enable_seq" ]; then cat "$scx/enable_seq"; else echo -; fi
}
start_scheduler=$(scheduler)
spin() { while :; do :; done; }
spin & first=$!
spin & second=$!
trap 'kill "$first" "$second" 2>/dev/null || true' EXIT
for pid in "$first" "$second"; do
    awk '$1 == "ext.enabled" {print "ext_task=" $3}' "/proc/$pid/sched"
done
sample() {
    awk '$1 == "usage_usec" {print $2}' "$cg/cpu.stat"
    cut -d' ' -f1 /proc/uptime
}
before=$(sample)
sleep 5
after=$(sample)
end_scheduler=$(scheduler)
[ "$start_scheduler" = "$end_scheduler" ] || { echo "scheduler changed during run" >&2; exit 1; }
set -- $start_scheduler
printf 'state=%s\nops=%s\nsequence=%s\n' "$1" "$2" "$3"
set -- $before $after
printf 'start_usec=%s\nstart_s=%s\nend_usec=%s\nend_s=%s\n' "$1" "$2" "$3" "$4"
printf 'cpu_max=%s\nmemory_max=%s\npids_max=%s\n' "$(cat "$cg/cpu.max")" "$(cat "$cg/memory.max")" "$(cat "$cg/pids.max")"
'''


def check(output, quota, scheduler):
    fields, tasks = {}, []
    for line in output.splitlines():
        key, value = line.split("=", 1)
        if key == "ext_task":
            tasks.append(value)
        else:
            fields[key] = value
    elapsed = float(fields["end_s"]) - float(fields["start_s"])
    if elapsed <= 0:
        raise ValueError("CPU sample has no elapsed time")
    cpu_seconds = (int(fields["end_usec"]) - int(fields["start_usec"])) / 1e6
    rate = cpu_seconds / elapsed
    limits_ok = (fields["cpu_max"] == f"{quota} 100000" and fields["memory_max"] == str(1 << 30)
                 and fields["pids_max"] == "512")
    if scheduler == "fair":
        policy_ok = fields["state"] in ("unavailable", "disabled") and "1" not in tasks
    else:
        policy_ok = fields["state"] == "enabled" and fields["ops"] == scheduler and tasks == ["1", "1"]
    # Saturation on each side of the half-CPU test distinguishes throttling from an idle/contended VM.
    rate_ok = rate >= 1.25 if quota == 200000 else 0.40 <= rate <= 0.60
    return {**fields, "task_sched_ext": tasks, "cpu_seconds_per_second": rate,
            "pass": elapsed >= 4.9 and limits_ok and policy_ok and rate_ok}


def sibling_layout(endpoint, image):
    docker = ["docker", "--host", endpoint]
    paths = []
    with ExitStack() as cleanup:
        for _ in range(2):
            name = "mp-quota-" + uuid.uuid4().hex
            cleanup.callback(subprocess.run, docker + ["rm", "-fv", name], stdout=subprocess.DEVNULL, check=True, timeout=30)
            container = subprocess.check_output(docker + [
                "run", "--name", name, "--pull=never", "--network", "none", "-d", image, "sleep", "90",
            ], text=True, timeout=45).strip()
            data = subprocess.check_output([
                "curl", "-fsS", "--max-time", "10", "--unix-socket", endpoint.removeprefix("unix://"),
                f"http://localhost/v1.47/containers/{container}/stats?stream=false&micropod-cgroup=1",
            ], text=True)
            paths.append(json.loads(data).get("micropod_cgroup"))
    valid = all(isinstance(p, str) and PurePosixPath(p).is_absolute() for p in paths)
    parents = {str(PurePosixPath(p).parent) for p in paths} if valid else set()
    flat = valid and paths[0] != paths[1] and len(parents) == 1
    return {"paths": paths, "common_parent": next(iter(parents)) if flat else None, "pass": bool(flat)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("endpoint", help="explicit local Docker endpoint")
    parser.add_argument("scheduler", help="fair, or the exact sched_ext ops name")
    parser.add_argument("--image", default="alpine:3.23", help="preloaded image with BusyBox")
    args = parser.parse_args()
    if not args.endpoint.startswith("unix:///"):
        parser.error("expected a local worker socket")
    results = []
    report = {"scheduler": args.scheduler, "pass": False, "rounds": results}
    try:
        report["cgroup_layout"] = sibling_layout(args.endpoint, args.image)
        for cpus, quota in (("2", 200000), ("0.5", 50000), ("2", 200000)):
            output = subprocess.check_output([
                "docker", "--host", args.endpoint, "run", "--rm", "--pull=never", "--network", "none",
                "--cpus", cpus, "--memory", "1g", "--pids-limit", "512", "--entrypoint", "sh", args.image, "-ec", PROBE,
            ], text=True, timeout=90)
            results.append(check(output, quota, args.scheduler))
        stable = len({(r["state"], r["ops"], r["sequence"]) for r in results}) == 1
        report["pass"] = report["cgroup_layout"]["pass"] and stable and all(r["pass"] for r in results)
    except (subprocess.SubprocessError, OSError, ValueError, KeyError) as error:
        report["error"] = str(error)
    print(json.dumps(report, indent=2))
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
