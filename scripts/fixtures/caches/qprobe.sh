#!/bin/sh
# qprobe.sh — runs inside every container that scripts/e2e_hvf_caches.sh starts.
#
#   sh /q/qprobe.sh <name> <tool> <action> [variant]
#
# It copies a fixture to a fresh checkout, runs one package-manager command and
# records what happened as key=value lines in /qr/<name>.res, then appends the
# sentinel line `QUAL-SENTINEL <name>` and renames the file into place. The
# harness reads that file from the host through the workspace share and never
# trusts container stdout (it was once lost under CPU saturation). Tool output
# goes to /qr/<name>.log.
#
# Mounts (from the harness): /q (this script, ro), /qf (fixtures, ro),
# /qt (harness-installed pnpm<major>/, yarn4/, corepack/ and yarn1/, ro),
# /qr (results, rw 0777).
# Env: QCO checkout dir (default /tmp/qco/<name>), QEDIT one-file-change token,
#      QWAIT barrier file in /qr to wait for, QDROP uid that a root entrypoint
#      drops to with busybox su before the tool runs, QPNPM pnpm major,
#      QHOLD seconds to keep the container (and its cache units) after the
#      result is written.
# Nothing here sets a cache variable: every cache path comes from the engine
# (or from the harness's QUAL_MANUAL_WIRING arguments).
set -u
NAME=$1
TOOL=$2
ACTION=$3
VARIANT=${4:-a}
R=/qr
RES=$R/$NAME.res
LOG=$R/$NAME.log
TMP=$R/.$NAME.res.$$
MAIN=/tmp/qmain.$$
MK=/tmp/qmarker.$$

# A root entrypoint that drops privileges (the su-exec pattern): the cache
# environment was planned for the container user (root) and the tool runs as
# QDROP. busybox su keeps the environment apart from HOME/SHELL/USER/LOGNAME.
if [ -n "${QDROP:-}" ] && [ "$(id -u)" = 0 ]; then
    adduser -D -u "$QDROP" qdrop >/dev/null 2>&1 || true
    exec su qdrop -s /bin/sh -c "QDROP= QDROPPED_FROM=0 exec sh /q/qprobe.sh '$NAME' '$TOOL' '$ACTION' '$VARIANT'"
fi

