#!/bin/bash
# scripts/gates/scale.sh — many containers at once on one hvf machine, a
# GitHub Actions runner's container job through its Docker socket, and the
# capacity report a scheduler admits work by: a repeatable measurement on a
# throwaway machine, with a receipt.
#
#   scripts/gates/scale.sh [--payload DIR] [--engine-from-tree] [--workloads LIST]
#                          [--cpus N] [--memory-mib N] [--no-runner-job]
#                          [--receipt-dir DIR] [--keep] [--help]
#
# The machine runs as a shared-engine rig does: default trust untrusted,
# `dockerSocket: any`, `defaultLimits: none`, OS disk flush fsync.
#
# W  workloads through the docker CLI (scripts/gates/scale/driver.py), by
#    default: 32 and 64 `docker run --rm` at once; 16 per-job networks with a
#    container, an exec and a removal each; 200 containers alive at once;
#    16 `docker build` at once; a compose project of 20 services with health
#    checks; 500 short runs over 16 streams. For each: wall time, p50/p95 and
#    max per client, starts per second, the CPU the engine, containerd,
#    BuildKit and the shims used, their memory and descriptors, the guest's
#    busy share, the engine's own phases (pod, create, start), record writes
#    and the API's mean time per route.
# G  a GitHub Actions runner's container job, command for command, inside an
#    untrusted runner container on its delegated socket
#    (scripts/gates/scale/runner-job.sh): the job and service containers, a
#    step that uses the socket (run, build with cache, compose, health,
#    wait, the Testcontainers reaper), its family counted under its name,
#    and everything gone once the runner container is removed.
# C  the capacity report: `micropod machine capacity --json` answers with
#    the machine's CPUs and PSI, counts 8 containers started with
#    X-Micropod-Family under that family, POST /micropod/families/prune
#    removes exactly them, and the guest route's latency over 500 requests
#    (p50/p95, a metric).
#
# Every number is a metric (metrics.tsv). The hard checks are: no client
# failed, nothing of a workload is left, the runner job's commands worked,
# the capacity report is what the machine holds, and no container, network
# or volume of this run is left at the end.
#
# --payload           a payload directory (micropod-vmm, Image,
#                     mp-hvf-init.cpio, tools/); default: the rig's
#                     known-good payload, cloned (read only)
# --engine-from-tree  put this checkout's engine in the cloned payload: build
#                     guest/runner for linux/arm64 and copy ci/runner's
#                     start.sh and configuration over the payload's
# --workloads         comma-separated, of runN aliveN buildN composeN churnN
#                     netN seqN goN gobuildN fsN (driver.py; goN and gobuildN
#                     pull GATE_GO_IMAGE, golang:1.25-alpine)
# Environment: GATE_ROOT (/tmp/mpg-sc, a throwaway directory under /tmp),
# GATE_MICROPOD (.build/debug/micropod), GATE_DISK_FROM
# (~/.micropod/ci/worker.ext4), GATE_DOCKER, GATE_API_PORT (19350),
# GATE_SHIM_PORT (19351), GATE_IMAGE (alpine:3.20), GATE_CACHE_DISK (8g).
#
# Receipt: ~/.micropod/gates/scale/<UTC time>/ (result.json, checks.tsv,
# metrics.tsv, versions.txt, logs/, evidence/).
#
# Safety: one throwaway machine under GATE_ROOT with
# MICROPOD_LINK_DOCKER_SOCK=0 and its own MICROPOD_API_SOCK, API and shim
# ports; it is stopped and the root removed at exit. The rig (~/.micropod/hvf,
# ~/.micropod/docker.sock, ~/.micropod/api.sock, port 45454) is never started,
# stopped, repointed or written.
#
# Exit status: 0 every check passed, 1 a check failed, 2 the gate could not run.
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/scale"
REPO="$(cd "$HERE/../.." && pwd)"
PAYLOAD_SRC=""
FROM_TREE=0
WORKLOADS="run32,run64,net16,alive200,build16,compose20,churn500"
CPUS=16
MEM=32768
RUNNER_JOB=1
KEEP=0
TS="$(date -u +%Y%m%dT%H%M%SZ)"
R="$HOME/.micropod/gates/scale/$TS"

