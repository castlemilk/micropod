#!/bin/sh
# Hold the shipped compiler on a private FIFO until both Go processes are visible.
set -eu
mask=$1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/compiler-affinity.XXXXXXXX")
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
taskset_path=$(readlink -f "$(command -v taskset)")
go_path=$(readlink -f "$(command -v go)")
compile_path=$(readlink -f "$(go env GOTOOLDIR)/compile")
printf 'boot %s\nrequested %s\n' "$(cat /proc/sys/kernel/random/boot_id)" "$mask"
file_identity() {
    test -x "$2"
    digest=$(sha256sum "$2")
    printf 'file %s %s %s\n' "$1" "$2" "${digest%% *}"
}
file_identity taskset "$taskset_path"
file_identity go "$go_path"
file_identity compile "$compile_path"

mkfifo proof.go
# Holding this descriptor open prevents the compiler from seeing EOF while sampled.
exec 9<>proof.go
nice -n 0 taskset -c "$mask" go tool compile -o proof.o proof.go 9>&- &
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
    [ "$tries" -lt 120 ] || { echo 'Could not observe the Go compiler' >&2; exit 1; }
    if [ -z "$compile_pid" ]; then sleep .025; fi
done

report_process() {
    role=$1
    pid=$2
    exe=$(readlink "/proc/$pid/exe")
    [ "$exe" = "$3" ]
    ppid=$(awk '$1 == "PPid:" {print $2}' "/proc/$pid/status")
    nice_value=$(awk '{print $19}' "/proc/$pid/stat")
    printf 'process %s %s %s %s %s\n' "$role" "$pid" "$ppid" "$nice_value" "$exe"
    for status in "/proc/$pid"/task/[0-9]*/status; do
        cpus=$(awk '$1 == "Cpus_allowed_list:" {print $2}' "$status" 2>/dev/null) || continue
        [ "$cpus" = "$mask" ]
        task=${status%/status}
        printf 'thread %s %s %s\n' "$role" "${task##*/}" "$cpus"
    done
}
report_process go "$go_pid" "$go_path"
report_process compile "$compile_pid" "$compile_path"
printf 'package affinityproof\nvar Answer = 42\n' >&9
exec 9>&-
wait "$go_pid"
go_pid=
compile_pid=
test -s proof.o
printf 'object_bytes %s\n' "$(stat -c %s proof.o)"
