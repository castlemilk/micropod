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
#     writes and chown semantics, and a postgres image initialising a
#     bind-mounted data directory; a guest chown belongs to the host file, so
#     a non-root user cannot get round it through a hard link or another
#     spelling of the name; a FIFO in the workspace does not hang the share;
#     a stat storm over many spellings of one name does not grow the VMM's
#     node table, and nodes the guest forgets are freed (FORGET); a
#     container cannot reach past its bind mount by renaming a directory and
#     planting a symlink at its old name (hard link and lookup routes); a
#     set-id binary on the workspace does not elevate a non-root user (rw and
#     :ro binds);
#   - SIGTERM is an orderly poweroff (exit 0); on the next boot the stopped
#     container and a named volume are intact and ext4 needs no recovery;
#   - kill -9 of the VMM is recovered: the stale socket is replaced and the
#     data is intact (journal replay is allowed);
#   - an unusable --vsock-expose path fails startup (exit 1);
#   - guest init and engine failures exit 4, not 0;
#   - losing the --parent-pid supervisor powers the guest off in an orderly
#     way (ext4 remounted read-only) and exits 7.
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
TSOCK="$WORK/telemetry.sock"
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
        --vsock-expose "${SOCK}:2375" --published-net --telemetry-socket "$TSOCK" \
        --cpus 4 --memory-mib 4096 --quiet --json-summary \
        --console-log "$base.console" >"$base.summary" 2>"$base.stderr" &
    VM_PID=$!
}

# fs_nodes: Virtio-FS nodes the VMM holds now (all shares), from its telemetry.
fs_nodes() {
    curl -s -m 5 --unix-socket "$TSOCK" http://vmm/healthz |
        python3 -c 'import json, sys; print(json.load(sys.stdin)["fs_nodes"])'
}

