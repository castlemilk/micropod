#!/bin/sh
# Dedicated scheduler-owned node. No control socket is mounted into a job.
set -eu
umask 077
tools=/opt/micropod-oci
export PATH="$tools/runner/bin:/opt/kata/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# A `set -e` exit says nothing, and guest init can only report the status:
# every exit that is not a success names the step it ended.
step="starting"
cleanup=
on_exit() {
    status=$?
    eval "$cleanup" || true
    [ "$status" = 0 ] || echo "start.sh: exited with status $status while $step" >&2
}
trap on_exit EXIT
step="configuring the CI scheduler"
# The trusted worker supervisor supplies this optional kernel command-line setting.
configure_scheduler() (
    selection=$(tr ' ' '\n' </proc/cmdline | sed -n '/^micropod\.ci_sched=/p')
    wakeup=$(tr ' ' '\n' </proc/cmdline | sed -n '/^micropod\.ci_wakeup=/p')
    [ -n "$selection$wakeup" ] || exit 0
    case "$selection" in
        ''|micropod.ci_sched=hrtick) slice= ;;
        micropod.ci_sched=hrtick-1ms) slice=1000000 ;;
        micropod.ci_sched=hrtick-500us) slice=500000 ;;
        micropod.ci_sched=hrtick-250us) slice=250000 ;;
        micropod.ci_sched=hrtick-125us) slice=125000 ;;
        *) echo "Unknown or repeated Micropod CI scheduler setting: $selection" >&2; exit 1 ;;
    esac
    case "$wakeup" in
        ''|micropod.ci_wakeup=next-buddy|micropod.ci_wakeup=next-buddy,sync-colocate|micropod.ci_wakeup=sync-colocate|micropod.ci_wakeup=next-buddy,sync-colocate,no-ttwu-queue) ;;
        *) echo "Unknown or repeated Micropod CI wakeup setting: $wakeup" >&2; exit 1 ;;
    esac

    debug=/sys/kernel/debug
    if [ ! -d "$debug/sched" ]; then
        debug=$(mktemp -d)
        trap 'rmdir "$debug"' EXIT
        mount -t debugfs -o nosuid,nodev,noexec debugfs "$debug"
        trap 'umount "$debug" && rmdir "$debug"' EXIT
    fi
    enable_feature() {
        # Each debugfs write is a separate command. Pass just the feature token.
        if ! printf '%s' "$1" >"$debug/sched/features" || ! grep -qw "$1" "$debug/sched/features"; then
            echo "Guest kernel did not enable scheduler feature $1" >&2
            return 1
        fi
    }
    if [ -n "$selection" ]; then
        if [ -r /proc/config.gz ] && ! zcat /proc/config.gz | grep -qx 'CONFIG_SCHED_HRTICK=y'; then
            echo "CI scheduler requires CONFIG_SCHED_HRTICK in the guest kernel" >&2
            exit 1
        fi
        enable_feature HRTICK
        if [ -n "$slice" ]; then
            printf '%s' "$slice" >"$debug/sched/base_slice_ns"
            # Rewriting tunable_scaling with its own value makes the kernel
            # derive its CPU-count-normalized copy from this slice, so a
            # sched domain rebuild keeps it (vmm/guest-init/sched.go).
            if scaling=$(cat "$debug/sched/tunable_scaling" 2>/dev/null); then
                printf '%s' "$scaling" >"$debug/sched/tunable_scaling"
            fi
            [ "$(cat "$debug/sched/base_slice_ns")" = "$slice" ] || { echo "Guest kernel rejected slice $slice ns" >&2; exit 1; }
        fi
        echo "CI fair scheduler enabled HRTICK with base slice $(cat "$debug/sched/base_slice_ns") ns" >&2
    fi
    if [ -n "$wakeup" ]; then
        case ",${wakeup#micropod.ci_wakeup=}," in
            *,next-buddy,*)
                grep -qw PICK_BUDDY "$debug/sched/features" || { echo "CI wakeup preference requires PICK_BUDDY" >&2; exit 1; }
                enable_feature NEXT_BUDDY
                echo "CI fair scheduler enabled NEXT_BUDDY" >&2
                ;;
        esac
        case ",${wakeup#micropod.ci_wakeup=}," in
            *,sync-colocate,*)
                if grep -qwE '(NO_)?SYNC_COLOCATE' "$debug/sched/features"; then
                    enable_feature SYNC_COLOCATE
                    echo "CI fair scheduler enabled SYNC_COLOCATE" >&2
                else
                    echo "Guest kernel does not expose SYNC_COLOCATE; keeping default wakeup placement" >&2
                fi
                ;;
        esac
        case ",${wakeup#micropod.ci_wakeup=}," in
            *,no-ttwu-queue,*)
                if grep -qwE '(NO_)?TTWU_QUEUE' "$debug/sched/features"; then
                    enable_feature NO_TTWU_QUEUE
                    echo "CI fair scheduler enabled NO_TTWU_QUEUE" >&2
                fi
                ;;
        esac
    fi
)
configure_scheduler
step="applying the CI sysctl profile"
configure_sysctls() (
    selection=$(tr ' ' '\n' </proc/cmdline | sed -n '/^micropod\.ci_sysctls=/p')
    [ -n "$selection" ] || exit 0
    case "$selection" in
        micropod.ci_sysctls=perf) ;;
        *) echo "Unknown or repeated Micropod CI sysctl profile: $selection" >&2; exit 1 ;;
    esac
    apply_sysctl() {
        path="/proc/sys/$1"
        val="$2"
        if [ -w "$path" ]; then
            printf '%s\n' "$val" >"$path" || {
                echo "Guest kernel rejected sysctl $1=$val" >&2
                return 1
            }
        fi
    }
    apply_sysctl vm/compaction_proactiveness 0
    apply_sysctl vm/watermark_boost_factor 0
    apply_sysctl vm/overcommit_memory 1
    apply_sysctl kernel/sched_rt_runtime_us 1000000
    apply_sysctl kernel/pid_max 4194304
    apply_sysctl net/core/rmem_max 7500000
    apply_sysctl net/core/wmem_max 7500000
    apply_sysctl net/netfilter/nf_conntrack_max 327680
    cc=$(tr ' ' '\n' </proc/cmdline | sed -n 's/^micropod\.ci_cc=//p')
    case "$cc" in
        '') ;;
        cubic)
            if [ -r /proc/sys/net/ipv4/tcp_available_congestion_control ] && grep -qw cubic /proc/sys/net/ipv4/tcp_available_congestion_control; then
                apply_sysctl net/ipv4/tcp_congestion_control cubic
                echo "CI TCP congestion control set to cubic (preserving fq qdisc)" >&2
            else
                echo "Guest kernel does not expose cubic TCP congestion control; keeping default" >&2
            fi
            ;;
        bbr)
            apply_sysctl net/core/default_qdisc fq
            apply_sysctl net/ipv4/tcp_congestion_control bbr
            echo "CI TCP congestion control set to bbr + fq" >&2
            ;;
        *) echo "Unknown Micropod CI congestion control setting: $cc" >&2; exit 1 ;;
    esac
    echo "CI sysctl profile perf applied" >&2
)
configure_sysctls
step="preparing the node"
# Each containerd shim watches its cgroup's memory.events. The pause pods
# and job containers share the same real UID on this dedicated Linux node.
#
# The kernel's defaults are sized for one user's session, and this node runs
# hundreds of containers at once, all as the same real UID. Each limit below
# stops containers from starting, or the programs in them from working, well
# before the machine runs out of CPU or memory:
#   pid_max            32768 tasks in all: threads count, and a few dozen
#                      builds (Go, the JVM) reach it
#   inotify instances  one per shim, plus every file watcher in every
#                      container (128 by default, 512 before this)
#   inotify watches    shared by every container's watchers
#   max_map_count      65530 by default; Elasticsearch and OpenSearch
#                      refuse to start below 262144
#   neighbour table    1024 entries by default: one per container on a bridge
# Only ever raised: a kernel or a profile that set more keeps it.
raise_limit() {
    path="/proc/sys/$1"
    [ -w "$path" ] || return 0
    current=$(cat "$path" 2>/dev/null) || return 0
    [ "$current" -lt "$2" ] 2>/dev/null || return 0
    echo "$2" >"$path" 2>/dev/null || echo "Could not raise the guest's $1 from $current to $2" >&2
}
raise_limit kernel/pid_max 4194304
raise_limit fs/inotify/max_user_instances 8192
raise_limit fs/inotify/max_user_watches 1048576
raise_limit vm/max_map_count 262144
raise_limit net/ipv4/neigh/default/gc_thresh2 4096
raise_limit net/ipv4/neigh/default/gc_thresh3 8192
mkdir -p /run/containerd /var/lib/micropod /etc/cni/net.d /etc/cni/micropod-private
# No network namespace outlives a boot, so no address the default network
# handed out before this boot is in use. BuildKit cannot give back the ones
# its pooled namespaces held (its DEL of a namespace left from an earlier
# boot fails in the loopback plugin: the mount is gone), so each restart
# leaked as many addresses as RUN steps had last run at once. The
# allocator's position (last_reserved_ip) stays, so addresses keep being
# handed out in turn.
for reservation in /var/lib/cni/networks/micropod-ci/10.*; do
    if [ -f "$reservation" ]; then rm -f "$reservation"; fi
