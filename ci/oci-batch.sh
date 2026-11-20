#!/bin/bash
# Offline source jobs on the persistent ARM64 CI worker. A prepared handle belongs to this worker account.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cli="${MICROPOD_BIN:-$root/.build/release/micropod}"
alpine='alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc'
usage() { echo 'Usage: oci-batch.sh prepare SOURCE_IMAGE CACHE_SCOPE | run HANDLE COUNT COMMAND [ARG ...] | session HANDLE | forget HANDLE' >&2; exit 2; }
[[ $# -ge 2 ]] || usage
verb="$1"; shift
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
    tmp="$(mktemp -d)"
    template=""
    cleanup() {
        if [[ -n "$template" ]]; then "${docker[@]}" rm -f "$template" >/dev/null || true; fi
        rm -rf "$tmp"
    }
    trap cleanup EXIT
    (cd "$root/guest" && env -u GOROOT GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$tmp/runner" ./cmd/oci-batch)
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
