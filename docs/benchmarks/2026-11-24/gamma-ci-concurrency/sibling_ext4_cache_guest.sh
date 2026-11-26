#!/bin/sh
# Owned fixture boot only. Nothing runs between FIFO requests.
set -eu
export LC_ALL=C
unset LD_LIBRARY_PATH LD_PRELOAD
umask 077

workspace=$1
owner=$2
block=$3
tools=/opt/micropod-oci/runner/ext4-cache-tools
control="$workspace/ext4-cache-control"
records="$workspace/ext4-cache-records"
engine=/var/lib/micropod/engine
volume="$engine/volumes/$owner-a-grouped-go"
backdir="$engine/$owner-ext4-cache"
image="$backdir/cache.img"
image_bytes=536870912
group_bytes=134217728
loop=
device_stats=
control_mounted=false
data_mounted=false
backdir_owned=false
control_mount=
data_mount=

fail() { printf '%s\n' "$*" >&2; exit 1; }

run() {
    program=$1
    shift
    "$tools/lib/ld-linux-aarch64.so.1" --inhibit-cache --library-path "$tools/lib" "$tools/bin/$program" "$@"
}

record() { mv "$records/$1.tmp" "$records/$1"; }
mount_row() { awk -v path="$1" '$5 == path {print}' /proc/self/mountinfo; }

unmount_owned() {
    [ -n "$2" ] && [ "$(mount_row "$1")" = "$2" ] || return 1
    umount "$1" && [ -z "$(mount_row "$1")" ]
}

detach_owned() {
    [ -n "$loop" ] || return 0
    loop_sys="/sys/class/block/${loop#/dev/}/loop/backing_file"
    [ "$(cat "$loop_sys")" = "$image" ] || return 1
    run losetup --detach "$loop" || return 1
    # LOOP_CLR_FD can defer detachment if another namespace holds a mount.
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if [ ! -e "$loop_sys" ]; then
            loop=
            return 0
        fi
        sleep .25
    done
    return 1
}

cleanup() {
    result=$?
    trap - EXIT
    if "$data_mounted"; then
        if unmount_owned "$volume" "$data_mount"; then data_mounted=false; else result=1; fi
    fi
    if ! "$data_mounted"; then
        detach_owned || result=1
        if [ -z "$loop" ] && "$backdir_owned"; then
            rm -f "$image" && rmdir "$backdir" || result=1
        fi
    fi
    if "$control_mounted"; then unmount_owned "$control" "$control_mount" || result=1; fi
    if [ "$result" -ne 0 ]; then
        printf 'exit=%s\n' "$result" > "$records/error.tmp"
        record error
    fi
    exit "$result"
}

case "$owner" in mp-t-*) ;; *) fail 'invalid private worker owner';; esac
case "$owner" in *[!a-z0-9_-]*) fail 'invalid private worker owner';; esac
case "$block" in 4096|16384) ;; *) fail 'invalid ext4 block size';; esac
[ "$workspace" = "/private/tmp/$owner/workspace" ] || fail 'invalid private workspace'
[ "$(id -u)" -eq 0 ] && [ -c /dev/loop-control ] || fail 'guest root and loop control are required'
page_bytes=$(run getconf PAGESIZE)
[ "$page_bytes" = 16384 ] || fail 'expected a 16 KiB guest page size'
[ -d "$control" ] && [ ! -L "$control" ] && [ -z "$(mount_row "$control")" ] || fail 'control directory already mounted'
[ -d "$records" ] && [ ! -L "$records" ] && [ ! -e "$records/ready" ] || fail 'invalid receipt directory'

trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mount -t tmpfs -o size=1m,mode=0700,nosuid,nodev,noexec cache-control "$control"
control_mounted=true
control_mount=$(mount_row "$control")
[ -n "$control_mount" ] || fail 'control mount identity unavailable'
mkfifo -m 0600 "$control/request"
boot=$(cat /proc/sys/kernel/random/boot_id)
printf 'boot=%s\npage_bytes=%s\nloop_control=%s\n' "$boot" "$page_bytes" "$(stat -c %t:%T /dev/loop-control)" > "$records/ready.tmp"
record ready
IFS= read -r action < "$control/request"
[ "$action" = prepare ] || fail 'expected cache prepare command'

[ -d "$volume" ] && [ "$(realpath "$volume")" = "$volume" ] && [ -z "$(mount_row "$volume")" ] &&
    [ -z "$(ls -A "$volume")" ] || fail 'expected a new empty native volume'
