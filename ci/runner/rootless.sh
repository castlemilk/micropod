#!/bin/bash
# Invoked only by the allocation user's RootlessKit child. Its mounts, network
# devices and firewall belong exclusively to this disposable allocation.
set -eu
umask 077
tools=/opt/micropod-oci/runner
export PATH="$tools/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
test "$(awk 'NR==1{print $1,$2,$3}' /proc/self/uid_map)" = '0 1001 1'
export MICROPOD_ENGINE_ROOTLESS=1 MICROPOD_ENGINE_WORKSPACE=/work
MICROPOD_CI_INSTANCE=$(cat /proc/sys/kernel/random/boot_id)
export MICROPOD_CI_INSTANCE MICROPOD_CI_WORKER_ID="$MICROPOD_CI_INSTANCE"
MICROPOD_ROOTLESS_UPLINK=$(ip -4 route show default | awk 'NR==1{print $5}')
export MICROPOD_ROOTLESS_UPLINK
test -n "$MICROPOD_ROOTLESS_UPLINK"
mkdir -p /etc/cni/net.d /run/containerd /run/micropod-oci
for data in containerd cni micropod; do
    mkdir -p "/work/docker/$data" "/var/lib/$data"
    mount --bind "/work/docker/$data" "/var/lib/$data"
done
cp "$tools/10-micropod.conflist" /etc/cni/net.d/
awk '{print} /^version = 3$/ {print "[plugins.\"io.containerd.cri.v1.runtime\"]\n  restrict_oom_score_adj = true"}' "$tools/containerd.toml" > /run/containerd/private.toml
iptables -w 5 -t nat -A POSTROUTING -s 10.88.0.0/16 -o "$MICROPOD_ROOTLESS_UPLINK" -j MASQUERADE
(umask 022; exec containerd --config /run/containerd/private.toml) &
engine=$!
api=
trap 'kill "$engine" ${api:+"$api"} 2>/dev/null || true' EXIT
trap 'exit 0' TERM INT
for i in $(seq 1 80); do
    job status >/dev/null 2>&1 && break
    kill -0 "$engine" && [ "$i" -lt 80 ] || exit 1
    sleep .1
done
job recover
job engine &
api=$!
# The Ubuntu allocation image provides bash and its wait -n builtin.
wait -n "$engine" "$api"
