#!/bin/sh
# Run once in the trusted tools bank of a disposable guest, after Docker work is idle.
set -eu
umask 077

workspace=${MICROPOD_ENGINE_WORKSPACE:?}
request="$workspace/.release-lifecycle.request"
receipt="$workspace/.release-lifecycle.done"
deadline=$(($(cut -d . -f 1 /proc/uptime) + 300))
while [ ! -f "$request" ]; do
    [ "$(cut -d . -f 1 /proc/uptime)" -lt "$deadline" ] || exit 0
    sleep 0.1
done
[ ! -L "$request" ] && [ "$(stat -c %s "$request")" = 17 ] && [ ! -e "$receipt" ] && [ ! -L "$receipt" ]
IFS= read -r token < "$request"
case "$token" in ''|*[!0-9a-f]*) exit 1 ;; esac
[ "${#token}" -eq 16 ]

scratch=$(mktemp -d /run/mp-release.XXXXXX)
mount_a="$scratch/a"
mount_b="$scratch/b"
ctl="$scratch/fusectl"
leaf="release-lifecycle-$token"
fixture="$workspace/$leaf"
reason=invalid_workspace
have_a=0 have_b=0 have_ctl=0 have_fixture=0 restore_workspace=0
mode=$(cat /sys/module/virtiofs/parameters/workspace_async_release)

workspace_device() {
    awk -v path="$workspace" '
        $5 == path {
            for (i = 7; i <= NF; i++) {
                if ($i != "-") continue
                if ($(i+1) == "virtiofs" && $(i+2) == "workspace" && $3 ~ /^[0-9]+:[0-9]+$/) good = $3
                break
            }
            seen++
        }
        END { if (seen == 1 && good != "") print good; else if (seen != 0) exit 1 }
    ' /proc/self/mountinfo
}

restore_mount() {
    present=$(workspace_device) || return 1
    [ -z "$present" ] || return 1
    timeout 8 mount -t virtiofs -o nosuid,nodev workspace "$workspace"
}

cleanup() {
    code=$?
    trap - EXIT HUP INT TERM
    set +e
    exec 4<&-
    if [ "$have_b" = 1 ]; then timeout 8 umount "$mount_b" || code=1; fi
    if [ "$have_a" = 1 ]; then timeout 8 umount "$mount_a" || code=1; fi
    if [ "$have_ctl" = 1 ]; then timeout 8 umount "$ctl" || code=1; fi
    if [ "$restore_workspace" = 1 ]; then
        if actual=$(workspace_device) && [ -n "$actual" ]; then timeout 8 umount "$workspace" || code=1; fi
        restore_mount || code=1
    fi
    recovered=$(workspace_device) || code=1
    if [ "$have_fixture" = 1 ] && [ -n "$recovered" ]; then rm -r "$fixture" || code=1; fi
    details=
    if [ -f "$scratch/details" ]; then details=$(cat "$scratch/details"); fi
    rm -f "$scratch/details" "$scratch/expected" "$scratch/abort-read.err"
    rmdir "$mount_a" "$mount_b" "$ctl" "$scratch" || code=1
    result=$({
        printf 'token=%s\nmode=%s\nexit=%s\nstep=%s\nworkspace_device_final=%s\n' "$token" "$mode" "$code" "$reason" "$recovered"
        if [ -n "$details" ]; then printf '%s\n' "$details"; fi
    })
    printf '[workspace-release-test]\n%s\n' "$result"
    if [ -n "$recovered" ]; then
        pending=$(mktemp "$workspace/.release-lifecycle.XXXXXX")
        printf '%s\n' "$result" > "$pending" && mv "$pending" "$receipt" || { rm -f "$pending"; code=1; }
    fi
    exit "$code"
}

trap cleanup EXIT
trap 'reason=interrupted; exit 1' HUP INT TERM
initial=$(workspace_device)
[ -n "$initial" ]
case "$mode" in N|Y) ;; *) exit 1 ;; esac
mkdir "$mount_a" "$mount_b" "$ctl" "$fixture"
have_fixture=1
printf 'workspace-release-%s\n' "$token" > "$scratch/expected"
dd if="$scratch/expected" of="$fixture/original" conv=fsync status=none
ln "$fixture/original" "$fixture/link"