[ -d "$engine" ] && [ "$(realpath "$engine")" = "$engine" ] || fail 'unexpected engine directory'
mkdir "$backdir"
backdir_owned=true
run fallocate --length "$image_bytes" "$image"
[ "$(stat -c '%s' "$image")" = "$image_bytes" ] && [ "$(stat -c '%d' "$image")" = "$(stat -c '%d' /)" ] ||
    fail 'loop image must use the private worker root disk'

MKE2FS_CONFIG="$tools/mke2fs.conf"
export MKE2FS_CONFIG
run mke2fs -F -t ext4 -b "$block" -g "$((group_bytes / block))" -I 256 -N 16384 -m 0 -J size=16 \
    -E nodiscard,lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0 "$image" > "$records/mkfs.log" 2>&1
run sync -f "$image"
run dumpe2fs -h "$image" > "$records/initial-superblock.txt"
loop=$(run losetup --find --show --nooverlap --sector-size 512 --direct-io=off "$image")
case "$loop" in /dev/loop*) ;; *) fail 'unexpected loop device';; esac
case "${loop#/dev/loop}" in ''|*[!0-9]*) fail 'unexpected loop device';; esac
loop_name=${loop#/dev/}
[ "$(cat "/sys/class/block/$loop_name/loop/backing_file")" = "$image" ] || fail 'wrong loop backing file'
device_stats="/sys/class/block/$loop_name/stat"
mount -t ext4 -o rw,data=ordered,barrier=1,commit=5,max_batch_time=15000,dioread_lock,nosuid,nodev "$loop" "$volume"
data_mounted=true
data_mount=$(mount_row "$volume")
[ -n "$data_mount" ] || fail 'cache mount identity unavailable'
[ "$(stat -f -c %S "$volume")" = "$block" ] || fail 'live ext4 block size differs'
cat "/proc/fs/ext4/$loop_name/options" > "$records/mount-options.txt"
{
    printf 'boot=%s\npage_bytes=%s\nblock_bytes=%s\nloop=%s\nimage=%s\nimage_bytes=%s\nimage_sectors=%s\n' \
        "$boot" "$page_bytes" "$block" "$loop" "$image" "$image_bytes" "$(stat -c %b "$image")"
    printf 'logical_sector_bytes=%s\nloop_direct_io=%s\nroot_block_bytes=%s\n' \
        "$(cat "/sys/class/block/$loop_name/queue/logical_block_size")" \
        "$(cat "/sys/class/block/$loop_name/loop/dio")" "$(stat -f -c %S /)"
    printf 'cache_inode=%s\nloop_stat=%s\n' "$(stat -c %d:%i "$volume")" "$(cat "$device_stats")"
    printf 'mount %s\n' "$(mount_row "$volume")"
} > "$records/mounted.tmp"
record mounted

IFS= read -r action < "$control/request"
[ "$action" = retire ] || fail 'expected cache retire command'
[ "$(mount_row "$volume")" = "$data_mount" ] || fail 'refusing to sync a different cache mount'
run sync -f "$volume"
sync_stats=$(cat "$device_stats")
unmount_owned "$volume" "$data_mount" || fail 'refusing to retire a different or busy cache mount'
data_mounted=false
unmount_stats=$(cat "$device_stats")
detach_owned || fail 'cache loop device remains attached'
run e2fsck -f -n "$image" > "$records/fsck.txt" 2>&1
run dumpe2fs -h "$image" > "$records/final-superblock.txt"
rm "$image"
rmdir "$backdir"
backdir_owned=false
ack="$records/control-release"
controller="$owner-ext4-cache-retire"
attempts=100
while [ ! -f "$ack" ]; do
    [ "$attempts" -gt 0 ] || fail 'host did not confirm retirement controller removal'
    attempts=$((attempts - 1))
    sleep .25
done
expected=$(printf 'boot=%s\ncontroller=%s\n' "$boot" "$controller")
[ ! -L "$ack" ] && [ "$(cat "$ack")" = "$expected" ] || fail 'invalid retirement controller acknowledgment'
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(mount_row "$control")" = "$control_mount" ] || fail 'refusing to retire a different control mount'
    if unmount_owned "$control" "$control_mount"; then
        control_mounted=false
        break
    fi
    sleep .25
done
"$control_mounted" && fail 'cache control mount remains'
printf 'boot=%s\ncontroller=%s\nsync_stat=%s\nunmount_stat=%s\nclean=true\n' \
    "$boot" "$controller" "$sync_stats" "$unmount_stats" > "$records/retired.tmp"
record retired
