#!/bin/bash
# scripts/gates/scale/runner-job.sh — a GitHub Actions runner's container job
# against a machine's Docker socket, command for command.
#
#   runner-job.sh SOCKET WORKSPACE RECEIPT [RUN]
#
# A GitHub Actions runner that runs in a container on the machine (a Linux
# self-hosted runner) binds /var/run/docker.sock and drives `container:` jobs
# and `services:` through it with the docker CLI. This starts such a runner
# container (image docker:28-cli, unlabelled, so untrusted on a machine whose
# default is untrusted) on SOCKET and runs inside it the commands
# actions/runner's DockerCommandManager and ContainerOperationProvider issue
# for one job, in their order and with their flags:
#   docker version; ps --filter label=<instance> and network prune (the
#   leftovers of an earlier job); network create --label; pull; create of a
#   service (--network-alias, -p, --health-*, -e) and of the job container
#   (--workdir, the runner's binds, the Docker socket, --entrypoint tail);
#   start; ps --filter id= --filter status=running; inspect of the env; the
#   service's health status and `docker port`; a step as
#   `docker exec -i --workdir … -e NAME` with the script on a bind; logs
#   --details; rm --force; network rm.
# The step itself uses the socket the job container was given, as workflow
# steps do: docker run, docker build with the default builder (cache-to and
# cache-from type=local, and inline), docker compose up/ps/down, a container
# with a health check and `docker wait`, and the Testcontainers reaper.
# Then, from the machine's own socket: the runner's family is counted under
# its name in GET /micropod/capacity, sees nothing of another job, and is
# gone, containers, networks and volumes, once the runner container is
# removed (a runner that died mid-job leaves nothing).
#
# WORKSPACE is a directory inside the machine's workspace share: the runner's
# work directory and its externals live there, at the same path inside the
# runner container, because a job container's binds are paths on the machine,
# as they are with any Docker daemon a runner container shares.
#
# The machine needs `dockerSocket: any` (the runner is untrusted and its job
# container shares the runner's socket). Appends numbered checks to
# RECEIPT/checks.tsv (section G). Exit 0 when it ran, 2 when it could not.
set -u
SOCK=${1:?socket}
WS=${2:?workspace directory}
R=${3:?receipt directory}
RUN=${4:-rj$$}
DOCKER=${GATE_DOCKER_BIN:-docker}
export DOCKER_HOST="unix://$SOCK"
N=0
check() {
    N=$((N + 1))
    local status=pass
    [ "$2" == "$3" ] || status=fail
    printf 'G-%02d\tG\t%s\t%s\t%s\t%s\t\n' "$N" "$status" "$1" "$(printf '%s' "$2" | tr '\t\n' '  ' | cut -c1-600)" "$3" >>"$R/checks.tsv"
    if [ "$status" == pass ]; then echo "  ok   G: $1"; else echo "  FAIL G: $1 (got '$(printf '%s' "$2" | head -c 400)', want '$3')"; fi
}
RUNNER="gha-runner-$RUN"
# As the machine names it: its workspace share is the directory's real path
# (/private/tmp for /tmp), and a bind source is a path on the machine.
WS=$(cd "$WS" 2>/dev/null && pwd -P) || { echo "no workspace directory $2" >&2; exit 2; }
W="$WS/$RUNNER"
OTHER="other-job-$RUN"
cleanup() {
    "$DOCKER" rm -f "$RUNNER" "$OTHER" >/dev/null 2>&1
    rm -rf "$W"
}
trap cleanup EXIT
"$DOCKER" version --format '{{.Server.APIVersion}}' >/dev/null 2>&1 || { echo "the engine at $SOCK does not answer" >&2; exit 2; }
mkdir -p "$W/_work/repo/repo" "$W/_work/_temp/_github_home" "$W/_work/_temp/_github_workflow" "$W/_work/_actions" "$W/_work/_tool" "$W/externals" "$W/out" || exit 2
echo node-would-be-here >"$W/externals/marker"

