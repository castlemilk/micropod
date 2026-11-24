#!/bin/sh
# Run in the already-authorized service network namespace with its IPv4 publication peer.
set -eu
export LC_ALL=C
test "$#" = 1 || exit 2
case "$1" in ''|*[!0-9.]*) exit 2 ;; esac
printf 'service-qdisc-v1\n'
cat /proc/sys/kernel/random/boot_id
readlink /proc/self/ns/net
cat /proc/uptime
printf '@@ link-before\n'
ip -j -s -d link show dev mppub0
printf '\n@@ route\n'
ip -4 -j route get "$1"
printf '\n@@ qdisc\n'
tc -j -s -d qdisc show dev mppub0
printf '\n@@ link-after\n'
ip -j -s -d link show dev mppub0
printf '\n@@ end\n'
cat /proc/uptime
readlink /proc/self/ns/net
cat /proc/sys/kernel/random/boot_id
