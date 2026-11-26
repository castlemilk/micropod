#!/bin/sh
# micropod-vmm of the updater gate's "boots but fails the probe" payloads.
#
# The payload directory holds the real, signed micropod-vmm, the proxy and a
# mode file at tools/b26-gate/. The wrapper rewrites the argv the supervisor
# gave it and execs the real VMM with the same pid, so the supervisor's
# signals, readiness and exit handling are the product's own. The guest is the
# real one and boots normally. Modes:
#
#   metrics503     (default) the guest Docker API's --vsock-expose moves from
#                  <root>/run/docker.sock to <root>/run/b26-up.sock, and
#                  probefail_proxy.py on <root>/run/docker.sock forwards
#                  everything but GET /micropod/metrics, which it answers 503
#   no-cache-disk  the --cache-disk argument is dropped (the boot argument
#                  mp.cache_disk=1 stays), so the guest comes up without the
#                  persistent cache disk it should have; caches.ext4 is untouched
#
# Each launch appends "<epoch> mode=<mode> pid=<pid>" to <root>/logs/b26-wrapper.log.
here=$(cd "$(dirname "$0")" && pwd -P)
real="$here/tools/b26-gate/micropod-vmm"
proxy="$here/tools/b26-gate/probefail_proxy.py"
mode=metrics503
[ -f "$here/tools/b26-gate/mode" ] && mode=$(cat "$here/tools/b26-gate/mode")
sock=""
disk=""
prev=""
skip=0
for arg do
    shift
    if [ "$skip" = 1 ]; then
        skip=0
        prev="$arg"
        continue
    fi
    if [ "$mode" = no-cache-disk ] && [ "$arg" = "--cache-disk" ]; then
        skip=1
        prev="$arg"
        continue
    fi
    [ "$prev" = "--disk" ] && disk="$arg"
    if [ "$mode" = metrics503 ] && [ "$prev" = "--vsock-expose" ]; then
        case "$arg" in
        */run/docker.sock:*)
            sock="${arg%:*}"
            arg="${sock%/docker.sock}/b26-up.sock:${arg##*:}"
            ;;
        esac
    fi
    set -- "$@" "$arg"
    prev="$arg"
done
root="${disk%/disk.ext4}"
[ -n "$root" ] && [ -d "$root/logs" ] && echo "$(date +%s) mode=$mode pid=$$" >>"$root/logs/b26-wrapper.log"
[ "$mode" = metrics503 ] && [ -n "$sock" ] || exec "$real" "$@"
log="${sock%/run/docker.sock}/logs/b26-probefail-proxy.log"
/usr/bin/python3 -I "$proxy" --listen "$sock" --upstream "${sock%/docker.sock}/b26-up.sock" \
    --watch-pid "$$" --log "$log" </dev/null >>"$log" 2>&1 &
exec "$real" "$@"