usage() { sed -n '2,/^set -o pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
while [ "$#" -gt 0 ]; do
    case $1 in
    --payload) PAYLOAD_SRC=$2 && shift ;;
    --engine-from-tree) FROM_TREE=1 ;;
    --workloads) WORKLOADS=$2 && shift ;;
    --cpus) CPUS=$2 && shift ;;
    --memory-mib) MEM=$2 && shift ;;
    --no-runner-job) RUNNER_JOB=0 ;;
    --receipt-dir) R=$2 && shift ;;
    --keep) KEEP=1 ;;
    -h | --help) usage && exit 0 ;;
    *) echo "unknown argument $1 (see --help)" >&2 && exit 2 ;;
    esac
    shift
done
case "$WORKLOADS" in '' | *[!a-z0-9,]*) echo "--workloads must be names like run32,alive200 separated by commas" >&2 && exit 2 ;; esac
case "$CPUS$MEM" in *[!0-9]*) echo "--cpus and --memory-mib must be numbers" >&2 && exit 2 ;; esac

BASE="${GATE_ROOT:-/tmp/mpg-sc}"
case "$BASE" in
*/ | *//* | */./* | */. | */../* | */..) echo "GATE_ROOT must be a plain directory under /tmp" >&2 && exit 2 ;;
/tmp/?* | /private/tmp/?*) ;;
*) echo "GATE_ROOT must be a throwaway directory under /tmp (got '$BASE')" >&2 && exit 2 ;;
esac
MARKER=.micropod-gate-scale
if [ -e "$BASE" ] && [ ! -f "$BASE/$MARKER" ] && [ -n "$(ls -A "$BASE" 2>/dev/null)" ]; then
    echo "$BASE exists and was not made by this harness (no $MARKER)" >&2
    exit 2
fi
MROOT="$BASE/m"
WS="$BASE/ws"
STAGE="$BASE/stage"
TMPD="$BASE/tmp"
SOCK="$MROOT/run/docker.sock"
M="${GATE_MICROPOD:-$REPO/.build/debug/micropod}"
DISK_FROM="${GATE_DISK_FROM:-$HOME/.micropod/ci/worker.ext4}"
if [ -n "${GATE_DOCKER:-}" ]; then DOCKER=$GATE_DOCKER; elif [ -x /opt/homebrew/bin/docker ]; then DOCKER=/opt/homebrew/bin/docker; else DOCKER="$(command -v docker)"; fi
IMAGE="${GATE_IMAGE:-alpine:3.20}"
RUN="sc$(date +%s)"

if [ -z "$PAYLOAD_SRC" ]; then
    KG="$HOME/.micropod/hvf/known-good"
    [ -L "$KG" ] && PAYLOAD_SRC="$HOME/.micropod/hvf/$(readlink "$KG")"
fi
for need in "$M" "$DOCKER"; do [ -x "$need" ] || { echo "missing executable $need" >&2 && exit 2; }; done
for need in micropod-vmm Image mp-hvf-init.cpio tools/runner/start.sh; do
    [ -f "$PAYLOAD_SRC/$need" ] || { echo "payload '$PAYLOAD_SRC' lacks $need (pass --payload)" >&2 && exit 2; }
done
[ -f "$DISK_FROM" ] || { echo "missing OS disk image $DISK_FROM" >&2 && exit 2; }

mkdir -p "$R/logs" "$R/evidence" || exit 2
R="$(cd "$R" && pwd)"
: >"$R/checks.tsv"
: >"$R/metrics.tsv"
exec > >(tee -a "$R/logs/harness.log") 2>&1
log() { printf '%s scale: %s\n' "$(date +%H:%M:%S)" "$*"; }

export MICROPOD_HVF_ROOT="$MROOT"
export MICROPOD_RUNTIMES_CONFIG="$TMPD/runtimes.json"
export MICROPOD_CLI="$M"
export MICROPOD_DOCKER_SOCK="$MROOT/canonical-docker.sock"
export MICROPOD_LINK_DOCKER_SOCK=0
export MICROPOD_API_SOCK="$BASE/api.sock"
export MICROPOD_API_PORT="${GATE_API_PORT:-19350}"
export MICROPOD_SHIM_TCP_PORT="${GATE_SHIM_PORT:-19351}"
export MICROPOD_CI_HOME="$BASE/ci"
export MICROPOD_HVF_AUTOSTART=0
export MICROPOD_NO_UPDATE_NOTIFIER=1
export PYTHONDONTWRITEBYTECODE=1
unset MICROPOD_DEFAULT_RUNTIME DOCKER_CONTEXT BUILDX_BUILDER DOCKER_BUILDKIT
export DOCKER_HOST="unix://$SOCK"
export DOCKER_CONFIG="$TMPD/docker"
RIG_LINK_BEFORE="$(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo absent)"