: >"$LOG"
: >"$TMP"
out() { printf '%s=%s\n' "$1" "$2" >>"$TMP"; }
finish() {
    out end "$(date +%s)"
    printf 'QUAL-SENTINEL %s\n' "$NAME" >>"$TMP"
    mv -f "$TMP" "$RES"
    echo "QUAL-SENTINEL $NAME"
    [ -n "${QHOLD:-}" ] && sleep "$QHOLD"
    exit 0
}
count() { grep -c "$1" "$MAIN" 2>/dev/null | tr -d ' ' || true; }
# run_main CMD…: the measured command; its output is counted from $MAIN.
run_main() {
    if [ -n "${QSTREAM:-}" ]; then
        # The kill -9 test watches progress from the host while this runs.
        "$@" >"$R/$NAME.progress" 2>&1
        rc=$?
        cp "$R/$NAME.progress" "$MAIN"
    else
        "$@" >"$MAIN" 2>&1
        rc=$?
    fi
    { echo "+ $*"; cat "$MAIN"; echo "+ rc=$rc"; } >>"$LOG"
    out rc "$rc"
    # Whole words only: `go build -x` lists source files such as eaccess.go.
    out eacces "$(grep -ciE '(^|[^a-z_])(eacces|eperm)([^a-z_.]|$)|permission denied|operation not permitted|readonly database' "$MAIN" | tr -d ' ')"
    return 0
}
# The store a path really lives in: mountinfo root of the longest mount point
# covering it, plus the rest of the path ("rootfs:<path>" when on no bind).
qstore() {
    p=$(readlink -f "$1" 2>/dev/null || echo "$1")
    awk -v p="$p" '
        { mp = $5; gsub(/\\040/, " ", mp)
          if (mp != "/" && (p == mp || index(p, mp "/") == 1) && length(mp) > bl) { bl = length(mp); root = $4; best = mp } }
        END { if (bl == 0) print "rootfs:" p; else { r = root substr(p, bl + 1); sub(/^\/\//, "/", r); print r } }' /proc/self/mountinfo
}
# scan <label> <dir>: owner-only entries (no group or other bits at all) and
# entries without o+w, counted by mode string so BusyBox and GNU agree.
scan() {
    [ -d "$2" ] || { out "scan.$1.total" absent; return 0; }
    find "$2" ! -type l -exec stat -c '%a %u %F %n' {} + 2>/dev/null | awk -v L="$1" -v me="$(id -u)" -v lf="$LOG" '
        { m = $1; n = length(m); o = substr(m, n, 1); g = substr(m, n - 1, 1); total++
          if ($2 == me) mine++
          if (g == "0" && o == "0") { oo++; if (oo <= 5) print "OWNER_ONLY " $0 >> lf }
          ow = index("2367", o) > 0
          if ($3 == "directory") { dirs++; if (!ow) { dnw++; if (dnw <= 3) print "DIR_NO_O+W " $0 >> lf } }
          else if (!ow) fnw++ }
        END { printf "scan.%s.total=%d\nscan.%s.dirs=%d\nscan.%s.mine=%d\nscan.%s.owner_only=%d\nscan.%s.dir_no_ow=%d\nscan.%s.file_no_ow=%d\n", L, total, L, dirs, L, mine, L, oo, L, dnw, L, fnw }' >>"$TMP"
}
# stats <label> <dir>: where the store is, what this uid added, the scan.
stats() {
    out "path.$1" "$2"
    out "store.$1" "$(qstore "$2")"
    if [ -n "$2" ] && [ -d "$2" ]; then
        out "new_by_me.$1" "$(find "$2" -newer "$MK" -user "$(id -u)" -type f 2>/dev/null | wc -l | tr -d ' ')"
        out "files.$1" "$(find "$2" -type f 2>/dev/null | wc -l | tr -d ' ')"
        scan "$1" "$2"
        # Files this uid cannot read: owner-only is not the only way to lose
        # a shared entry (a tool that keeps a tarball's 0640 mode does too).
        find "$2" -type f ! -perm -004 2>/dev/null | while read -r f; do [ -r "$f" ] || echo "$f"; done >"/tmp/qur.$$"
        out "unreadable.$1" "$(wc -l <"/tmp/qur.$$" | tr -d ' ')"
        head -3 "/tmp/qur.$$" | while read -r f; do echo "UNREADABLE $(stat -c '%a %u' "$f") $f"; done >>"$LOG"
    else
        out "new_by_me.$1" absent
        out "files.$1" absent
        out "unreadable.$1" absent
    fi
}
co() {
    QCO=${QCO:-/tmp/qco/$NAME}
    rm -rf "$QCO" && mkdir -p "$QCO" && cp -R "/qf/$1/." "$QCO/" && cd "$QCO" || {
        out rc checkout-failed
        finish
    }
    out checkout "$QCO"
}

if [ -n "${QWAIT:-}" ]; then # barrier for the concurrency section
    n=0
    while [ ! -e "$R/$QWAIT" ] && [ "$n" -lt 3000 ]; do
        sleep 0.1
        n=$((n + 1))
    done
    out barrier_ticks "$n"
fi
out name "$NAME"
out tool "$TOOL"
out action "$ACTION"
out variant "$VARIANT"
out uid "$(id -u)"
out gid "$(id -g)"
out dropped_from "${QDROPPED_FROM:-}"
out home "${HOME:-}"
out umask "$(umask)"
out start "$(date +%s)"
for k in HOME GOMODCACHE GOCACHE GOFLAGS GOPATH npm_config_cache NPM_CONFIG_CACHE pnpm_config_store_dir npm_config_store_dir \
    YARN_CACHE_FOLDER YARN_GLOBAL_FOLDER PIP_CACHE_DIR UV_CACHE_DIR UV_LINK_MODE COREPACK_HOME CARGO_HOME \
    MICROPOD_CACHE MICROPOD_CACHE_SCOPE XDG_CACHE_HOME XDG_DATA_HOME; do
    eval "v=\${$k-__unset__}"
    out "env.$k" "$v"
done
# Every ext4 bind (the stores live on the guest disk), as mount.<point>=<root>.
awk '{ for (i = 7; i <= NF; i++) if ($i == "-") { fs = $(i + 1); break }
       if (fs == "ext4" && $5 != "/" && $5 !~ /^\/etc\// && $5 !~ /^\/dev\//) print "mount." $5 "=" $4 }' /proc/self/mountinfo >>"$TMP"
# BusyBox `find -newer` compares whole seconds: start the tool in the second
# after the marker's, so every entry it writes is strictly newer.
touch "$MK"
mks=$(date +%s)
while [ "$(date +%s)" = "$mks" ]; do sleep 0.05; done

case $TOOL in
go)
    if [ "$ACTION" = prewarm ]; then
        cd /prewarm/go || { out rc no-prewarm; finish; }
    else
        co "go/$VARIANT"
        [ -n "${QEDIT:-}" ] && printf 'package lib\n\n// Edit is the one-file change.\nconst Edit = "%s"\n' "$QEDIT" >lib/edit.go
    fi
    out version "$(go version 2>&1)"
    case $ACTION in
    build | prewarm) run_main go build -x -o "/tmp/qapp.$$" . ;;
    verify)
        run_main go mod verify
        out verify_ok "$(count '^all modules verified')"
        ;;
    download) run_main go mod download -x ;;
    count | env) out rc 0 ;;
    *) out rc unknown-action ;;
    esac
    out compiles "$(count '/compile ')"
    out downloads "$(count '^go: downloading')"
    GC=$(go env GOCACHE 2>/dev/null)
    GM=$(go env GOMODCACHE 2>/dev/null)
    out goenv.GOCACHE "$GC"
    out goenv.GOMODCACHE "$GM"
    out goenv.GOFLAGS "$(go env GOFLAGS 2>/dev/null)"
    stats gobuild "$GC"
    stats gomod "$GM"
    out dirs_not_0777.gobuild "$(find "$GC" -type d ! -perm -0777 2>/dev/null | wc -l | tr -d ' ')"
    out dirs_not_0777.gomod_download "$(find "$GM/cache/download" -type d ! -perm -0777 2>/dev/null | wc -l | tr -d ' ')"
    ;;
