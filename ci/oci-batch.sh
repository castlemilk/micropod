#!/bin/bash
# Offline source jobs on the persistent ARM64 CI worker. A prepared handle belongs to this worker account.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cli="${MICROPOD_BIN:-$root/.build/release/micropod}"
alpine='alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc'
usage() { echo 'Usage: oci-batch.sh prepare SOURCE_IMAGE CACHE_SCOPE | run HANDLE COUNT COMMAND [ARG ...] | session HANDLE | forget HANDLE' >&2; exit 2; }
[[ $# -ge 2 ]] || usage
verb="$1"; shift
worker="${MICROPOD_CI_HOME:-$HOME/.micropod/ci}"
native_socket="$worker/oci.sock"
native_handles="$worker/native-oci-handles"
client="${MICROPOD_OCI_CLIENT:-$root/.build/oci-tools/client}"
native=false
case "${MICROPOD_OCI_BACKEND:-auto}" in
    auto) if [[ "$verb" == prepare && -S "$native_socket" || "$verb" != prepare && "$1" =~ ^[a-f0-9]{64}$ && -f "$native_handles/$1" ]]; then native=true; fi ;;
    native) native=true ;;
    docker) ;;
    *) usage ;;
esac
if [[ "$1" == bundle:* ]]; then
    [[ "${MICROPOD_OCI_BACKEND:-auto}" != docker && ( "$verb" == run || "$verb" == session ) ]] || usage
    [[ "$1" =~ ^bundle:[a-f0-9]{64}:[a-z0-9][a-z0-9_-]{0,62}$ ]] || usage
    native=true