remove_tree() { [ ! -e "$1" ] || { chmod -R u+w "$1" 2>/dev/null; rm -rf "$1"; }; }
N=0
check() { # section label got want
    N=$((N + 1))
    local status=pass
    [ "$3" == "$4" ] || status=fail
    printf '%s-%02d\t%s\t%s\t%s\t%s\t%s\t\n' "$1" "$N" "$1" "$status" "$2" "$(printf '%s' "$3" | tr '\t\n' '  ' | cut -c1-600)" "$4" >>"$R/checks.tsv"
    if [ "$status" == pass ]; then echo "  ok   $1: $2"; else echo "  FAIL $1: $2 (got '$(printf '%s' "$3" | head -c 400)', want '$4')"; fi
}
ABORTED=""
write_result() {
    python3 - "$R" "$TS" "$BASE" "$ABORTED" "$WORKLOADS" "$CPUS" "$MEM" <<'PY'
import datetime, json, os, sys
r, ts, base, aborted, workloads, cpus, mem = sys.argv[1:]
checks = []
for line in open(os.path.join(r, "checks.tsv")):
    f = line.rstrip("\n").split("\t")
    if len(f) >= 6:
        checks.append({"id": f[0], "section": f[1], "status": f[2], "label": f[3], "got": f[4], "want": f[5], "evidence": f[6] if len(f) > 6 else ""})
metrics = {}
for line in open(os.path.join(r, "metrics.tsv")):
    f = line.rstrip("\n").split("\t")
    if len(f) >= 3:
        try:
            value = float(f[2]) if "." in f[2] else int(f[2])
        except ValueError:
            value = f[2]
        metrics.setdefault(f[0], {})[f[1]] = value
versions = {}
path = os.path.join(r, "versions.txt")
for line in open(path) if os.path.exists(path) else []:
    k, _, v = line.rstrip("\n").partition("=")
    versions[k] = v
bad = [c for c in checks if c["status"] != "pass"]
verdict = "error" if aborted else ("fail" if bad or not checks else "pass")
json.dump({"gate": "scale: many containers at once, a GitHub Actions runner's container job, and the capacity report",
           "receipt": r, "started": datetime.datetime.strptime(ts, "%Y%m%dT%H%M%SZ").replace(tzinfo=datetime.timezone.utc).isoformat(),
           "finished": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
           "machine": {"cpus": int(cpus), "memoryMiB": int(mem)}, "workloads": workloads.split(","),
           "throwawayRoot": base, "aborted": aborted or None, "versions": versions,
           "summary": {"checks": len(checks), "passed": len(checks) - len(bad), "failed": len(bad)},
           "verdict": verdict, "failed": [c["id"] + " " + c["label"] for c in bad], "metrics": metrics, "checks": checks},
          open(os.path.join(r, "result.json"), "w"), indent=2)
print("result: %s — %d passed, %d failed of %d checks%s" % (verdict, len(checks) - len(bad), len(bad), len(checks), " (aborted: %s)" % aborted if aborted else ""))
for c in bad:
    print("  failed:", c["id"], c["label"])
print("  %-11s %8s %8s %8s %8s %9s" % ("workload", "clients", "wall s", "p50 s", "p95 s", "per s"))
for name, m in metrics.items():
    if "clients" in m:
        print("  %-11s %8s %8.2f %8.3f %8.3f %9.1f" % (name, m["clients"], m.get("wall_s", 0), m.get("p50_s", 0), m.get("p95_s", 0), m.get("per_second", 0)))
PY
}
cleanup() {
    local rc=$?
    set +e
    [ -n "$ABORTED" ] || [ "$rc" -le 1 ] || ABORTED="interrupted (exit $rc)"
    if [ -f "$MROOT/machine.json" ]; then
        "$M" machine logs -n 400 >"$R/logs/console-tail.log" 2>&1
        for f in supervisor.log; do [ -f "$MROOT/logs/$f" ] && tail -c 1000000 "$MROOT/logs/$f" >"$R/logs/$f"; done
        "$M" machine stop >"$R/logs/final-stop.log" 2>&1
    fi
    write_result
    log "rig link ~/.micropod/docker.sock -> $(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo absent) (before: $RIG_LINK_BEFORE)"
    if [ "$KEEP" != 1 ] && [ -f "$BASE/$MARKER" ]; then remove_tree "$BASE"; fi
    log "receipt: $R/result.json"
    if [ -n "$ABORTED" ]; then exit 2; fi
    if python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['verdict'] == 'pass' else 1)" "$R/result.json"; then exit 0; fi
    exit 1
}
trap cleanup EXIT
trap 'exit 130' INT TERM
abort() { ABORTED=$1 && log "ABORT: $1" && exit 2; }