done
packages=
command -v iptables >/dev/null || packages=iptables
if [ "${MICROPOD_CI_PUBLISHED_PATH:-}" = macvlan ] && ! command -v nft >/dev/null; then
    packages="$packages nftables"
fi
if [ -n "$packages" ]; then
    if [ -d "$tools/runner/network-apks" ]; then
        apk --repositories-file /dev/null add --no-network "$tools"/runner/network-apks/*.apk
    else
        apk add --no-cache $packages
    fi
fi
# The default network's plugin is micropod-bridge (the bridge plugin with a
# DEL that leaves the veth to the namespace's own teardown) when the bundle
# has it; a bundle without it keeps the bridge plugin.
if [ -x "$tools/runner/cni/micropod-bridge" ]; then
    rm -f /etc/cni/net.d/10-micropod.conflist
    sed 's/"type": "bridge"/"type": "micropod-bridge"/' "$tools/runner/10-micropod.conflist" >/etc/cni/net.d/10-micropod.conflist.tmp
    chmod 0644 /etc/cni/net.d/10-micropod.conflist.tmp
    mv /etc/cni/net.d/10-micropod.conflist.tmp /etc/cni/net.d/10-micropod.conflist
else
    ln -sf "$tools/runner/10-micropod.conflist" /etc/cni/net.d/10-micropod.conflist
fi
ln -sf "$tools/runner/10-micropod-private.conflist" /etc/cni/micropod-private/10-micropod.conflist
if [ -x /opt/kata/bin/containerd-shim-kata-v2 ]; then
    if ! [ -x /sbin/ip ] || ! apk info -e iproute2-minimal >/dev/null; then apk add --no-cache iproute2; fi
    # Private macvlan ports on an empty bridge have neither a peer path nor an uplink.
    ip link add mpciiso0 type bridge
    ip link set mpciiso0 up
    for dev in kvm vhost-net vhost-vsock tun; do
        node="/dev/$dev"
        if [ "$dev" = tun ]; then mkdir -p /dev/net; node=/dev/net/tun; fi
        if [ ! -c "$node" ] && [ -f "/sys/class/misc/$dev/dev" ]; then
            pair=$(cat "/sys/class/misc/$dev/dev")
            mknod "$node" c "${pair%:*}" "${pair#*:}"
        fi
    done
    # The pinned arm64 QEMU build on nested Apple KVM has no configurable PMU.
    # Never accept hypervisor configuration annotations from workloads.
    mkdir -p /etc/kata-containers
    sed -e 's/^cpu_features = "pmu=off"$/cpu_features = ""/' -e 's/^enable_annotations = .*/enable_annotations = []/' \
        /opt/kata/share/defaults/kata-containers/configuration.toml > /etc/kata-containers/configuration.toml
