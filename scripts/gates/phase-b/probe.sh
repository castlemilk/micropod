#!/bin/sh
# phase-b/probe.sh — runs inside every workload container the Phase B gate
# (scripts/gates/phase-b.sh) starts.
#
#   sh /g/probe.sh <name> <action> [variant] [offline]
#
# It records what happened as key=value lines in /o/<name>.res, then appends
# `GATE-SENTINEL <name>` and renames the file into place; the harness reads it
# from the host through the workspace share and fails a container whose
# sentinel is missing. Tool output goes to /o/<name>.log. Nothing here sets a
# cache variable: every cache path comes from the engine.
#
# Mounts: /g (the gate's scripts, ro), /f (fixtures, ro), /t (pinned tools,
# ro), /o (results, rw). Env: GTAG (run tag), GEDIT (one-file-change token for
# the go fixture), GHOLD=1 (after the result, wait for /o/<name>.release so
# the host can probe the running container), GPNPM (pnpm version for
# tool-install).
#
# Actions:
#   go-build V        go build -x of fixture go/V: compiles, downloads, ms
#   go-download V     go mod download -x of go/V: proxy gets, downloads
#   go-verify V       go mod verify
#   npm-ci V [offline]       npm ci (--offline) of npm/V, http fetch lines
#   pnpm-install V [offline] pnpm install --frozen-lockfile (--offline) of pnpm/V
#   attack            deliberate writes into every attached store
#   writer            writes into $GOMODCACHE until the VMM dies (crash case)
#   mutate            one trusted overwrite of a gomod file (sabotage only)
#   touch             one trusted mtime change of a gomod file, no byte
#                     written (sabotage only)
#   tool-install      installs pnpm GPNPM into /t (a label-off container)
set -u
NAME=$1
ACTION=$2
VARIANT=${3:-}
MODE=${4:-}
O=/o
RES=$O/$NAME.res
LOG=$O/$NAME.log
TMP=$O/.$NAME.res.$$
MAIN=/tmp/gmain.$$
TAG=${GTAG:-gate}
: >"$LOG"
: >"$TMP"
out() { printf '%s=%s\n' "$1" "$2" >>"$TMP"; }
now_ms() { # ms: date's nanoseconds where it has them (busybox drops %N), else /proc/uptime (10 ms)
    t=$(date +%s%N 2>/dev/null)
    case $t in '' | *[!0-9]*) t= ;; esac
    if [ "${#t}" -ge 16 ]; then echo $((t / 1000000)); else awk '{ printf "%d", $1 * 1000 }' /proc/uptime; fi
}
finish() {
    out end_ms "$(now_ms)"
    printf 'GATE-SENTINEL %s\n' "$NAME" >>"$TMP"
    mv -f "$TMP" "$RES"
    if [ "${GHOLD:-}" = 1 ]; then
        n=0
        while [ ! -e "$O/$NAME.release" ] && [ "$n" -lt 6000 ]; do
            sleep 0.1
            n=$((n + 1))
        done
    fi
    exit 0
}
# run CMD…: the measured command; output in $MAIN and the log.
run() {
    t0=$(now_ms)
    "$@" >"$MAIN" 2>&1
    rc=$?
    t1=$(now_ms)
    { echo "+ $*"; cat "$MAIN"; echo "+ rc=$rc ms=$((t1 - t0))"; } >>"$LOG"
    out rc "$rc"
    out ms "$((t1 - t0))"
}
count() { grep -c "$1" "$MAIN" 2>/dev/null | tr -d ' ' || true; }
co() {
    CO=/tmp/co-$NAME
    if ! { rm -rf "$CO" && mkdir -p "$CO" && cp -R "/f/$1/." "$CO/" && cd "$CO"; }; then
        out rc checkout-failed
        finish
    fi
}
# fs_of PATH: "<fstype> <mount root> <source>" of the mount that covers PATH.
fs_of() {
    awk -v p="$1" '{ mp = $5; gsub(/\\040/, " ", mp)
        if ((p == mp || index(p, mp "/") == 1 || mp == "/") && length(mp) >= bl) {
            bl = length(mp); root = $4
            for (i = 7; i <= NF; i++) if ($i == "-") { fs = $(i + 1); src = $(i + 2); break } } }
        END { print fs " " root " " src }' /proc/self/mountinfo
}

out name "$NAME"
out action "$ACTION"
out uid "$(id -u)"
out start_ms "$(now_ms)"
for k in GOMODCACHE GOCACHE GOFLAGS npm_config_cache pnpm_config_store_dir npm_config_store_dir MICROPOD_CACHE_TRUST; do
    eval "v=\${$k-__unset__}"
    # shellcheck disable=SC2154 # v is assigned by the eval
    out "env.$k" "$v"