# The step a workflow would run inside the job container.
cat >"$W/_work/_temp/step.sh" <<'STEP'
set -e
echo "env:$STEP_VAR:$GITHUB_ACTIONS:$HOME"
echo "pwd:$(pwd)"
read -r line && echo "stdin:$line"
echo "externals:$(cat /__e/marker)"
( echo PING; sleep 1 ) | nc redis 6379 | head -1 | tr -d '\r' | sed 's/^/service:/'
echo written-by-step > /__w/repo/repo/artifact.txt
echo "socket:$(docker version --format '{{.Server.Version}}')"
echo "run:$(docker run --rm --label step=1 alpine:3.20 echo from-step)"
echo "family:$(docker ps -q | wc -l | tr -d ' ')"
mkdir -p /__w/_temp/img && cd /__w/_temp/img
printf 'FROM alpine:3.20\nRUN --mount=type=cache,target=/c echo built > /built && date > /c/stamp\n' > Dockerfile
docker build -q -t "$RUN_TAG:1" --cache-to type=local,dest=/__w/_temp/bcache --cache-from type=local,src=/__w/_temp/bcache . >/dev/null
docker build -q -t "$RUN_TAG:2" --cache-to type=inline . >/dev/null
echo "build:$(docker run --rm "$RUN_TAG:1" cat /built):$(test -f /__w/_temp/bcache/index.json && echo local-cache)"
docker buildx ls >/dev/null && echo "buildx:ok"
mkdir -p /__w/_temp/c && cd /__w/_temp/c
printf 'services:\n  web:\n    image: alpine:3.20\n    command: ["sleep", "300"]\n    healthcheck: {test: ["CMD", "true"], interval: 1s, timeout: 2s, retries: 5}\n  worker:\n    image: alpine:3.20\n    command: ["sleep", "300"]\n    depends_on: {web: {condition: service_healthy}}\n    volumes: ["data:/data"]\nvolumes:\n  data: {}\n' > compose.yaml
docker compose -p "c$RUN_TAG" up -d --wait >/dev/null 2>&1
echo "compose:$(docker compose -p "c$RUN_TAG" ps -q | wc -l | tr -d ' ')"
docker compose -p "c$RUN_TAG" down -v -t 1 >/dev/null 2>&1
echo "compose-down:$(docker ps -aq --filter "label=com.docker.compose.project=c$RUN_TAG" | wc -l | tr -d ' ')"
id=$(docker run -d --health-cmd true --health-interval 1s alpine:3.20 sh -c 'sleep 3; exit 7')
for _ in 1 2 3 4 5 6; do [ "$(docker inspect -f '{{.State.Health.Status}}' "$id")" = healthy ] && break; sleep 0.5; done
echo "health:$(docker inspect -f '{{.State.Health.Status}}' "$id")"
echo "wait:$(docker wait "$id")"
docker rm "$id" >/dev/null
# Left running on purpose: the runner's death must take them.
docker network create "leak-net-$RUN_TAG" >/dev/null
docker volume create "leak-vol-$RUN_TAG" >/dev/null
docker run -d --name "leak-$RUN_TAG" --network "leak-net-$RUN_TAG" -v "leak-vol-$RUN_TAG:/v" alpine:3.20 sleep 600 >/dev/null
docker run -d --rm --name "ryuk-$RUN_TAG" -l org.testcontainers.ryuk=true -l org.testcontainers.reaper=true -l "org.testcontainers.sessionId=$RUN_TAG" \
    -v /var/run/docker.sock:/var/run/docker.sock -e RYUK_RECONNECTION_TIMEOUT=3s testcontainers/ryuk:0.11.0 >/dev/null && echo "ryuk:started"
STEP

# What actions/runner does for the job, inside the runner container.
cat >"$W/job.sh" <<'JOB'
set -u
W=$1; RUN=$2
INST="runner-instance-$RUN"
NET="github_network_$RUN"
out() { printf '%s\t%s\n' "$1" "$2" >>"$W/out/results.tsv"; }
out server_api "$(docker version --format '{{.Server.APIVersion}}' 2>&1)"
out client_api "$(docker version --format '{{.Client.APIVersion}}' 2>&1)"
out leftovers "$(docker ps --all --quiet --no-trunc --filter "label=$INST" 2>&1 | wc -l | tr -d ' ')"
docker network create --label "$INST" "stale_network_$RUN" >/dev/null 2>&1
docker network create "kept_network_$RUN" >/dev/null 2>&1
out network_prune "$(docker network prune --force --filter "label=$INST" >/dev/null 2>&1; echo "$? $(docker network ls -q --filter "name=stale_network_$RUN" | wc -l | tr -d ' ') $(docker network ls -q --filter "name=kept_network_$RUN" | wc -l | tr -d ' ')")"
docker network rm "kept_network_$RUN" >/dev/null 2>&1
out network_create "$(docker network create --label "$INST" "$NET" >/dev/null 2>&1; echo $?)"
out pull "$(docker pull redis:7-alpine >/dev/null 2>&1 && docker pull docker:28-cli >/dev/null 2>&1; echo $?)"
SVC=$(docker create --name "svc-$RUN" --label "$INST" --network "$NET" --network-alias redis -p 6379 \
    --health-cmd "redis-cli ping" --health-interval 1s --health-timeout 3s --health-retries 10 -e "SERVICE_VAR=one" redis:7-alpine 2>&1)