fi
native_key() {
    local epoch
    epoch="$(jq -er '.instance' "$worker/session.json")" || return 1
    printf '%s\0' native-oci-v2 "$1" "$2" "$epoch" | shasum -a 256 | cut -d' ' -f1
}
if $native; then
    if [[ ! -x "$client" && -z "${MICROPOD_OCI_CLIENT:-}" ]]; then
        cli_path="$(command -v "$cli")"
        client="$(dirname "$(realpath "$cli_path")")/micropod-oci"
    fi
    [[ -S "$native_socket" && -x "$client" ]] || { echo 'The native OCI worker socket and client are required' >&2; exit 1; }
    case "$verb" in
        session|run) exec "$client" "$native_socket" "$verb" "$@" ;;
        prepare)
            # ci snapshot returns a content ID. Warm readers share the guest lease and never queue
            # behind another reader's Docker CLI, policy capture or exclusive host preparation lock.
            if [[ $# -eq 2 && "$1" =~ ^sha256:[a-f0-9]{64}$ && "$2" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; then
                key="$(native_key "$1" "$2")"
                if [[ -s "$native_handles/$key" ]] && curl --silent --fail --max-time 5 --unix-socket "$worker/docker.sock" \
                    "http://localhost/containers/micropod-oci-pin-$key/json" | \
                    jq -e --arg image "$1" --arg key "$key" '.Image == $image and .Config.Labels["io.micropod.oci.pin"] == $key' >/dev/null && \
                    "$client" "$native_socket" reuse "$key" >/dev/null; then
                    printf '%s\n' "$key"
                    exit 0
                fi
            fi ;;
    esac
fi
endpoint="$("$cli" ci endpoint)"
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH BUILDX_BUILDER
docker=(docker --host "$endpoint")
handles="$(dirname "${endpoint#unix://}")/oci-batches"
umask 077
mkdir -p "$handles/locks"
lock_handle() {
    exec 9>"$handles/locks/${1:0:3}"
    /usr/bin/lockf -s 9
}
case "$verb" in
prepare)
    [[ $# -eq 2 && "$2" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ && "$1" != -* ]] || usage
    source_image="$("${docker[@]}" image inspect --format '{{.Id}}' "$1")"
    scope="$2"
    if $native; then
        # A boot selects the stock policy. Freeze that policy with the immutable image and scope.
        # Existing handles also recover after reboot. New preparations then capture the new boot's policy.
        key="$(native_key "$source_image" "$scope")"
        lock_handle "$key"
        mkdir -p "$native_handles"
        tag="micropod-internal/oci-native:$key"
        pin="micropod-oci-pin-$key"
        if [[ -s "$native_handles/$key" ]]; then
            pinned="$("${docker[@]}" inspect --format '{{index .Config.Labels "io.micropod.oci.pin"}} {{.Image}}' "$pin")"
            [[ "$pinned" == "$key $source_image" ]] || { echo 'Native OCI cache reference changed' >&2; exit 1; }
            "$client" "$native_socket" prepare "$key" < "$native_handles/$key" >/dev/null
            printf '%s\n' "$key"
            exit 0
        fi
    fi
    tmp="$(mktemp -d)"
    template=""
    cleanup() {
        if [[ -n "$template" ]]; then "${docker[@]}" rm -f "$template" >/dev/null || true; fi
        rm -rf "$tmp"
    }
    trap cleanup EXIT
    if ! $native; then
        (cd "$root/guest" && env -u GOROOT GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$tmp/runner" ./cmd/oci-batch)
    fi
    # Docker resolves the image user, namespaces, seccomp, devices and resource controls once.
    template="$("$cli" ci run --cache go --cache-scope "$scope" --detach --pull=never --network none \
        --cpus 1 --memory 1g --entrypoint /bin/sh "$source_image" -ec 'exec sleep 300')"
    "${docker[@]}" run --rm --read-only --network none --cap-drop ALL \
        -v /run/docker/containerd/containerd.sock:/observe.sock -v /usr/local/bin/ctr:/bin/worker-ctr:ro \
        "$alpine" /bin/worker-ctr -a /observe.sock -n moby containers info --spec "$template" > "$tmp/template.json"
    "${docker[@]}" cp "$template:/etc/resolv.conf" "$tmp/resolv.conf"
    "${docker[@]}" rm -f "$template" >/dev/null
    template=""
    # Canonicalize only instance-dependent values. The launcher validates every bind and namespace.
    jq -S '.hostname="" | .root.path="rootfs" | .linux.cgroupsPath="" |
      .process.env |= map(select(startswith("HOSTNAME=")|not)) |
      .mounts |= map(if .type=="bind" then .source=.destination else . end)' \
        "$tmp/template.json" > "$tmp/normalized"
    mv "$tmp/normalized" "$tmp/template.json"
    if $native; then
        "${docker[@]}" image tag "$source_image" "$tag"
        # Docker GC must see a durable reference to the original named volumes while native jobs mount them.
        # This owner record is never started. Session open and all jobs go over the private socket.
        if ! "${docker[@]}" container inspect "$pin" >/dev/null 2>&1; then
            "${docker[@]}" create --pull=never --name "$pin" --label "io.micropod.oci.pin=$key" --network none \
                --mount "type=volume,source=micropod-ci-scoped-$scope-gomod,destination=/cache/gomod,volume-nocopy" \
                --mount "type=volume,source=micropod-ci-scoped-$scope-gobuild,destination=/cache/gobuild,volume-nocopy" \
                --entrypoint /bin/true "$source_image" >/dev/null
        fi
        [[ "$("${docker[@]}" inspect --format '{{index .Config.Labels "io.micropod.oci.pin"}} {{.Image}}' "$pin")" == "$key $source_image" ]] || { echo 'Conflicting OCI cache reference' >&2; exit 1; }
        jq -n --arg scope "$scope" --slurpfile spec "$tmp/template.json" --rawfile resolver "$tmp/resolv.conf" \
            '{scope:$scope,spec:$spec[0],resolver:$resolver}' > "$tmp/native.json"
        if ! "$client" "$native_socket" prepare "$key" < "$tmp/native.json" >/dev/null; then
            if "$client" "$native_socket" forget "$key" >/dev/null; then
                "${docker[@]}" rm "$pin" >/dev/null
                "${docker[@]}" image rm "$tag" >/dev/null
            else
                cp "$tmp/native.json" "$native_handles/$key"
                echo "Retry or forget native OCI handle $key" >&2
            fi
            exit 1
        fi
        entry="$(mktemp "$native_handles/.prepared.XXXXXX")"
        cp "$tmp/native.json" "$entry"
        mv "$entry" "$native_handles/$key"
        printf '%s\n' "$key"
        exit 0
    fi
    # Build the privileged control image from the pinned control base. The job image is only an immutable mount.
    cat > "$tmp/Dockerfile" <<'DOCKERFILE'
ARG CONTROL_BASE
FROM ${CONTROL_BASE}
COPY runner /usr/local/bin/oci-batch
COPY template.json resolv.conf /opt/ci/
ENTRYPOINT ["/usr/local/bin/oci-batch"]
DOCKERFILE
    key="$( (printf '%s\0' "$source_image" "$scope" "$alpine"; cd "$tmp" && shasum -a 256 runner template.json resolv.conf Dockerfile) | shasum -a 256 | cut -d' ' -f1)"
    lock_handle "$key"
    tag="micropod-internal/oci-batch:$key"
    "${docker[@]}" buildx build --builder default --load --quiet --provenance=false --build-arg "CONTROL_BASE=$alpine" --tag "$tag" "$tmp" >/dev/null
    control="$("${docker[@]}" image inspect --format '{{.Id}}' "$tag")"
    "${docker[@]}" image tag "$source_image" "micropod-internal/oci-source:$key"
    entry="$(mktemp "$handles/.handle.XXXXXX")"
    printf '%s\n' "$control" "$source_image" "$scope" > "$entry"
    mv -f "$entry" "$handles/$key"
    printf '%s\n' "$key"
    ;;
run|session|forget)
    key="$1"; shift
    [[ "$key" =~ ^[0-9a-f]{64}$ ]] || usage
    if [[ "$verb" == forget ]]; then
        [[ $# -eq 0 ]] || usage
        lock_handle "$key"
        if $native; then
            [[ -f "$native_handles/$key" ]] || exit 0
            "$client" "$native_socket" forget "$key" >/dev/null
            pin="micropod-oci-pin-$key"
            owned="$("${docker[@]}" ps -aq --filter "name=^/$pin$" --filter "label=io.micropod.oci.pin=$key")"
            if [[ -n "$owned" ]]; then "${docker[@]}" rm "$owned" >/dev/null; fi
            tag="micropod-internal/oci-native:$key"
            tagged="$("${docker[@]}" image ls -q --filter "reference=$tag")"
            if [[ -n "$tagged" ]]; then "${docker[@]}" image rm "$tag" >/dev/null; fi
            rm -f "$native_handles/$key"
            exit 0
        fi
        [[ -f "$handles/$key" ]] || exit 0
        users="$("${docker[@]}" ps -aq --filter "label=io.micropod.oci.handle=$key")"
        if [[ -n "$users" ]]; then
            echo 'The prepared handle has an active launcher' >&2
            exit 1
        fi
        # Prepared images can share layers and configuration IDs. Remove only this handle's tag.
        for repo in oci-batch oci-source; do
            tag="micropod-internal/$repo:$key"
            tagged="$("${docker[@]}" image ls -q --filter "reference=$tag")"
            if [[ -n "$tagged" ]]; then
                "${docker[@]}" image rm "$tag" >/dev/null
            fi
        done
        rm -f "$handles/$key"
        exit 0
    fi
    [[ -f "$handles/$key" ]] || usage
    { IFS= read -r control; IFS= read -r source_image; IFS= read -r scope; } < "$handles/$key"
    [[ "$control" =~ ^sha256:[0-9a-f]{64}$ && "$source_image" =~ ^sha256:[0-9a-f]{64}$ && "$scope" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || usage
    args=()
    if [[ "$verb" == session ]]; then
        [[ $# -eq 0 ]] || usage
        args+=(-i)
        set -- session
    else
        [[ $# -ge 2 && "$1" =~ ^([1-9]|[1-5][0-9]|6[0-4])$ ]] || usage
    fi
    for k in GOENV GOTOOLCHAIN GOWORK GOFLAGS GOMAXPROCS CGO_ENABLED GOTELEMETRY GOPROXY GOSUMDB; do
        if [[ -n "${!k+x}" ]]; then args+=(-e "$k"); fi
    done
    case "${MICROPOD_OCI_RUNTIME:-runc}" in
        runc) runtime_dir=/usr/local/bin ;;
        crun) runtime_dir=/var/lib/micropod/oci ;;
        *) usage ;;
    esac
    exec "${docker[@]}" run --rm --pull=never --label "io.micropod.oci.handle=$key" --network none --privileged --read-only --cgroupns private \
        --mount "type=image,source=$source_image,destination=/image,readonly" \
        -e "MICROPOD_OCI_TRACE=${MICROPOD_OCI_TRACE:-0}" -e "MICROPOD_JOB_RUNTIME=${MICROPOD_OCI_RUNTIME:-runc}" \
        --mount "type=bind,source=$runtime_dir,destination=/opt/runtime,readonly" \
        --mount type=volume,destination=/data,volume-nocopy --tmpfs /run:rw,nosuid,nodev,mode=0755 \
        --mount "type=volume,source=micropod-ci-scoped-$scope-gomod,destination=/stores/gomod,volume-nocopy" \
        --mount "type=volume,source=micropod-ci-scoped-$scope-gobuild,destination=/stores/gobuild,volume-nocopy" \
        ${args[@]+"${args[@]}"} "$control" "$@"
    ;;
*) usage ;;
esac