log "receipt $R"
log "throwaway root $BASE; $CPUS CPUs, $MEM MiB; workloads $WORKLOADS; payload $PAYLOAD_SRC"
"$M" machine stop >/dev/null 2>&1
remove_tree "$BASE"
{ mkdir -p "$BASE" "$MROOT" "$WS" "$STAGE" "$TMPD/docker" && touch "$BASE/$MARKER"; } || abort "cannot create $BASE"
# The user's CLI plugin directory, so `docker build` (buildx) and `docker
# compose` load; nothing else of the user's docker config is read.
python3 -c 'import json,os,sys; json.dump({"cliPluginsExtraDirs": [os.path.expanduser("~/.docker/cli-plugins")]}, open(sys.argv[1], "w"))' "$DOCKER_CONFIG/config.json"
cp -cR "$PAYLOAD_SRC/." "$STAGE/payload/" 2>/dev/null || cp -R "$PAYLOAD_SRC/." "$STAGE/payload/"
chmod -R u+w "$STAGE/payload"
if [ "$FROM_TREE" == 1 ]; then
    runner="$STAGE/payload/tools/runner"
    install -m 0644 "$REPO"/ci/runner/*.toml "$REPO"/ci/runner/*.conflist "$runner/" || abort "cannot copy ci/runner's configuration"
    install -m 0755 "$REPO/ci/runner/start.sh" "$REPO/ci/runner/published-ports.sh" "$REPO/ci/runner/rootless.sh" "$runner/" || abort "cannot copy ci/runner's scripts"
    install -m 0755 "$REPO/ci/runner/micropod-bridge" "$runner/cni/" || abort "cannot copy ci/runner's CNI plugin"
    (cd "$REPO/guest/runner" && env -u GOROOT GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
        -ldflags "-X main.engineCommit=$(git -C "$REPO" rev-parse HEAD)" -o "$runner/bin/job" .) >"$R/logs/engine-build.log" 2>&1 ||
        { tail -20 "$R/logs/engine-build.log"; abort "the engine did not build"; }
fi
{
    echo "harness_rev=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
    echo "harness_dirty=$(git -C "$REPO" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    echo "payload_src=$PAYLOAD_SRC"
    echo "engine_from_tree=$FROM_TREE"
    for f in micropod-vmm Image mp-hvf-init.cpio tools/runner/start.sh tools/runner/bin/job; do
        echo "payload_sha256.$f=$(shasum -a 256 "$STAGE/payload/$f" 2>/dev/null | cut -d' ' -f1)"
    done
    echo "cpus=$CPUS"
    echo "memory_mib=$MEM"
    echo "workloads=$WORKLOADS"
    echo "docker_cli=$("$DOCKER" --version 2>/dev/null)"
    echo "host=$(sysctl -n machdep.cpu.brand_string 2>/dev/null), $(sysctl -n hw.ncpu 2>/dev/null) CPUs, $(($(sysctl -n hw.memsize 2>/dev/null) >> 30)) GiB"
    echo "run=$RUN"
} >"$R/versions.txt"
"$M" machine install --vmm "$STAGE/payload/micropod-vmm" --kernel "$STAGE/payload/Image" --initrd "$STAGE/payload/mp-hvf-init.cpio" \
    --tools "$STAGE/payload/tools" --disk-from "$DISK_FROM" --cache-disk-size "${GATE_CACHE_DISK:-8g}" --cpus "$CPUS" --memory-mib "$MEM" --workspace "$WS" >"$R/logs/install.log" 2>&1 ||
    { cat "$R/logs/install.log"; abort "machine install failed"; }
# As the rig runs: the OS disk's flushes are fsync, the cache disk's ordered.
python3 - "$MROOT/machine.json" <<'PY' || abort "cannot set the disk flush mode"
import json, sys
config = json.load(open(sys.argv[1]))
config["osDiskFlush"] = "fsync"
json.dump(config, open(sys.argv[1], "w"), indent=2)
PY
"$M" machine cache policy --default-trust untrusted --docker-socket any --default-limits none >"$R/logs/policy.log" 2>&1 || { cat "$R/logs/policy.log"; abort "the policy was refused"; }
"$M" machine start --timeout 300 >"$R/logs/machine-start.log" 2>&1 || { tail -20 "$R/logs/machine-start.log"; abort "machine start failed"; }
for _ in $(seq 1 240); do curl -s -m 2 --unix-socket "$SOCK" http://d/_ping 2>/dev/null | grep -q OK && break; sleep 0.5; done
curl -s -m 5 --unix-socket "$SOCK" http://d/version >"$R/evidence/version.json" || abort "the engine never answered"
echo "engine_commit=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('GitCommit'))" "$R/evidence/version.json")" >>"$R/versions.txt"
"$DOCKER" pull -q "$IMAGE" >"$R/logs/pull.log" 2>&1 || abort "cannot pull $IMAGE"
"$M" machine status >"$R/evidence/machine-status.txt" 2>&1
check H "machine status names the shared-engine policy" "$(grep -c 'docker socket for any container' "$R/evidence/machine-status.txt")" 1
check H "machine status names the lifted default limits" "$(grep -c 'no default container limits' "$R/evidence/machine-status.txt")" 1
check H "a container naming no limit has no CPU quota and the machine's memory" \
    "$("$DOCKER" run --rm "$IMAGE" sh -c 'cut -d" " -f1 /sys/fs/cgroup/cpu.max; test "$(cat /sys/fs/cgroup/memory.max)" -gt 2000000000 && echo roomy' 2>&1 | tr '\n' ' ')" "max roomy "
check H "a container gets a Docker daemon's open-file limit" "$("$DOCKER" run --rm "$IMAGE" sh -c 'ulimit -n' 2>&1)" 1048576

# W: the workloads.
GATE_DOCKER_BIN="$DOCKER" GATE_TMP="$TMPD" GATE_WORKSPACE="$WS" python3 -I "$GATE/driver.py" "$SOCK" "$R" "$RUN" "$IMAGE" "$WORKLOADS"
rc=$?
[ "$rc" == 0 ] || abort "the driver could not run the workloads (exit $rc)"

# G: a GitHub Actions runner's container job.
if [ "$RUNNER_JOB" == 1 ]; then
    log "G: a GitHub Actions runner's container job"
    GATE_DOCKER_BIN="$DOCKER" bash "$GATE/runner-job.sh" "$SOCK" "$WS" "$R" "$RUN" || abort "the runner job could not run"
fi

# C: the capacity report.
log "C: the capacity report"
mkdir -p "$TMPD/family"
python3 -c 'import json,os,sys; json.dump({"cliPluginsExtraDirs": [os.path.expanduser("~/.docker/cli-plugins")], "HttpHeaders": {"X-Micropod-Family": sys.argv[2]}}, open(sys.argv[1], "w"))' "$TMPD/family/config.json" "job-$RUN"
for i in 1 2 3 4 5 6 7 8; do DOCKER_CONFIG="$TMPD/family" "$DOCKER" run -d --name "cap-$RUN-$i" --cpus 0.5 -m 256m "$IMAGE" sleep 600 >/dev/null 2>&1; done
DOCKER_CONFIG="$TMPD/family" "$DOCKER" network create "cap-net-$RUN" >/dev/null 2>&1
DOCKER_CONFIG="$TMPD/family" "$DOCKER" volume create "cap-vol-$RUN" >/dev/null 2>&1
"$DOCKER" run -d --name "cap-other-$RUN" "$IMAGE" sleep 600 >/dev/null 2>&1
"$M" machine capacity --json >"$R/evidence/capacity.json" 2>"$R/logs/capacity.err"
check C "machine capacity answers" "$?" 0
"$M" machine capacity >"$R/evidence/capacity.txt" 2>&1
python3 - "$R/evidence/capacity.json" "job-$RUN" "$CPUS" >"$R/evidence/capacity-facts.txt" 2>&1 <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
family = [f for f in d["containers"].get("families", []) if f.get("name") == sys.argv[2]]
print("cpus", d.get("cpus") == int(sys.argv[3]))
print("psi", d["pressure"].get("available") is True)
print("family_running", family[0].get("running") if family else "absent")
print("family_milli_cpu", family[0].get("requestedMilliCpu") if family else "absent")
print("running", d["containers"].get("running"))
print("headroom", d["headroom"].get("containers", 0) > 0 and not d["headroom"].get("underPressure", False))
print("host", bool(d["host"].get("memoryBytes")))
PY
fact() { awk -v k="$1" '$1 == k { print $2 }' "$R/evidence/capacity-facts.txt"; }
check C "it reports the machine's CPUs" "$(fact cpus)" True
check C "the guest kernel reports pressure (PSI)" "$(fact psi)" True
check C "the family's 8 containers are counted under the X-Micropod-Family name" "$(fact family_running)" 8
check C "with their CPU limits summed" "$(fact family_milli_cpu)" 4000
check C "an idle machine has headroom and is not under pressure" "$(fact headroom)" True
check C "the Mac's memory is reported" "$(fact host)" True
curl -s -m 60 --unix-socket "$SOCK" -X POST "http://d/micropod/families/prune?family=job-$RUN&dry-run=1" >"$R/evidence/prune-dry.json"
check C "a dry-run prune lists the family and removes nothing" \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["containers"]), len(d["networks"]), len(d["volumes"]))' "$R/evidence/prune-dry.json") $("$DOCKER" ps -q --filter "name=cap-$RUN-" | wc -l | tr -d ' ')" "8 1 1 8"
curl -s -m 120 --unix-socket "$SOCK" -X POST "http://d/micropod/families/prune?family=job-$RUN" >"$R/evidence/prune.json"
check C "the prune removes the family's containers, network and volume" \
    "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["containers"]), len(d["networks"]), len(d["volumes"]), len(d["errors"]), d["remaining"])' "$R/evidence/prune.json")" "8 1 1 0 False"
check C "and nothing else" "$("$DOCKER" ps -aq --filter "name=cap-" | wc -l | tr -d ' ') $("$DOCKER" inspect -f '{{.State.Running}}' "cap-other-$RUN" 2>&1)" "1 true"
"$DOCKER" rm -f "cap-other-$RUN" >/dev/null 2>&1
python3 -I - "$SOCK" "$R" <<'PY'
import http.client, socket, sys, time
sock, receipt = sys.argv[1:]
class Unix(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(sock)
samples = []
for i in range(520):
    c = Unix("d", timeout=10)
    begin = time.perf_counter()
    c.request("GET", "/micropod/capacity")
    r = c.getresponse()
    r.read()
    took = time.perf_counter() - begin
    c.close()
    if r.status != 200:
        sys.exit("capacity: HTTP %d" % r.status)
    if i >= 20:
        samples.append(took * 1e6)
samples.sort()
with open(receipt + "/metrics.tsv", "a") as f:
    for name, value in (("guest_route_p50_us", samples[len(samples) // 2]), ("guest_route_p95_us", samples[int(len(samples) * 0.95)]),
                        ("guest_route_max_us", samples[-1]), ("samples", len(samples))):
        f.write("capacity\t%s\t%s\t%s\n" % (name, ("%.1f" % value) if isinstance(value, float) else value, "us" if name != "samples" else ""))
print("   GET /micropod/capacity over the machine's socket, a connection each: p50 %.0f µs, p95 %.0f µs" % (samples[len(samples) // 2], samples[int(len(samples) * 0.95)]))
PY
check C "500 capacity requests in a row all answered" "$?" 0

# S: nothing is left, and the rig was not touched.
left="$("$DOCKER" ps -aq | wc -l | tr -d ' ') $("$DOCKER" network ls -q --filter type=custom | wc -l | tr -d ' ') $("$DOCKER" volume ls -q | wc -l | tr -d ' ')"
check S "no container, network or volume is left on the machine" "$left" "0 0 0"
link=$(readlink "$HOME/.micropod/docker.sock" 2>/dev/null || echo absent)
case "$link" in "$BASE"* | "$MROOT"*) touched=yes ;; *) touched=no ;; esac
check S "$HOME/.micropod/docker.sock is not pointed at the throwaway machine" "$touched" no