out service_create "$?"
out service_start "$(docker start "$SVC" >/dev/null 2>&1; echo $?)"
out service_running "$(docker ps --all --filter "id=$SVC" --filter status=running --no-trunc --format '{{.ID}} {{.Status}}' 2>&1 | grep -c "^$SVC ")"
JOBC=$(docker create --name "job-$RUN" --label "$INST" --workdir /__w/repo/repo --network "$NET" \
    -e "HOME=/github/home" -e GITHUB_ACTIONS=true -e CI=true \
    -v "/var/run/docker.sock":"/var/run/docker.sock" -v "$W/_work":"/__w" -v "$W/externals":"/__e":ro \
    -v "$W/_work/_temp":"/__w/_temp" -v "$W/_work/_actions":"/__w/_actions" -v "$W/_work/_tool":"/__w/_tool" \
    -v "$W/_work/_temp/_github_home":"/github/home" -v "$W/_work/_temp/_github_workflow":"/github/workflow" \
    --entrypoint "tail" docker:28-cli "-f" "/dev/null" 2>&1)
out job_create "$? $(printf '%s' "$JOBC" | tail -c 200)"
out job_start "$(docker start "$JOBC" >/dev/null 2>&1; echo $?)"
out job_running "$(docker ps --all --filter "id=$JOBC" --filter status=running --no-trunc --format '{{.ID}} {{.Status}}' 2>&1 | grep -c "^$JOBC ")"
out job_env "$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$JOBC" 2>&1 | grep -c -E '^(HOME=/github/home|GITHUB_ACTIONS=true|CI=true|PATH=.+)$')"
health=
for _ in $(seq 1 40); do
    health=$(docker inspect --format='{{if .Config.Healthcheck}}{{print .State.Health.Status}}{{end}}' "$SVC" 2>&1)
    [ "$health" = healthy ] && break
    sleep 0.5
done
out service_health "$health"
out service_port "$(docker port "$SVC" 2>&1 | grep -c '^6379/tcp -> ')"
out label_filter "$(docker ps --filter "label=$INST" --filter "network=$NET" -q 2>&1 | wc -l | tr -d ' ')"
export STEP_VAR=from-the-runner RUN_TAG="t$RUN"
echo piped-in | docker exec -i --workdir /__w/repo/repo -e STEP_VAR -e RUN_TAG "$JOBC" sh -e /__w/_temp/step.sh >"$W/out/step.log" 2>&1
out step_exit "$?"
out exec_exit_code "$(docker exec "$JOBC" sh -c 'exit 3' >/dev/null 2>&1; echo $?)"
out service_logs "$(docker logs --details "$SVC" 2>&1 | grep -c 'Ready to accept connections')"
out rm "$(docker rm --force "$JOBC" >/dev/null 2>&1 && docker rm --force "$SVC" >/dev/null 2>&1; echo $?)"
out network_rm "$(docker network rm "$NET" >/dev/null 2>&1; echo $?)"
JOB