fi
# Move the VM's initial processes into a leaf before enabling cgroup v2 delegation.
# Guest init starts this script at the root of its own cgroup namespace (the
# worker cgroup), where only this shell is listed. A process that exited after
# the list was read needs no move; one that is still there and cannot be moved
# (a kernel thread, if this ever runs at the real root) ends the boot, loudly.
step="moving the worker's processes into a leaf cgroup"
cg=/sys/fs/cgroup
mkdir -p "$cg/init"
while read -r pid; do
    if ! echo "$pid" 2>/run/micropod-cgroup-move.err >"$cg/init/cgroup.procs" && [ -e "/proc/$pid" ]; then
        echo "start.sh: cannot move process $pid ($(cat "/proc/$pid/comm" 2>/dev/null)) out of the cgroup root ($(cat /proc/self/cgroup)): $(cat /run/micropod-cgroup-move.err)" >&2
        exit 1
    fi
done < "$cg/cgroup.procs"
step="enabling the worker's cgroup controllers"
for controller in cpu memory pids; do
    if ! grep -qw "$controller" "$cg/cgroup.controllers"; then
        echo "start.sh: the worker cgroup has no $controller controller (it has: $(cat "$cg/cgroup.controllers"))" >&2
        exit 1
    fi
    echo "+$controller" > "$cg/cgroup.subtree_control"
