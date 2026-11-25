#!/bin/bash
# scripts/e2e_vmm_machine.sh — micropod-vmm as a long-lived Docker machine.
#
# Boots the Rust HVF VMM directly (no Swift supervisor) on an APFS clone of a
# CI worker disk in a throwaway directory and asserts, through the docker CLI
# on the exposed socket:
#   - the Docker API comes up; guest init configured eth0/eth1 (rtnetlink);
#   - run / exec / logs and their exit codes; DNS, egress and the guest clock;
#   - a published port serves HTTP, under concurrency, for large up- and
#     downloads, and for a container that only starts listening later;
#   - bind mounts from the Mac (--workspace): read, write, :ro, non-root
#     writes and chown semantics;
#   - SIGTERM is an orderly poweroff (exit 0); on the next boot the stopped
#     container and a named volume are intact and ext4 needs no recovery;
#   - kill -9 of the VMM is recovered: the stale socket is replaced and the
#     data is intact (journal replay is allowed);
#   - an unusable --vsock-expose path fails startup (exit 1);
#   - guest init and engine failures exit 4, not 0.
# Only the VMM processes this script starts are signalled, by pid.
#
# Usage: scripts/e2e_vmm_machine.sh       (after vmm/build.sh)
#   VMM          signed micropod-vmm   (default vmm/target/release/micropod-vmm)
#   INITRD       guest initramfs       (default vmm/target/mp-hvf-init.cpio)
#   KERNEL       arm64 Image           (default ~/.micropod/kernels/7.3.5-micropod-7e3713940eec/Image,
#                                       else the newest ~/.micropod/kernels/*/Image)
#   OCI_TOOLS    guest engine share    (default newest micropod-oci-tools build)
#   SOURCE_DISK  ext4 worker disk, only ever APFS-cloned (default ~/.micropod/ci/worker.ext4)
#   PORT_BASE    first of three free loopback ports (default 18240)
#   DOCKER       docker CLI            (default /opt/homebrew/bin/docker or PATH)
#   E2E_KEEP=1   keep the work directory for inspection
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VMM="${VMM:-$ROOT/vmm/target/release/micropod-vmm}"
INITRD="${INITRD:-$ROOT/vmm/target/mp-hvf-init.cpio}"
SOURCE_DISK="${SOURCE_DISK:-$HOME/.micropod/ci/worker.ext4}"
PORT_BASE="${PORT_BASE:-18240}"
# Newest by modification time; these are tool-generated names without spaces.
# shellcheck disable=SC2012
if [ -z "${KERNEL:-}" ]; then
    KERNEL="$HOME/.micropod/kernels/7.3.5-micropod-7e3713940eec/Image"
    [ -f "$KERNEL" ] || KERNEL="$(ls -t "$HOME"/.micropod/kernels/*/Image 2>/dev/null | head -1 || true)"
fi
# shellcheck disable=SC2012
if [ -z "${OCI_TOOLS:-}" ]; then
    OCI_TOOLS="$(ls -td "$HOME"/projects/micropod-warm-ci/.build/ci-runner-*/micropod-oci-tools 2>/dev/null | head -1 || true)"
fi
if [ -z "${DOCKER:-}" ]; then
    if [ -x /opt/homebrew/bin/docker ]; then DOCKER=/opt/homebrew/bin/docker; else DOCKER="$(command -v docker || true)"; fi
fi
for need in "$VMM" "$INITRD" "$KERNEL" "$SOURCE_DISK" "$DOCKER"; do
    [ -e "$need" ] || { echo "missing: ${need:-<unset>} (see the header for overrides)" >&2; exit 2; }
done
[ -f "${OCI_TOOLS:-}/runner/start.sh" ] || { echo "OCI_TOOLS has no runner/start.sh: ${OCI_TOOLS:-<unset>}" >&2; exit 2; }