npm)
    if [ "$ACTION" = prewarm ]; then cd /prewarm/npm || { out rc no-prewarm; finish; }; else co "npm/$VARIANT"; fi
    out version "$(npm --version 2>/dev/null)"
    case $ACTION in
    ci) run_main npm ci --no-audit --no-fund --no-update-notifier ;;
    ci-offline | prewarm) run_main npm ci --offline --no-audit --no-fund --no-update-notifier ;;
    cache-verify) run_main npm cache verify ;;
    count | env) out rc 0 ;;
    *) out rc unknown-action ;;
    esac
    out npm_unknown_env_warn "$(count 'Unknown env config')"
    stats npm "$(npm config get cache 2>/dev/null)"
    ;;
pnpm)
    P=/qt/pnpm${QPNPM:-10}/bin/pnpm
    co "pnpm/$VARIANT"
    out version "$($P --version 2>/dev/null)"
    case $ACTION in
    install) run_main "$P" install --frozen-lockfile --reporter=append-only ;;
    install-offline) run_main "$P" install --frozen-lockfile --offline --reporter=append-only ;;
    store-status)
        run_main "$P" install --frozen-lockfile --reporter=append-only
        "$P" store status >>"$LOG" 2>&1
        out store_status_rc "$?"
        ;;
    *) out rc unknown-action ;;
    esac
    out reused "$(grep -o 'reused [0-9]*' "$MAIN" | tail -1 | cut -d' ' -f2)"
    out downloaded "$(grep -o 'downloaded [0-9]*' "$MAIN" | tail -1 | cut -d' ' -f2)"
    out project_store "$([ -e "$QCO/.pnpm-store" ] && echo present || echo none)"
    SP=$($P store path 2>/dev/null)
    stats pnpm "$SP"
    out pnpm_index_db_mode "$(stat -c %a "$SP/index.db" 2>/dev/null || echo absent)"
    ;;
yarn1)
    # Node 26 images no longer ship Yarn 1: an image without one uses the
    # release node:22-alpine carried, from the qualification tool volume. Its
    # cache location is Yarn's own default either way.
    command -v yarn >/dev/null 2>&1 || PATH="/qt/yarn1/bin:$PATH"
    export PATH
    co "yarn1/$VARIANT"
    out version "$(yarn --version 2>/dev/null)"
    case $ACTION in
    install) run_main yarn install --frozen-lockfile --non-interactive --ignore-scripts --no-progress ;;
    install-offline) run_main yarn install --offline --frozen-lockfile --non-interactive --ignore-scripts --no-progress ;;
    *) out rc unknown-action ;;
    esac
    stats yarn "$(yarn cache dir 2>/dev/null)"
    ;;
