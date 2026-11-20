#!/bin/bash
# The inner single-quoted programs expand their arguments in Linux.
# shellcheck disable=SC2016
# Register an optional OCI runtime on this Micropod worker without restarting Docker.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cli="${MICROPOD_BIN:-$root/.build/release/micropod}"
status="$("$cli" ci start)"
endpoint="$(jq -er .endpoint <<< "$status")"
worker="$(jq -er .worker <<< "$status")"
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
docker=(docker --host "$endpoint")
"${docker[@]}" info --format '{{json .Labels}}' | jq -e --arg w "io.micropod.ci.worker=$worker" 'index($w) != null' >/dev/null
version=1.31
expected=f54fd58603ae031aa7a255af550bcffb035f28058aa1a971e6691b53f7f5a32e
dst="/var/lib/micropod/oci/crun-$version-arm64"
helper=alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
guest=(run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges
       -v /etc/docker:/config -v /var/lib/micropod/oci:/oci)
"${docker[@]}" "${guest[@]}" "$helper" sh -ec '
    if test -e /config/daemon.json; then cat /config/daemon.json; fi
' > "$tmp/original"
if [[ -s "$tmp/original" ]]; then
    jq -e --arg p "$dst" '.runtimes["micropod-crun"] == null or .runtimes["micropod-crun"] == {path:$p}' \
        "$tmp/original" >/dev/null || { echo 'Existing micropod-crun runtime uses another configuration' >&2; exit 1; }
    cp "$tmp/original" "$tmp/base"
else
    echo '{}' > "$tmp/base"
fi
jq --arg p "$dst" '.runtimes["micropod-crun"] = {path:$p}' "$tmp/base" > "$tmp/new"
registered() {
    "${docker[@]}" info --format '{{json .Runtimes}}' | jq -e --arg p "$dst" '.["micropod-crun"].path == $p' >/dev/null
}
if jq -e --arg p "$dst" '.runtimes["micropod-crun"].path == $p' "$tmp/base" >/dev/null && registered && \
   "${docker[@]}" "${guest[@]}" --runtime micropod-crun "$helper" sh -ec \
       'echo "$1  /oci/$2" | sha256sum -c - >/dev/null' sh "$expected" "${dst##*/}"; then
    echo "Verified micropod-crun $version on worker $worker."
    exit 0
fi
if [[ -n "${MICROPOD_CRUN_FILE:-}" ]]; then
    binary="$MICROPOD_CRUN_FILE"
else
    binary="$tmp/crun"
    curl --fail --location --silent --show-error --retry 2 \
        "https://github.com/containers/crun/releases/download/$version/crun-$version-linux-arm64" -o "$binary"
fi
[[ "$(shasum -a 256 "$binary" | cut -d' ' -f1)" == "$expected" ]] || { echo 'crun checksum mismatch' >&2; exit 1; }
# Stage the digest-checked binary atomically. Running containers keep their runtime inode.
"${docker[@]}" "${guest[@]}" -i "$helper" sh -ec '
    f=$(mktemp /oci/.crun.XXXXXX)
    trap '\''rm -f "$f"'\'' EXIT
    cat > "$f"
    echo "$1  $f" | sha256sum -c - >/dev/null
    chmod 755 "$f"
    if test ! -f "/oci/$2" || ! echo "$1  /oci/$2" | sha256sum -c - >/dev/null 2>&1; then mv -f "$f" "/oci/$2"; fi
' sh "$expected" "${dst##*/}" < "$binary"
# Compare the exact previous contents under a guest lock before changing Docker's configuration.
apply_config() {
    local previous="$1" replacement="$2" hash
    hash="$(shasum -a 256 "$previous" | cut -d' ' -f1)"
    "${docker[@]}" "${guest[@]}" --pid=host --cap-add KILL -i "$helper" sh -ec '
        exec 9>/oci/config.lock
        flock -x 9
        current=$(if test -e /config/daemon.json; then cat /config/daemon.json; fi | sha256sum)
        f=$(mktemp /config/.micropod-daemon.XXXXXX)
        trap '\''rm -f "$f"'\'' EXIT
        cat > "$f"
        wanted=$(sha256sum "$f")
        if test "${current%% *}" != "${wanted%% *}"; then
            test "${current%% *}" = "$1" || { echo "Docker configuration changed during installation" >&2; exit 1; }
            if test -f /config/daemon.json; then chmod "$(stat -c %a /config/daemon.json)" "$f"; fi
            if test -s "$f"; then mv -f "$f" /config/daemon.json; else rm -f /config/daemon.json; fi
        fi
        set -- $(pidof dockerd)
        test "$#" -eq 1
        kill -HUP "$1"
    ' sh "$hash" < "$replacement"
}
apply_config "$tmp/original" "$tmp/new"
for ((try=0; try<30; try++)); do
    if registered; then
        if "${docker[@]}" run --rm --pull=never --network none --runtime micropod-crun "$helper" true; then
            echo "Registered micropod-crun $version on worker $worker."
            exit 0
        fi
        break
    fi
    sleep 0.2
done
apply_config "$tmp/new" "$tmp/original"
echo 'Docker could not run the crun probe. Restored its previous configuration.' >&2
exit 1