"$DOCKER" pull -q docker:28-cli >/dev/null 2>&1 || { echo "cannot pull docker:28-cli" >&2; exit 2; }
"$DOCKER" pull -q alpine:3.20 >/dev/null 2>&1
"$DOCKER" pull -q testcontainers/ryuk:0.11.0 >/dev/null 2>&1
# Another job's container, which the runner must never see.
"$DOCKER" run -d --name "$OTHER" alpine:3.20 sleep 600 >/dev/null 2>&1
started=$("$DOCKER" run -d --name "$RUNNER" -v /var/run/docker.sock:/var/run/docker.sock -v "$W:$W" docker:28-cli sleep 3600 2>&1)
printf '%s\n' "$started" >"$R/logs/runner-start-$RUN.log"
check "an unlabelled runner container is given a Docker socket (dockerSocket: any)" "$(printf '%s' "$started" | grep -E '^[0-9a-f]{64}$' | wc -l | tr -d ' ') $(printf '%s' "$started" | grep -v -E '^[0-9a-f]{64}$' | tail -1)" "1 "
"$DOCKER" exec "$RUNNER" sh "$W/job.sh" "$W" "$RUN" >"$R/logs/runner-job-$RUN.log" 2>&1
cp "$W/out/results.tsv" "$R/evidence/runner-job-$RUN.tsv" 2>/dev/null
cp "$W/out/step.log" "$R/evidence/runner-step-$RUN.log" 2>/dev/null
got() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$W/out/results.tsv" 2>/dev/null | tail -1; }
step() { grep -m1 "^$1:" "$W/out/step.log" 2>/dev/null | cut -d: -f2-; }
check "docker version reports the server API" "$(got server_api)" "1.47"
check "no leftover of an earlier job (ps --filter label=)" "$(got leftovers)" 0
check "network prune --filter label= removes an earlier job's network and no other" "$(got network_prune)" "0 0 1"
check "network create --label" "$(got network_create)" 0
check "docker pull of the job's images" "$(got pull)" 0
check "service: create with --network-alias, -p, --health-cmd, -e" "$(got service_create)" 0
check "service: start" "$(got service_start)" 0
check "service: ps --filter id= --filter status=running" "$(got service_running)" 1
check "job container: create with the runner's binds, the Docker socket and --entrypoint tail" "$(got job_create | cut -d' ' -f1)" 0
check "job container: start" "$(got job_start)" 0
check "job container: running" "$(got job_running)" 1
check "job container: inspect lists its env (HOME, GITHUB_ACTIONS, CI, PATH)" "$(got job_env)" 4
check "service: health status reaches healthy" "$(got service_health)" healthy
check "service: docker port lists the published port" "$(got service_port)" 1
check "ps --filter label= --filter network= finds both containers" "$(got label_filter)" 2
check "step: docker exec -i --workdir -e NAME exits 0" "$(got step_exit)" 0
check "step: env passed by name, and the create's env" "$(step env)" "from-the-runner:true:/github/home"
check "step: runs in --workdir" "$(step pwd)" "/__w/repo/repo"
check "step: reads the runner's stdin" "$(step stdin)" "piped-in"
check "step: the read-only externals bind" "$(step externals)" "node-would-be-here"
check "step: reaches the service by its network alias" "$(step service)" "+PONG"
check "step: its file is in the runner's workspace" "$(cat "$W/_work/repo/repo/artifact.txt" 2>/dev/null)" "written-by-step"
check "step: the job container's own Docker socket answers" "$(step socket)" "micropod"
check "step: docker run through it" "$(step run)" "from-step"
check "step: docker build with the default builder, cache-to/cache-from type=local and inline" "$(step build)" "built:local-cache"
check "step: docker buildx ls" "$(step buildx)" "ok"
check "step: docker compose up --wait with a health dependency and a volume" "$(step compose)" 2
check "step: docker compose down -v leaves none" "$(step compose-down)" 0
check "step: a health check turns healthy" "$(step health)" healthy
check "step: docker wait returns the exit code" "$(step wait)" 7
check "step: the Testcontainers reaper starts with its socket" "$(step ryuk)" started
check "docker exec returns the command's exit code" "$(got exec_exit_code)" 3
check "service: docker logs --details" "$(got service_logs | awk '{ print ($1 >= 1) ? "logged" : "nothing" }')" logged
check "rm --force of the job and service containers" "$(got rm)" 0
check "network rm" "$(got network_rm)" 0

api() { curl -s -m 10 --unix-socket "$SOCK" "$@"; }
family=$(api http://d/micropod/capacity | python3 -c '
import json, sys
name = sys.argv[1]
rows = [f for f in json.load(sys.stdin)["containers"]["families"] if f["name"] == name]
print(rows[0]["running"] if rows else "absent")' "$RUNNER" 2>&1)
# The runner, the step's leftover container and the reaper.
check "the runner's family is counted under its name (GET /micropod/capacity)" "$family" 3
check "the runner's socket shows nothing of another job" "$("$DOCKER" exec "$RUNNER" docker ps -aq --filter "name=$OTHER" 2>&1 | wc -l | tr -d ' ')" 0
before=$("$DOCKER" ps -aq --filter "name=t$RUN" | wc -l | tr -d ' ')
check "the step left a container, a network and a volume behind" "$before $("$DOCKER" network ls -q --filter "name=leak-net-t$RUN" | wc -l | tr -d ' ') $("$DOCKER" volume ls -q --filter "name=leak-vol-t$RUN" | wc -l | tr -d ' ')" "2 1 1"
"$DOCKER" rm -f "$RUNNER" >/dev/null 2>&1
left=
for _ in $(seq 1 60); do
    left="$("$DOCKER" ps -aq --filter "name=t$RUN" | wc -l | tr -d ' ') $("$DOCKER" network ls -q --filter "name=leak-net-t$RUN" | wc -l | tr -d ' ') $("$DOCKER" volume ls -q --filter "name=leak-vol-t$RUN" | wc -l | tr -d ' ')"
    [ "$left" == "0 0 0" ] && break
    sleep 0.5
done
check "removing the runner container removes everything its job made" "$left" "0 0 0"
check "another job's container is untouched" "$("$DOCKER" inspect -f '{{.State.Running}}' "$OTHER" 2>&1)" true
exit 0