done

case $ACTION in
go-build)
    co "go/$VARIANT"
    [ -n "${GEDIT:-}" ] && printf 'package lib\n\n// Edit is the one-file change.\nconst Edit = "%s"\n' "$GEDIT" >lib/edit.go
    out version "$(go version 2>&1)"
    run go build -x -o /tmp/gapp .
    out compiles "$(count '/compile ')"
    out downloads "$(count '^go: downloading')"
    out app "$(/tmp/gapp 2>&1 | head -1 | tr -d '\n' | cut -c1-60)"
    out goenv.GOFLAGS "$(go env GOFLAGS 2>/dev/null)"
    ;;
go-download)
    co "go/$VARIANT"
    run go mod download -x
    out gets "$(count '^# get ')"
    out downloads "$(count '^go: downloading')"
    ;;
go-verify)
    co "go/$VARIANT"
    run go mod verify
    out verified "$(count '^all modules verified')"
    ;;
npm-ci)
    co "npm/$VARIANT"
    if [ "$MODE" = offline ]; then
        run npm ci --offline --no-audit --no-fund --no-update-notifier --loglevel=http
    else
        run npm ci --no-audit --no-fund --no-update-notifier --loglevel=http
    fi
    out http_fetch "$(count 'http fetch')"
    out cache_miss "$(count 'cache miss')"
    out installed "$(find node_modules -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
    ;;
pnpm-install)
    P=/t/pnpm10/bin/pnpm
    co "pnpm/$VARIANT"
    if [ "$MODE" = offline ]; then
        run "$P" install --frozen-lockfile --offline --reporter=append-only
    else
        run "$P" install --frozen-lockfile --reporter=append-only
    fi
    out reused "$(grep -o 'reused [0-9]*' "$MAIN" | tail -1 | cut -d' ' -f2)"
    out downloaded "$(grep -o 'downloaded [0-9]*' "$MAIN" | tail -1 | cut -d' ' -f2)"
    out store_path "$("$P" store path 2>/dev/null)"
    ;;
tool-install)
    run npm i -g --prefix /t/pnpm10 "pnpm@${GPNPM:-10.34.9}"
    out pnpm "$(/t/pnpm10/bin/pnpm --version 2>/dev/null)"
    ;;
