#!/bin/sh
# Run beneath the measured slice launcher. The real compiler blocks on a private FIFO.
set -eu
inspector=/mpcheck/compiler-runtime
tmp=$(mktemp -d "${TMPDIR:-/tmp}/compiler-runtime.XXXXXXXX")
go_pid=
compile_pid=
cleanup() {
    if [ -n "$compile_pid" ]; then kill "$compile_pid" 2>/dev/null || :; fi
    if [ -n "$go_pid" ]; then
        kill "$go_pid" 2>/dev/null || :
        wait "$go_pid" 2>/dev/null || :
    fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
export GOENV=off GOTOOLCHAIN=local GOWORK=off GOPROXY=off GOTELEMETRY=off
export GOCACHE=off TMPDIR="$tmp"
cd "$tmp"
go_path=$(readlink -f "$(command -v go)")
compile_path=$(readlink -f "$(go env GOTOOLDIR)/compile")
dispatcher_path=$(readlink "/proc/$$/exe")
printf 'boot %s\nlimits %s %s\ncgroup_inode %s\nlink %s\n' \
    "$(cat /proc/sys/kernel/random/boot_id)" "$(cat /sys/fs/cgroup/cpuset.cpus.effective)" \
    "$(cat /sys/fs/cgroup/cpu.max)" "$(stat -c '%d:%i' /sys/fs/cgroup)" "$(/mpcheck/guest-link)"
file_identity() {
    test -x "$2"
    digest=$(sha256sum "$2")
    printf 'file %s %s %s\n' "$1" "$2" "${digest%% *}"
}
file_identity taskset "$(readlink -f "$(command -v taskset)")"
file_identity compiler-runtime "$inspector"
file_identity dispatcher "$dispatcher_path"
file_identity go "$go_path"
file_identity compile "$compile_path"

mkfifo proof.go
# Holding this descriptor open prevents EOF until all three processes are inspected.
exec 9<>proof.go
go tool compile -trimpath "$tmp" -o proof.o proof.go 9>&- &
go_pid=$!
tries=0
while [ -z "$compile_pid" ]; do
    kill -0 "$go_pid"
    for status in /proc/[0-9]*/status; do
        proc=${status%/status}
        [ "$(readlink "$proc/exe" 2>/dev/null)" = "$compile_path" ] || continue
        [ "$(awk '$1 == "PPid:" {print $2}' "$status")" = "$go_pid" ] || continue
        compile_pid=${proc##*/}
        break
    done
    tries=$((tries + 1))
    [ "$tries" -lt 120 ] || { echo 'Could not observe the real Go compiler' >&2; exit 1; }
    if [ -z "$compile_pid" ]; then sleep .025; fi
done

report_process() {
    role=$1
    pid=$2
    proc=/proc/$pid
    exe=$(readlink "$proc/exe")
    [ "$exe" = "$3" ]
    ppid=$(awk '$1 == "PPid:" {print $2}' "$proc/status")
    cgroup=$(cat "$proc/cgroup")
    network_ns=$(readlink "$proc/ns/net")
    cgroup_ns=$(readlink "$proc/ns/cgroup")
    threads=$("$inspector" -inspect "$pid")
    printf 'process %s %s %s %s %s %s %s\nthreads %s %s\n' \
        "$role" "$pid" "$ppid" "$exe" "$cgroup" "$network_ns" "$cgroup_ns" "$role" "$threads"
}
report_process dispatcher "$$" "$dispatcher_path"
report_process go "$go_pid" "$go_path"
report_process compile "$compile_pid" "$compile_path"
printf 'package compilerproof\nvar Answer = 42\n' >&9
exec 9>&-
wait "$go_pid"
go_pid=
compile_pid=
test -s proof.o
digest=$(sha256sum proof.o)
printf 'object %s %s\n' "$(stat -c %s proof.o)" "${digest%% *}"