done
if [ "${MICROPOD_ENGINE_API:-}" = 1 ] && grep -qw cpuset "$cg/cgroup.controllers"; then
    echo +cpuset > "$cg/cgroup.subtree_control" || echo "Container CPU placement is unavailable" >&2
fi
step="setting up the node's network"
echo 1 > /proc/sys/net/ipv4/ip_forward
# The VM owns a single uplink. One subnet rule amortizes NAT setup across jobs.
iptables -w 5 -t nat -C POSTROUTING -s 10.88.0.0/16 -o eth0 -j MASQUERADE 2>/dev/null ||
    iptables -w 5 -t nat -A POSTROUTING -s 10.88.0.0/16 -o eth0 -j MASQUERADE
. "$tools/runner/published-ports.sh"
# The snapshotter creates each container root with mode 0755. An inherited
# 0077 umask makes / unsearchable after the image switches to a non-root UID.
step="starting containerd and the engine"
# micropod.start_boost_ms=<milliseconds> (machine.json kernelArguments) turns
# the engine's start boost on for a measurement; it is off without it
# (guest/runner/docker_start_boost_linux.go). The engine refuses a value it
# cannot use.
start_boost=$(tr ' ' '\n' </proc/cmdline | sed -n 's/^micropod\.start_boost_ms=//p' | tail -n 1)
if [ -n "$start_boost" ]; then export MICROPOD_START_BOOST_MS="$start_boost"; fi
# containerd, its shims and so every container inherit this open-file limit
# (init's is 1024, 4096 at most): containerd itself holds descriptors for
# every live container, and a container gets what a Docker daemon gives
# (1048576), which databases and language servers in CI images expect.
(umask 022; ulimit -n 1048576 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
    exec containerd --config "$tools/runner/containerd.toml") &
engine=$!
service=
api=
cleanup='kill "$engine" ${service:+"$service"} ${api:+"$api"} 2>/dev/null'
trap 'exit 0' TERM INT
# The engine starts beside containerd and waits for its CRI itself (every
# 5 ms, for up to a minute), then recovers interrupted jobs and containers,
# and only then opens the Docker API socket. If containerd exits first, the
# wait below returns.
# A socket file an earlier boot left would look like this boot's below.
rm -f /var/lib/micropod/docker.sock
"$tools/runner/bin/job" engine &
api=$!
# The OCI service runs a scheduler job as soon as it is asked to, and the
# engine's recovery removes every job and ready pod it finds. So the service
# starts only once the engine has recovered and bound its socket, as it did
# when `job recover` ran here before either. The engine does not wait for
# this loop: the first _ping is no later for it.
step="waiting for the engine to open its socket"
until [ -S /var/lib/micropod/docker.sock ]; do
    kill -0 "$engine" 2>/dev/null || { echo "start.sh: containerd exited before the engine opened its socket" >&2; exit 1; }
    # The engine's own status (4: its start-up outlasted its budget) is the
    # one guest init reports.
    if ! kill -0 "$api" 2>/dev/null; then
        status=0
        wait "$api" || status=$?
        echo "start.sh: the engine exited with status $status before it opened its socket" >&2
        [ "$status" != 0 ] || status=1
        exit "$status"
    fi
    usleep 10000 2>/dev/null || sleep 0.01 2>/dev/null || sleep 1
done
"$tools/service" serve &
service=$!
# Serve until containerd, the engine or the OCI service exits, then exit: guest
# init reports that and the supervisor relaunches the machine. BusyBox ash
# cannot wait for the first of several jobs: `wait -n` with IDs waits for
# every one of them, and without IDs it does not return for a job that a
# signal killed (the OOM killer, a crash). So an engine that died alone left a
# machine that looked running and answered nothing. Poll instead: `wait` on the
# sleep reaps any child that died meanwhile, after which kill -0 fails, and a
# stop's SIGTERM still interrupts the wait at once.
step="serving (containerd, the engine or the OCI service exited)"
while kill -0 "$engine" 2>/dev/null && kill -0 "$service" 2>/dev/null && kill -0 "$api" 2>/dev/null; do
    sleep 1 &
    wait $!
done
exit 1