# A short directory: Unix socket paths are limited to 103 bytes on macOS.
WORK="$(mktemp -d /tmp/mpe2e.XXXXXX)"
SOCK="$WORK/docker.sock"
WS="$WORK/ws"
DISK="$WORK/disk.ext4"
P_WEB=$PORT_BASE
P_SINK=$((PORT_BASE + 1))
P_LATE=$((PORT_BASE + 2))
VM_PID=""
BOOTS=0
FAILED=0
export DOCKER_HOST="unix://$SOCK"
unset DOCKER_CONTEXT

cleanup() {
    if [ -n "$VM_PID" ] && kill -0 "$VM_PID" 2>/dev/null; then
        kill -TERM "$VM_PID" 2>/dev/null || true
        for _ in $(seq 1 150); do kill -0 "$VM_PID" 2>/dev/null || break; sleep 0.1; done
        kill -KILL "$VM_PID" 2>/dev/null || true
    fi
    if [ "${E2E_KEEP:-0}" = 1 ] || [ "$FAILED" = 1 ]; then
        echo "work directory kept: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

log() { printf '\n== %s\n' "$*"; }
pass() { printf '  ok   %s\n' "$*"; }
fail() {
    FAILED=1
    printf '  FAIL %s\n' "$*" >&2
    local last="$WORK/boot$BOOTS"
    if [ -f "$last.console" ]; then
        echo "--- last console lines ($last.console)" >&2
        tail -25 "$last.console" >&2
    fi
    [ -f "$last.stderr" ] && cat "$last.stderr" >&2
    exit 1
}
docker_() { "$DOCKER" "$@"; }
now() { python3 -c 'import time; print(time.time())'; }

# boot: start the machine in the background.
boot() {
    BOOTS=$((BOOTS + 1))
    local base="$WORK/boot$BOOTS"
    "$VMM" --kernel "$KERNEL" --initrd "$INITRD" --disk "$DISK" \
        --share "oci-tools:${OCI_TOOLS}:ro" --workspace "$WS" \
        --vsock-expose "${SOCK}:2375" --published-net \
        --cpus 4 --memory-mib 4096 --quiet --json-summary \
        --console-log "$base.console" >"$base.summary" 2>"$base.stderr" &
    VM_PID=$!
}

wait_api() {
    local start
    start=$(now)
    for _ in $(seq 1 600); do
        if docker_ version --format '{{.Server.APIVersion}}' >/dev/null 2>&1; then
            pass "Docker API up after $(python3 -c "print('%.2f' % ($(now) - $start))")s (boot $BOOTS)"
            return 0
        fi
        kill -0 "$VM_PID" 2>/dev/null || fail "VMM exited before the API came up"
        sleep 0.1
    done
    fail "Docker API did not come up within 60s"
}

# stop_vm SIGNAL: signal our VMM and record its exit code in VM_RC.
stop_vm() {
    kill "-$1" "$VM_PID"
    set +e
    wait "$VM_PID" 2>/dev/null
    VM_RC=$?
    set -e
    VM_PID=""
}

expect_console() {
    grep -qF -- "$1" "$WORK/boot$BOOTS.console" || fail "console lacks: $1"
}

# wait_http PORT TIMEOUT_S [PATH]: poll until the published port returns 200.
wait_http() {
    local code=""
    for _ in $(seq 1 $(($2 * 10))); do
        code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1${3:-/}" || true)
        [ "$code" = 200 ] && return 0
        sleep 0.1
    done
    fail "127.0.0.1:$1 never returned HTTP 200 (last: ${code:-none})"
}

log "setup: $WORK"
cp -c "$SOURCE_DISK" "$DISK"
mkdir -p "$WS"
echo "hello from the mac" >"$WS/hello.txt"
TOKEN="e2e-$$-$RANDOM"
echo "  vmm=$VMM"
echo "  kernel=$KERNEL"
echo "  oci-tools=$OCI_TOOLS"

log "boot 1"
boot
wait_api
expect_console "net: eth0 up mtu=1500 10.42.0.2/24 default via 10.42.0.1"
expect_console "net: eth1 up mtu=9000 10.43.0.2/24 neigh 10.43.0.1 52:54:00:ab:cd:02 permanent"
if grep -qE 'net: WARNING|invalid argument' "$WORK/boot1.console"; then
    fail "guest network setup reported problems: $(grep -E 'net: WARNING|invalid argument' "$WORK/boot1.console")"
fi
pass "guest init configured eth0 and eth1 over rtnetlink"
[ "$(stat -f %Lp "$SOCK")" = 600 ] || fail "docker.sock is not mode 0600"
pass "docker.sock is owner-only"

log "run / exec / logs"
out=$(docker_ run --name e2e-run alpine:3.20 sh -c "echo $TOKEN-out; exit 3") && rc=0 || rc=$?
if [ "$out" != "$TOKEN-out" ] || [ "$rc" != 3 ]; then fail "docker run output/exit: '$out' rc=$rc"; fi
docker_ logs e2e-run | grep -qx "$TOKEN-out" || fail "docker logs lacks the output"
docker_ run -d --name e2e-sleeper alpine:3.20 sleep 3600 >/dev/null
[ "$(docker_ exec e2e-sleeper sh -c 'echo exec-ok')" = exec-ok ] || fail "docker exec output"
set +e
docker_ exec e2e-sleeper sh -c 'exit 7'
rc=$?
set -e
[ "$rc" = 7 ] || fail "docker exec exit code $rc, want 7"
pass "run, logs and exec (with exit codes)"

log "DNS, egress and clock inside a container"
docker_ exec e2e-sleeper nslookup dl-cdn.alpinelinux.org >/dev/null || fail "DNS lookup in a container"
docker_ exec e2e-sleeper wget -q -O /dev/null http://dl-cdn.alpinelinux.org/alpine/ || fail "HTTP egress from a container"
skew=$(($(docker_ exec e2e-sleeper date +%s) - $(date +%s)))
[ "${skew#-}" -le 3 ] || fail "guest clock is ${skew}s off the host"
pass "DNS and egress work; guest clock within ${skew#-}s of the host"

log "published ports"
docker_ run -d --name e2e-web -p "$P_WEB:80" nginx:alpine >/dev/null
wait_http "$P_WEB" 20
pass "127.0.0.1:$P_WEB serves HTTP"
codes=$(seq 1 256 | xargs -P 64 -I{} curl -s -m 10 -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:$P_WEB/" | sort | uniq -c | tr -s ' ')
[ "$codes" = " 256 200" ] || fail "concurrent requests: $codes"
pass "256 requests, 64 concurrent: all 200"
docker_ exec e2e-web sh -c 'head -c 33554432 /dev/urandom > /usr/share/nginx/html/big.bin'
want=$(docker_ exec e2e-web sha1sum /usr/share/nginx/html/big.bin | cut -d' ' -f1)
got=$(curl -s -m 60 "http://127.0.0.1:$P_WEB/big.bin" | shasum | cut -d' ' -f1)
[ "$want" = "$got" ] || fail "32 MiB download checksum $got, want $want"
pass "32 MiB download is byte-exact"

docker_ run -d --name e2e-sink -p "$P_SINK:8080" alpine:3.20 \
    sh -c 'nc -l -p 8080 > /tmp/up.bin; sha1sum /tmp/up.bin > /tmp/up.sha; sleep 3600' >/dev/null
for _ in $(seq 1 100); do
    docker_ exec e2e-sink sh -c 'netstat -ltn | grep -q ":8080 "' && break
    sleep 0.1
done
head -c 16777216 /dev/urandom >"$WORK/up.bin"
python3 - "$P_SINK" "$WORK/up.bin" <<'EOF'
import socket, sys
data = open(sys.argv[2], "rb").read()
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=30)
s.sendall(data)
s.shutdown(socket.SHUT_WR)
while s.recv(65536):
    pass
s.close()
EOF
want=$(shasum "$WORK/up.bin" | cut -d' ' -f1)
for _ in $(seq 1 50); do
    got=$(docker_ exec e2e-sink sh -c 'cat /tmp/up.sha 2>/dev/null' | cut -d' ' -f1)
    [ -n "$got" ] && break
    sleep 0.1
done
[ "$want" = "$got" ] || fail "16 MiB upload checksum ${got:-none}, want $want"
pass "16 MiB upload is byte-exact"

# The port is published before the container listens. Docker semantics: early
# connections may be refused or closed; a retrying client gets through.
docker_ run -d --name e2e-late -p "$P_LATE:80" nginx:alpine \
    sh -c 'sleep 3 && exec nginx -g "daemon off;"' >/dev/null
start=$(now)
wait_http "$P_LATE" 20
pass "late listener served after $(python3 -c "print('%.1f' % ($(now) - $start))")s of client retries"

log "bind mounts (--workspace $WS)"
[ "$(docker_ run --rm -v "$WS:/w" alpine:3.20 cat /w/hello.txt)" = "hello from the mac" ] || fail "read through bind mount"
docker_ run --rm -v "$WS:/w" alpine:3.20 sh -c "mkdir -p /w/sub && echo $TOKEN > /w/sub/from-container"
[ "$(cat "$WS/sub/from-container")" = "$TOKEN" ] || fail "container write not visible on the Mac"
[ "$(stat -f %u "$WS/sub/from-container")" = "$(id -u)" ] || fail "file written by the guest is not owned by the Mac user"
pass "read and write through the bind mount; host owns the files"
if docker_ run --rm -v "$WS:/w:ro" alpine:3.20 touch /w/ro-probe 2>/dev/null; then fail ":ro bind mount was writable"; fi
pass ":ro bind mount rejects writes"
docker_ run --rm --user 1000:1000 -v "$WS:/w" alpine:3.20 touch /w/by-uid-1000 || fail "non-root container cannot write the bind mount"
pass "non-root container writes the bind mount"
docker_ run --rm -v "$WS:/w" alpine:3.20 sh -c 'mkdir /w/data && chown 70:70 /w/data && chmod 700 /w/data'
[ "$(docker_ run --rm --user 70:70 -v "$WS:/w" alpine:3.20 sh -c 'touch /w/data/f && stat -c %u /w/data')" = 70 ] || fail "chown not honoured for its new owner"
if docker_ run --rm --user 1000:1000 -v "$WS:/w" alpine:3.20 ls /w/data >/dev/null 2>&1; then fail "chmod 700 directory readable by another user"; fi
pass "chown + chmod 700 behave as on Linux for container users"
if docker_ run --rm -v "$WORK:/w" alpine:3.20 true 2>/dev/null; then fail "bind outside the workspace was accepted"; fi
pass "binds outside the workspace are rejected"

log "persistence across an orderly stop"
docker_ volume create e2e-vol >/dev/null
docker_ run --rm -v e2e-vol:/data alpine:3.20 sh -c "echo $TOKEN > /data/v.txt"
docker_ create --name e2e-keep alpine:3.20 echo kept >/dev/null
start=$(now)
stop_vm TERM
[ "$VM_RC" = 0 ] || fail "SIGTERM exit code $VM_RC, want 0"
grep -q '"exit_reason":"poweroff","exit_code":0,"guest_failure":null' "$WORK/boot1.summary" || fail "summary: $(cat "$WORK/boot1.summary")"
expect_console "EXT4-fs (vda): re-mounted"
[ ! -e "$SOCK" ] || fail "docker.sock left behind after an orderly stop"
pass "SIGTERM: guest powered off in $(python3 -c "print('%.1f' % ($(now) - $start))")s, exit 0, ext4 remounted read-only, socket removed"

log "boot 2"
boot
wait_api
if grep -q 'recovery complete' "$WORK/boot2.console"; then fail "ext4 needed journal recovery after an orderly stop"; fi
expect_console "EXT4-fs (vda): mounted filesystem"
pass "ext4 mounted clean (no journal recovery)"
docker_ ps -a --format '{{.Names}}' | grep -qx e2e-keep || fail "stopped container e2e-keep is gone"
docker_ ps -a --format '{{.Names}}' | grep -qx e2e-web || fail "container e2e-web is gone"
[ "$(docker_ run --rm -v e2e-vol:/data alpine:3.20 cat /data/v.txt)" = "$TOKEN" ] || fail "volume data lost"
pass "containers and named volume survived the restart"
docker_ start e2e-web >/dev/null
wait_http "$P_WEB" 20
pass "restarted container republishes 127.0.0.1:$P_WEB"

log "kill -9 recovery"
docker_ run --rm -v e2e-vol:/data alpine:3.20 sh -c "echo $TOKEN-2 > /data/v2.txt && sync"
stop_vm KILL
[ -S "$SOCK" ] || fail "expected a stale docker.sock after kill -9"
boot
wait_api
if grep -q 'recovery complete' "$WORK/boot3.console"; then
    pass "ext4 replayed its journal after kill -9"
else
    pass "ext4 mounted after kill -9 (nothing to replay)"
fi
[ "$(docker_ run --rm -v e2e-vol:/data alpine:3.20 cat /data/v.txt /data/v2.txt | tr '\n' ' ')" = "$TOKEN $TOKEN-2 " ] || fail "volume data after kill -9"
pass "stale socket replaced and data intact after kill -9"

log "startup errors are fatal"
set +e
msg=$("$VMM" --kernel "$KERNEL" --initrd "$INITRD" --vsock-expose "${SOCK}:2375" --quiet 2>&1)
rc=$?
set -e
if [ "$rc" != 1 ] || [[ "$msg" != *"in use"* ]]; then fail "binding a live socket: rc=$rc $msg"; fi
pass "a socket another VM serves is refused (exit 1)"
long="$WORK/$(printf 'x%.0s' $(seq 1 100)).sock"
set +e
msg=$("$VMM" --kernel "$KERNEL" --initrd "$INITRD" --vsock-expose "${long}:2375" --quiet 2>&1)
rc=$?
set -e
if [ "$rc" != 1 ] || [[ "$msg" != *"limited to 103 bytes"* ]]; then fail "long socket path: rc=$rc $msg"; fi
pass "a socket path over 103 bytes is refused (exit 1)"
stop_vm TERM
[ "$VM_RC" = 0 ] || fail "SIGTERM exit code $VM_RC after kill -9 recovery"

log "guest failures are not clean exits"
mkdir -p "$WORK/broken-tools/runner"
printf 'echo "e2e: engine exits"\nexit 3\n' >"$WORK/broken-tools/runner/start.sh"
BOOTS=$((BOOTS + 1))
set +e
"$VMM" --kernel "$KERNEL" --initrd "$INITRD" --disk "$DISK" \
    --share "oci-tools:$WORK/broken-tools:ro" --published-net --cpus 2 --memory-mib 1024 \
    --quiet --json-summary --timeout 60 --console-log "$WORK/boot$BOOTS.console" >"$WORK/boot$BOOTS.summary" 2>&1
rc=$?
set -e
if [ "$rc" != 4 ] || ! grep -q '"guest_failure":"engine-exited status=3"' "$WORK/boot$BOOTS.summary"; then
    fail "engine exit: rc=$rc $(cat "$WORK/boot$BOOTS.summary")"
fi
pass "engine exit -> exit 4 (guest_failure: engine-exited status=3)"
BOOTS=$((BOOTS + 1))
set +e
"$VMM" --kernel "$KERNEL" --initrd "$INITRD" --disk "$DISK" \
    --share "oci-tools:${OCI_TOOLS}:ro" --cmdline-append "mp.workspace=/no-such-share" --cpus 2 --memory-mib 1024 \
    --quiet --json-summary --timeout 60 --console-log "$WORK/boot$BOOTS.console" >"$WORK/boot$BOOTS.summary" 2>&1
rc=$?
set -e
if [ "$rc" != 4 ] || ! grep -q '"guest_failure":"init-failed' "$WORK/boot$BOOTS.summary"; then
    fail "init failure: rc=$rc $(cat "$WORK/boot$BOOTS.summary")"
fi
pass "init failure -> exit 4 (guest_failure: init-failed ...)"

log "all checks passed"