yarn4)
    Y=/qt/yarn4/bin/yarn
    if [ "$ACTION" = zero ]; then co yarn4-zero-install; else co "yarn4-global/$VARIANT"; fi
    out version "$($Y --version 2>/dev/null)"
    manifest() { find . -type f ! -path './node_modules/*' ! -name '*.flock' ! -name '*.tmp' ! -name install-state.gz \
        ! -path './.yarn/cache/.gitignore' -exec md5sum {} + 2>/dev/null | sort; }
    case $ACTION in
    install) run_main "$Y" install --immutable ;;
    install-nonet)
        export YARN_ENABLE_NETWORK=0
        run_main "$Y" install --immutable
        ;;
    zero)
        manifest >/tmp/qman.before
        export YARN_ENABLE_NETWORK=0
        run_main "$Y" install --immutable
        manifest >/tmp/qman.after
        out changed_files "$(sort /tmp/qman.before /tmp/qman.after | uniq -u | wc -l | tr -d ' ')"
        ;;
    *) out rc unknown-action ;;
    esac
    out cache_folder "$($Y config get cacheFolder 2>/dev/null)"
    stats yarnberry "$($Y config get globalFolder 2>/dev/null)"
    ;;
pip)
    co "pip/$VARIANT"
    python3 -m venv "/tmp/qv.$$" >>"$LOG" 2>&1
    PY=/tmp/qv.$$/bin/python
    out version "$($PY -m pip --version 2>/dev/null)"
    case $ACTION in
    install) run_main "$PY" -m pip install --disable-pip-version-check --no-binary six -r requirements.txt ;;
    *) out rc unknown-action ;;
    esac
    out using_cached "$(count 'Using cached')"
    out downloading "$(count 'Downloading')"
    out cache_disabled_warn "$(count 'cache has been disabled')"
    stats pip "$($PY -m pip cache dir 2>/dev/null)"
    ;;
uv)
    co "uv/$VARIANT"
    out version "$(uv --version 2>/dev/null)"
    uv venv --offline --python /usr/local/bin/python3 "/tmp/qv.$$" >>"$LOG" 2>&1
    case $ACTION in
    install) run_main uv pip install --python "/tmp/qv.$$/bin/python" --no-binary six -r requirements.txt ;;
    install-offline) run_main uv pip install --offline --python "/tmp/qv.$$/bin/python" --no-binary six -r requirements.txt ;;
    *) out rc unknown-action ;;
    esac
    stats uv "$(uv cache dir 2>/dev/null)"
    ;;
cargo)
    co "cargo/$VARIANT"
    CH=${CARGO_HOME:-$HOME/.cargo}
    out version "$(cargo -V 2>/dev/null)"
    out lock_ino_before "$(stat -c %i "$CH/.package-cache" 2>/dev/null || echo absent)"
    out lock_mutate_ino_before "$(stat -c %i "$CH/.package-cache-mutate" 2>/dev/null || echo absent)"
    export CARGO_TARGET_DIR=/tmp/qtarget.$$
    case $ACTION in
    fetch) run_main cargo fetch --locked ;;
    build-offline) run_main cargo build --offline --locked ;;
    *) out rc unknown-action ;;
    esac
    out blocking "$(count 'Blocking waiting for file lock on package cache')"
    out lock_ino_after "$(stat -c %i "$CH/.package-cache" 2>/dev/null || echo absent)"
    out lock_mutate_ino_after "$(stat -c %i "$CH/.package-cache-mutate" 2>/dev/null || echo absent)"
    out lock_type "$(stat -c %F "$CH/.package-cache" 2>/dev/null || echo absent)"
    stats cargo "$CH/registry"
    out store.cargo_git "$(qstore "$CH/git")"
    out store.cargo_lock "$(qstore "$CH/.package-cache")"
    ;;
corepack)
    # The qualification tool volume supplies Corepack on Node 26.
    PATH="/qt/corepack/bin:$PATH"
    export PATH
    cd /tmp || exit 1
    if [ "$ACTION" = prewarm ]; then cd /prewarm/npm || { out rc no-prewarm; finish; }; fi
    CH=${COREPACK_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/node/corepack}
    out version "$(corepack --version 2>/dev/null)"
    export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
    case $ACTION in
    prepare) run_main corepack pnpm@9.15.9 --version ;;
    prepare-yarn) run_main corepack yarn@1.22.19 --version ;;
    nonet | prewarm)
        export COREPACK_ENABLE_NETWORK=0
        run_main corepack pnpm@9.15.9 --version
        ;;
    nonet-yarn)
        export COREPACK_ENABLE_NETWORK=0
        run_main corepack yarn@1.22.19 --version
        ;;
    *) out rc unknown-action ;;
    esac
    out reported "$(tail -1 "$MAIN" 2>/dev/null)"
    stats corepack "$CH"
    ;;
env)
    out rc 0
    ;;
*)
    out rc unknown-tool
    ;;
esac
finish