attack)
    # Every way a process with write access to a store could change it. Each
    # op is checked from this container's own view: "landed" means the write
    # took effect here (in a copy-on-write view it never reaches the store),
    # anything else is the error the kernel gave.
    landed=0 tried=0
    try() { # try LABEL OP CMD…: run a shell snippet, record landed/failed
        lbl=$1 op=$2
        shift 2
        # Only the ops on the attached stores count as tries: the alias volume
        # and the remounts are expected to fail.
        case $lbl in alias | fs) ;; *) tried=$((tried + 1)) ;; esac
        if err=$(sh -c "$*" 2>&1); then
            out "attack.$lbl.$op" landed
            case $lbl in alias | fs) ;; *) landed=$((landed + 1)) ;; esac
        else
            out "attack.$lbl.$op" "failed:$(echo "$err" | tail -1 | tr '\n=' '  ' | cut -c1-80)"
        fi
    }
    attack_store() { # attack_store LABEL DIR
        L=$1 D=$2
        out "attack.$L.dir" "$D"
        if [ -z "$D" ] || [ "$D" = __unset__ ] || [ ! -d "$D" ]; then
            out "attack.$L.present" no
            return 0
        fi
        out "attack.$L.present" yes
        out "attack.$L.fs" "$(fs_of "$D")"
        find "$D" -type f 2>/dev/null | sort | head -12 >/tmp/victims
        out "attack.$L.victims" "$(wc -l </tmp/victims | tr -d ' ')"
        v() { sed -n "${1}p" /tmp/victims; }
        try "$L" create "printf planted >'$D/gate-planted-$TAG' && [ \"\$(cat '$D/gate-planted-$TAG')\" = planted ]"
        try "$L" fill "dd if=/dev/zero of='$D/gate-fill-$TAG' bs=1M count=8 2>/dev/null && [ \$(stat -c %s '$D/gate-fill-$TAG') = 8388608 ]"
        try "$L" mkdir "mkdir '$D/gate-dir-$TAG' && [ -d '$D/gate-dir-$TAG' ]"
        try "$L" symlink "ln -s /etc/passwd '$D/gate-symlink-$TAG' && [ -L '$D/gate-symlink-$TAG' ]"
        F=$(v 1)
        [ -n "$F" ] && try "$L" overwrite "printf GATE >'$F' && [ \"\$(head -c 4 '$F')\" = GATE ]"
        F=$(v 2)
        [ -n "$F" ] && try "$L" append "printf GATE >>'$F' && [ \"\$(tail -c 4 '$F')\" = GATE ]"
        F=$(v 3)
        [ -n "$F" ] && try "$L" truncate ": >'$F' && [ ! -s '$F' ]"
        F=$(v 4)
        [ -n "$F" ] && try "$L" delete "rm -f '$F' && [ ! -e '$F' ]"
        F=$(v 5)
        [ -n "$F" ] && try "$L" rename "mv '$F' '$F.gate' && [ -e '$F.gate' ] && [ ! -e '$F' ]"
        F=$(v 6)
        [ -n "$F" ] && try "$L" chmod "chmod 0600 '$F' && [ \$(stat -c %a '$F') = 600 ]"
        F=$(v 7)
        [ -n "$F" ] && try "$L" chown "chown 4321:4321 '$F' && [ \$(stat -c %u '$F') = 4321 ]"
        F=$(v 8)
        [ -n "$F" ] && try "$L" touch "{ touch -d '2001-01-01 00:00:00' '$F' 2>/dev/null || touch -t 200101010000 '$F'; } && [ \$(stat -c %Y '$F') -lt 1000000000 ]"
        F=$(v 9)
        [ -n "$F" ] && try "$L" hardlink "ln '$F' '$D/gate-hardlink-$TAG' && [ -e '$D/gate-hardlink-$TAG' ]"
        # Last: the whole first subtree of the store.
        S1=$(find "$D" -mindepth 1 -maxdepth 1 -type d ! -name "gate-dir-$TAG" 2>/dev/null | sort | head -1)
        [ -n "$S1" ] && try "$L" wipe "rm -rf '$S1' && [ ! -e '$S1' ]"
    }
    attack_store gomod "${GOMODCACHE:-}"
    attack_store gobuild "${GOCACHE:-}"
    attack_store npm "${npm_config_cache:-}"
    attack_store pnpm "${pnpm_config_store_dir:-}"
    # A read-only alias volume of the same store, when the harness mounted one.
    if [ -d /alias ]; then
        out attack.alias.fs "$(fs_of /alias)"
        try alias create "printf planted >/alias/gate-planted-$TAG"
        F=$(find /alias -type f 2>/dev/null | sort | head -1)
        [ -n "$F" ] && try alias overwrite "printf GATE >'$F'"
        try alias remount "mount -o remount,rw /alias"
    fi
    try fs remount-cache "mount -o remount,rw /micropod/cache"
    out attack.tried "$tried"
    out attack.landed "$landed"
    out attack.not_landed "$(grep -E '^attack\.(gomod|gobuild|npm|pnpm)\.[a-z]+=failed' "$TMP" | cut -d= -f1 | tr '\n' ' ')"
    out rc 0
    ;;
writer)
    # Writes real bytes into the gomod store until the VMM is killed under it.
    D=${GOMODCACHE:-}
    [ -n "$D" ] && [ -d "$D" ] || { out rc no-gomod; finish; }
    W=$D/cache/download/gate.example/crash/@v
    mkdir -p "$W" || { out rc mkdir-failed; finish; }
    printf 'started %s\n' "$(fs_of "$D")" >"$O/$NAME.started"
    i=0
    while :; do
        i=$((i + 1))
        dd if=/dev/urandom of="$W/v0.0.$i.zip" bs=64k count=4 2>/dev/null
        printf '%s\n' "$i" >"$O/$NAME.progress"
        sleep 0.05
    done
    ;;
mutate)
    D=${GOMODCACHE:-}
    F=$(find "$D/cache/download" -type f -name '*.mod' 2>/dev/null | sort | head -1)
    if [ -n "$F" ] && printf '// gate sabotage\n' >>"$F"; then out mutated "$F"; out rc 0; else out rc mutate-failed; fi
    ;;
touch)
    D=${GOMODCACHE:-}
    F=$(find "$D/cache/download" -type f -name '*.mod' 2>/dev/null | sort | head -1)
    if [ -n "$F" ] && touch -d '2001-01-01 00:00:00' "$F"; then out touched "$F"; out rc 0; else out rc touch-failed; fi
    ;;
*)
    out rc unknown-action
    ;;
esac
finish