# within SECONDS CMD...: run CMD, killing it (status 124) if it outlives SECONDS.
within() {
    local secs=$1 pid rc
    shift
    "$@" &
    pid=$!
    for _ in $(seq 1 $((secs * 10))); do
        if ! kill -0 "$pid" 2>/dev/null; then
            rc=0
            wait "$pid" || rc=$?
            return "$rc"
        fi
        sleep 0.1
    done
    kill -9 "$pid" 2>/dev/null || true
    return 124
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
# The postgres entrypoint's own sequence: root chowns the data directory to
# the user alone (`chown postgres`, the group left as it is), chmod 700, then
# initdb runs as that user and the server checks it owns the directory.
mkdir -p "$WS/pg"
docker_ run -d --name e2e-pg -e POSTGRES_PASSWORD=e2e -v "$WS/pg:/var/lib/postgresql/data" postgres:17-alpine >/dev/null
for _ in $(seq 1 600); do
    docker_ exec e2e-pg pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1 && break
    sleep 0.1
done
[ "$(docker_ exec e2e-pg psql -U postgres -h 127.0.0.1 -tAc 'select 6*7' 2>&1)" = 42 ] ||
    fail "postgres on a bind-mounted data directory: $(docker_ logs e2e-pg 2>&1 | tail -5)"
[ "$(docker_ exec e2e-pg stat -c %u:%a /var/lib/postgresql/data)" = 70:700 ] || fail "postgres data directory owner/mode"
docker_ rm -f e2e-pg >/dev/null
pass "postgres initialises and serves a bind-mounted data directory it chowned"
if docker_ run --rm -v "$WORK:/w" alpine:3.20 true 2>/dev/null; then fail "bind outside the workspace was accepted"; fi
pass "binds outside the workspace are rejected"

log "guest ownership belongs to the host file (hard links, other spellings)"
touch "$WS/case-probe"
CASELESS=0
[ -e "$WS/CASE-PROBE" ] && CASELESS=1
rm -f "$WS/case-probe"
docker_ run --rm -v "$WS:/w" alpine:3.20 sh -c '
    mkdir /w/own && echo secret >/w/own/secret.key && chown 70:70 /w/own/secret.key &&
    chmod 600 /w/own/secret.key && ln /w/own/secret.key /w/own/hl &&
    echo tool >/w/own/tool && chown 70 /w/own/tool && chmod 770 /w/own/tool' || fail "pinning owners as root"
names="secret.key hl"
[ "$CASELESS" = 1 ] && names="$names SECRET.KEY Secret.Key HL"
# shellcheck disable=SC2016 # expanded by the container's shell
out=$(docker_ run --rm --user 1000:1000 -e NAMES="$names" -v "$WS:/w" alpine:3.20 sh -c '
    for f in $NAMES; do
        cat /w/own/$f >/dev/null 2>&1 && echo "read $f"
        chmod 644 /w/own/$f 2>/dev/null && echo "chmod $f"
        echo "$f $(stat -c %u:%g:%a:%i /w/own/$f)"
    done
    echo x >>/w/own/tool 2>/dev/null && echo "write tool"
    echo "tool $(stat -c %u:%g /w/own/tool)"' 2>&1)
case "$out" in
*read* | *chmod\ * | *write*) fail "a non-root user got round a pinned owner: $out" ;;
esac
ino=$(stat -f %i "$WS/own/secret.key")
for f in $names; do
    printf '%s\n' "$out" | grep -qx "$f 70:70:600:$ino" || fail "$f is not 70:70 0600 inode $ino: $out"
done
printf '%s\n' "$out" | grep -qx "tool 70:0" || fail "chown 70 left the group floating: $out"
[ "$(docker_ run --rm --user 70:70 -v "$WS:/w" alpine:3.20 cat /w/own/hl)" = secret ] || fail "the owner cannot read through a hard link"
[ "$(stat -f %Lp "$WS/own/secret.key")" = 600 ] || fail "the Mac file lost its mode"
pass "a pinned owner holds for every name of the file ($([ "$CASELESS" = 1 ] && echo "hard link and case spellings" || echo "hard link")), one inode number; chown of one field settles both"

log "a FIFO in the workspace does not hang the share"
mkdir -p "$WS/fifo"
for i in $(seq 1 10); do mkfifo "$WS/fifo/p$i"; done
# A container opens host FIFOs, and (case-insensitive Macs) reaches one
# through a stale spelling of a name it just renamed the FIFO over, which
# once had the VMM open the FIFO itself and block every container's share.
# shellcheck disable=SC2016 # expanded by the container's shell
docker_ run -d --name e2e-fifo -e CASELESS="$CASELESS" -v "$WS:/w" alpine:3.20 sh -c '
    cd /w/fifo
    for i in $(seq 1 10); do
        if [ "$CASELESS" = 1 ]; then touch r$i && stat R$i >/dev/null && mv p$i r$i; t=R$i; else t=p$i; fi
        cat $t >/dev/null 2>&1 & c=$!
        echo hi >$t 2>/dev/null & w=$!
        sleep 0.2; kill $c $w 2>/dev/null; wait $c $w 2>/dev/null
    done
    echo done >/w/fifo/finished; sleep 3600' >/dev/null
for _ in $(seq 1 300); do [ -f "$WS/fifo/finished" ] && break; sleep 0.1; done
[ -f "$WS/fifo/finished" ] || fail "the container using FIFOs did not finish within 30s"
out=$(within 20 docker_ run --rm -v "$WS:/w" alpine:3.20 sh -c 'echo ok >/w/fifo/after && cat /w/fifo/after && ls /w/fifo | wc -l') ||
    fail "another container could not use the share after the FIFO opens (rc=$?)"
[ "$(printf '%s\n' "$out" | head -1)" = ok ] || fail "share after the FIFO opens: $out"
docker_ rm -f e2e-fifo >/dev/null
pass "FIFOs opened in the workspace (directly and through a stale spelling) leave the share serving"

log "the VMM's node table stays bounded"
before=$(fs_nodes)
[ -n "$before" ] || fail "no fs_nodes in the telemetry"
mkdir -p "$WS/storm" && touch "$WS/storm/$(printf 'a%.0s' $(seq 1 48))"
if [ "$CASELESS" = 1 ]; then
    # shellcheck disable=SC2016 # expanded by the container's shell
    inodes=$(docker_ run --rm -v "$WS:/w" alpine:3.20 sh -c '
        awk "BEGIN { srand(7); for (i = 0; i < 20000; i++) { s = \"\"; for (j = 0; j < 48; j++) s = s (rand() < 0.5 ? \"a\" : \"A\"); print \"/w/storm/\" s } }" |
            xargs stat -c %i | sort -u | wc -l' | tr -d ' ')
    [ "$inodes" = 1 ] || fail "20000 spellings of one name are $inodes files"
    after=$(fs_nodes)
    [ $((after - before)) -lt 200 ] || fail "a stat storm over 20000 spellings grew the node table by $((after - before)) (from $before)"
    pass "20000 spellings of one name are one file and add $((after - before)) nodes (table: $after)"
fi
# A tree walk binds a node per file. When the files go on the Mac and the
# guest looks at the old names, it drops those dentries and inodes and sends
# FORGET, and the VMM frees the nodes.
docker_ run --rm -v "$WS:/w" alpine:3.20 sh -c 'mkdir /w/many && cd /w/many && seq 1 5000 | xargs touch && ls -l >/dev/null'
walked=$(fs_nodes)
[ $((walked - before)) -ge 4000 ] || fail "listing 5000 files bound only $((walked - before)) nodes"
find "$WS/many" -type f -delete
docker_ run --rm -v "$WS:/w" alpine:3.20 sh -c 'cd /w/many && seq 1 5000 | xargs stat >/dev/null 2>&1; true'
for _ in $(seq 1 50); do [ "$(fs_nodes)" -lt $((before + 1000)) ] && break; sleep 0.1; done
dropped=$(fs_nodes)
[ "$dropped" -lt $((before + 1000)) ] || fail "the guest forgot 5000 files but the VMM still holds $dropped nodes (was $walked, $before before)"
pass "5000 listed files: $before -> $walked nodes, $dropped once the guest forgot them"
rm -rf "${WS:?}/own" "${WS:?}/fifo" "${WS:?}/storm" "${WS:?}/many" "${WS:?}/pg"

log "bind mounts stay contained (rename + planted symlink)"
mkdir -p "$WS/proj" "$WS/Library/LaunchAgents"
echo payload >"$WS/proj/payload"
# Hard link route: the shell's cwd is renamed away and its old name becomes a
# symlink to "..", so the cwd's stale host path would end in $WS/Library.
out=$(docker_ run --rm --user 1000:1000 -v "$WS/proj:/app" alpine:3.20 sh -c '
    mkdir -p /app/d/Library/LaunchAgents && cd /app/d/Library/LaunchAgents &&
    mv /app/d /app/e && ln -s .. /app/d && ln /app/payload evil && echo linked' 2>&1) || fail "hard link route: $out"
[ ! -e "$WS/Library/LaunchAgents/evil" ] || fail "a hard link escaped the bind mount into $WS/Library/LaunchAgents"
[ -f "$WS/proj/e/Library/LaunchAgents/evil" ] || fail "the hard link is not in the renamed directory: $out"
pass "a hard link made in a renamed directory lands in it, not through the planted symlink"
# Lookup route: the renamed cwd's old name points at the Mac's /private, and
# the VMM's directory descriptor cache is flushed first (600 directories).
# shellcheck disable=SC2016 # expanded by the container's shell
out=$(docker_ run --rm --user 1000:1000 -v "$WS/proj:/app" alpine:3.20 sh -c '
    mkdir -p /app/x/etc && cd /app/x/etc && mv /app/x /app/y && ln -s /private /app/x &&
    mkdir /app/flush && (cd /app/flush && mkdir $(seq 1 600) && ls $(seq 1 600) >/dev/null) &&
    cat hosts; echo "rc=$?"' 2>&1)
case "$out" in
*broadcasthost*) fail "a lookup in a renamed directory read the Mac's /etc/hosts: $out" ;;
*"rc=0"*) fail "cat hosts in an empty renamed directory succeeded: $out" ;;
esac
[ -z "$(ls -A "$WS/proj/y/etc")" ] || fail "unexpected entries in the renamed directory"
pass "a lookup in a renamed directory does not resolve through the planted symlink"

log "set-id binaries on the workspace do not elevate"
# A 136-byte static arm64 ELF that exits with geteuid() & 0xff (root -> 0, uid 1000 -> 232).
python3 - "$WS/euid-probe" <<'EOF'
import struct, sys
code = struct.pack("<4I", 0xD28015E8, 0xD4000001, 0xD2800BA8, 0xD4000001)  # x0 = geteuid(); exit(x0)
ehdr = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8) + struct.pack(
    "<HHIQQQIHHHHHH", 2, 183, 1, 0x400078, 64, 0, 0, 64, 56, 1, 0, 0, 0)
phdr = struct.pack("<IIQQQQQQ", 1, 5, 0, 0x400000, 0x400000, 136, 136, 0x10000)
with open(sys.argv[1], "wb") as f:
    f.write(ehdr + phdr + code)
EOF
chmod 755 "$WS/euid-probe"
rc=$(docker_ run --rm --user 1000:1000 -v "$WS:/w" alpine:3.20 sh -c '/w/euid-probe; echo $?')
[ "$rc" = 232 ] || fail "euid probe as uid 1000 exited $rc, want 232"
rc=$(docker_ run --rm -v "$WS:/w" alpine:3.20 sh -c '/w/euid-probe; echo $?')
[ "$rc" = 0 ] || fail "euid probe as root exited $rc, want 0"
# A non-root user makes its own (floating-owner) copy set-uid while a root
# container keeps refreshing the guest's attribute cache for the same file.
docker_ run -d --name e2e-statter -v "$WS:/w" alpine:3.20 \
    sh -c 'while :; do stat /w/suid-user >/dev/null 2>&1; done' >/dev/null
# shellcheck disable=SC2016 # expanded by the container's shell
out=$(docker_ run --rm --user 1000:1000 -v "$WS:/w" alpine:3.20 sh -c '
    cp /w/euid-probe /w/suid-user && chmod 4755 /w/suid-user; stat -c %a /w/suid-user
    i=0; while [ $i -lt 50 ]; do /w/suid-user; r=$?; [ $r = 232 ] || { echo "euid=$r"; exit 1; }; i=$((i+1)); done; echo ok')
docker_ rm -f e2e-statter >/dev/null
[ "$out" = "$(printf '755\nok')" ] || fail "set-uid by a non-root user: $out"
[ "$(stat -f %Lp "$WS/suid-user")" = 755 ] || fail "the Mac file kept a guest-set set-uid bit"
pass "a non-root user's set-uid bit is not kept, and exec never runs as root"
# Root makes a root-owned set-uid binary; a non-root user runs it through
# read-write and read-only binds. Container runtimes remount binds without the
# workspace's nosuid, so the VMM itself never keeps or reports set-id bits.
expect_console "workspace: $WS nosuid=true nodev=true"
[ "$(docker_ run --rm -v "$WS:/w" alpine:3.20 sh -c '
    cp /w/euid-probe /w/suid-root && chown 0:0 /w/suid-root && chmod 4755 /w/suid-root &&
    stat -c %a:%u /w/suid-root')" = 755:0 ] || fail "a root-owned file on the workspace kept a set-uid bit"
[ "$(stat -f %Lp "$WS/suid-root")" = 755 ] || fail "the Mac file kept a guest-set set-uid bit (root)"
for opt in "" ":ro"; do
    rc=$(docker_ run --rm --user 1000:1000 -v "$WS:/w$opt" alpine:3.20 sh -c '/w/suid-root; echo $?')
    [ "$rc" = 232 ] || fail "set-uid root binary on a bind mount$opt ran with euid $rc (want 232)"
done
# A set-uid file made on the Mac is not honoured either.
cp "$WS/euid-probe" "$WS/suid-mac" && chmod 4755 "$WS/suid-mac"
out=$(docker_ run --rm --user 1000:1000 -v "$WS:/w" alpine:3.20 sh -c 'stat -c %a /w/suid-mac; /w/suid-mac; echo $?')
[ "$out" = "$(printf '755\n232')" ] || fail "a set-uid file from the Mac: $out"
pass "set-uid root binaries on the workspace (root-made or from the Mac) do not elevate, rw or :ro"
rm -rf "${WS:?}/proj" "${WS:?}/Library" "${WS:?}"/suid-* "${WS:?}/euid-probe"

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

log "supervisor loss is an orderly poweroff"
BOOTS=$((BOOTS + 1))
base="$WORK/boot$BOOTS"
# A stand-in supervisor: the VMM is its child and names it with --parent-pid.
python3 - "$base" "$VMM" --kernel "$KERNEL" --initrd "$INITRD" --disk "$DISK" \
    --share "oci-tools:${OCI_TOOLS}:ro" --workspace "$WS" \
    --vsock-expose "${SOCK}:2375" --cpus 2 --memory-mib 2048 --quiet --json-summary \
    --console-log "$base.console" <<'EOF' &
import os, subprocess, sys
base, cmd = sys.argv[1], sys.argv[2:]
with open(base + ".summary", "wb") as out, open(base + ".stderr", "wb") as err:
    vm = subprocess.Popen(cmd + ["--parent-pid", str(os.getpid())], stdout=out, stderr=err)
with open(base + ".pid", "w") as f:
    f.write(str(vm.pid))
vm.wait()
EOF
SUPERVISOR=$!
for _ in $(seq 1 50); do [ -s "$base.pid" ] && break; sleep 0.1; done
VM_PID=$(cat "$base.pid")
wait_api
docker_ run --rm -v e2e-vol:/data alpine:3.20 sh -c "echo $TOKEN-3 > /data/v3.txt"
start=$(now)
kill -KILL "$SUPERVISOR"
for _ in $(seq 1 300); do kill -0 "$VM_PID" 2>/dev/null || break; sleep 0.1; done
kill -0 "$VM_PID" 2>/dev/null && fail "VMM still running 30s after its supervisor died"
VM_PID=""
grep -q '"exit_reason":"poweroff","exit_code":7,' "$base.summary" || fail "summary: $(cat "$base.summary")"
expect_console "EXT4-fs (vda): re-mounted"
pass "supervisor killed: guest powered off in $(python3 -c "print('%.1f' % ($(now) - $start))")s, ext4 remounted read-only, exit 7"
boot
wait_api
if grep -q 'recovery complete' "$WORK/boot$BOOTS.console"; then fail "ext4 needed journal recovery after a supervisor loss"; fi
[ "$(docker_ run --rm -v e2e-vol:/data alpine:3.20 cat /data/v3.txt)" = "$TOKEN-3" ] || fail "volume data lost after a supervisor loss"
pass "next boot: ext4 clean, data intact"
stop_vm TERM
[ "$VM_RC" = 0 ] || fail "SIGTERM exit code $VM_RC after the supervisor-loss boot"

log "all checks passed"
