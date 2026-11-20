#!/bin/sh
# Dedicated scheduler-owned node. No control socket is mounted into a job.
set -eu
umask 077
tools=/opt/micropod-oci
export PATH="$tools/runner/bin:/opt/kata/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
mkdir -p /run/containerd /var/lib/micropod /etc/cni/net.d /etc/cni/micropod-private
if ! command -v iptables >/dev/null; then apk add --no-cache iptables; fi
ln -sf "$tools/runner/10-micropod.conflist" /etc/cni/net.d/10-micropod.conflist
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
cg=/sys/fs/cgroup
mkdir -p "$cg/init"
while read -r pid; do
    echo "$pid" > "$cg/init/cgroup.procs" 2>/dev/null || [ ! -e "/proc/$pid" ]
done < "$cg/cgroup.procs"
for controller in cpu memory pids; do
    grep -qw "$controller" "$cg/cgroup.controllers"
    echo "+$controller" > "$cg/cgroup.subtree_control"
done
echo 1 > /proc/sys/net/ipv4/ip_forward
containerd --config "$tools/runner/containerd.toml" &
engine=$!
service=
trap 'kill "$engine" ${service:+"$service"} 2>/dev/null || true' EXIT
trap 'exit 0' TERM INT
attempts=60
until "$tools/runner/bin/job" status >/dev/null; do
    kill -0 "$engine" || exit 1
    [ "$attempts" -gt 0 ] || exit 1
    attempts=$((attempts-1))
    sleep 1
done
"$tools/runner/bin/job" recover
"$tools/service" serve &
service=$!
# BusyBox ash waits for either critical process. The supervisor observes its exit.
wait -n "$engine" "$service"