printf 'workspace_device_initial=%s\n' "$initial" > "$scratch/details"
reason=mount_same_tag_again
timeout 8 mount -t virtiofs -o nosuid,nodev workspace "$mount_a"
have_a=1
printf 'same_tag_mount=1\n' >> "$scratch/details"
reason=mount_bind
timeout 8 mount --bind "$fixture" "$mount_b"
have_b=1
printf 'bind_mount=1\n' >> "$scratch/details"

reason=hardlink_metadata
printf 'before_revalidation_original=%s\nbefore_revalidation_link=%s\n' \
    "$(stat -c '%d:%i:%h' "$fixture/original")" "$(stat -c '%d:%i:%h' "$fixture/link")" >> "$scratch/details"
# Both cached aliases must be past the workspace's existing 20ms lifetime.
sleep 0.05
for view in original same_tag bind; do
    case "$view" in
        original) directory=$fixture ;;
        same_tag) directory="$mount_a/$leaf" ;;
        bind) directory=$mount_b ;;
    esac
    ident_original=$(stat -c '%d:%i:%h' "$directory/original")
    ident_link=$(stat -c '%d:%i:%h' "$directory/link")
    printf '%s_original=%s\n%s_link=%s\n' "$view" "$ident_original" "$view" "$ident_link" >> "$scratch/details"
done
for directory in "$fixture" "$mount_a/$leaf" "$mount_b"; do
    identity=$(stat -c '%d:%i:%h' "$directory/original")
    [ "$identity" = "$(stat -c '%d:%i:%h' "$directory/link")" ]
    case "$identity" in *:2) ;; *) exit 1 ;; esac
    cmp "$scratch/expected" "$directory/original"
    cmp "$scratch/expected" "$directory/link"
done

reason=held_and_replaced_handles
exec 4< "$mount_b/link"
printf 'atomic-replacement\n' > "$fixture/next"
mv "$fixture/next" "$fixture/link"
[ "$(cat <&4)" = "$(cat "$scratch/expected")" ]
exec 4<&-
sleep 0.05
[ "$(cat "$mount_a/$leaf/link")" = atomic-replacement ]
cmp "$scratch/expected" "$mount_b/original"

reason=concurrent_open_read_close
children=
for slot in 1 2 3 4 5 6 7 8; do
    (
        dd if="$scratch/expected" of="$mount_b/writer-$slot" conv=fsync status=none
        cmp "$scratch/expected" "$mount_a/$leaf/writer-$slot"
        n=0
        while [ "$n" -lt 64 ]; do
            cmp "$scratch/expected" "$mount_b/original"
            n=$((n + 1))
        done
    ) &
    children="$children $!"
done
failed=0
for child in $children; do wait "$child" || failed=1; done
[ "$failed" = 0 ]
printf 'concurrent_readers=8\nreads_per_job=64\nfsynced_writers=8\n' >> "$scratch/details"

reason=last_mount_unmount_and_remount
timeout 8 umount "$mount_b"
have_b=0
timeout 8 umount "$mount_a"
have_a=0
cmp "$scratch/expected" "$fixture/original"
timeout 8 umount "$workspace"
restore_workspace=1
[ -z "$(workspace_device)" ]
restore_mount
restore_workspace=0
first_remount=$(workspace_device)
[ -n "$first_remount" ]
cmp "$scratch/expected" "$fixture/original"
printf 'workspace_device_remounted=%s\n' "$first_remount" >> "$scratch/details"

reason=abort_connection_with_held_handle
timeout 8 mount -t fusectl none "$ctl"
have_ctl=1
major=${first_remount%:*}
minor=${first_remount#*:}
connection=$((major * 1048576 + minor))
abort="$ctl/$connection/abort"
[ -w "$abort" ]
exec 4< "$fixture/original"
printf '1\n' > "$abort"
restore_workspace=1
if timeout 5 dd bs=1 count=1 <&4 > /dev/null 2> "$scratch/abort-read.err"; then exit 1; fi
exec 4<&-
grep -Eq 'Transport endpoint is not connected|Input/output error|Software caused connection abort' "$scratch/abort-read.err"
timeout 8 umount "$workspace"
[ -z "$(workspace_device)" ]
restore_mount
restore_workspace=0
cmp "$scratch/expected" "$fixture/original"
printf 'aborted_connection=%s\nheld_read_failed_after_abort=1\n' "$connection" >> "$scratch/details"
reason=pass
