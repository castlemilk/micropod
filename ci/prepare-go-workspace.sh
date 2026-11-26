#!/bin/bash
# The inner single-quoted programs expand their arguments in Linux.
# shellcheck disable=SC2016
# Prepare one immutable checkout and Go output for independent, writable job containers.
set -euo pipefail
if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo 'Usage: prepare-go-workspace.sh BASE_IMAGE CHECKOUT RELATIVE_OUTPUT [MAIN_PACKAGE]' >&2
    exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
cli="${MICROPOD_BIN:-$root/.build/release/micropod}"
output="$3"
case "/$output/" in
    *'//'*|*'/../'*|*'/./'*)
        echo 'Go output must be a relative file inside the checkout' >&2
        exit 2
        ;;
esac
pkg="${4:-.}"
if [[ -z "$pkg" || "$pkg" == -* ]]; then
    echo 'Expected one Go main package' >&2
    exit 2
fi
source_image="$("$cli" ci snapshot "$1" "$2")"
endpoint="$("$cli" ci endpoint)"
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH BUILDX_BUILDER
docker=(docker --host "$endpoint")
env_flags=()
env_values=()
go_settings=(CGO_ENABLED CGO_CFLAGS CGO_CPPFLAGS CGO_CXXFLAGS CGO_LDFLAGS CC CXX
             GOFLAGS GOMAXPROCS GOOS GOARCH GOARM GOARM64 GOAMD64 GO386 GOEXPERIMENT
             GOENV GOTOOLCHAIN GOWORK GOTELEMETRY GOPROXY GOSUMDB)
for key in "${go_settings[@]}"; do
    if [[ -n "${!key+x}" ]]; then
        env_flags+=(-e "$key")
        env_values+=("$key=${!key}")
    fi
done
# Hash the build inputs with NUL delimiters. Only the hash appears in the engine's tag and job label.
build_key="$(
    printf '%s\0' go-output-v2 "$source_image" "$output" "$pkg" "${MICROPOD_CI_GO_SCOPE:-}" \
        ${env_values[@]+"${env_values[@]}"} | shasum -a 256 | cut -d' ' -f1
)"
output_tag="micropod-internal/ci-go-output:$build_key"
result() {
    printf '{"event":"ci.go.prepare","cache":"%s","key":"%s","image":"%s","binary_sha256":"%s"}\n' \
        "$1" "$build_key" "$2" "$3" >&2
    printf '%s\n' "$2"
}
reuse_output() {
    local info digest
    info="$("${docker[@]}" image inspect --format '{{.Id}} {{index .Config.Labels "io.micropod.ci.go-output.sha256"}}' "$output_tag" 2>/dev/null)" || return 1
    digest="${info##* }"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    result hit "${info%% *}" "$digest"
}
reuse_output && exit 0
lock_dir="$(dirname "${endpoint#unix://}")/go-preparation-locks"
mkdir -p "$lock_dir"
# Darwin lockf holds the lock on the shell's open descriptor, including across child processes.
# The fixed set of shards bounds metadata growth as revisions accumulate.
exec 9>"$lock_dir/${build_key:0:3}"
/usr/bin/lockf -s 9
reuse_output && exit 0
# The immutable source tag lets BuildKit resolve the local parent. Concurrent preparations
# can share it, and removing a last tag would invalidate a source ID already given to a job.
source_tag="micropod-internal/ci-workspace:${source_image#sha256:}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
context="$tmp/context"
"${docker[@]}" image tag "$source_image" "$source_tag"
cache=(--cache go)
if [[ -n "${MICROPOD_CI_GO_SCOPE:-}" ]]; then cache+=(--cache-scope "$MICROPOD_CI_GO_SCOPE"); fi
# Use the same package stores as ordinary ci run jobs. Only the final product enters the image.
"$cli" ci run "${cache[@]}" ${env_flags[@]+"${env_flags[@]}"} --label "io.micropod.ci.go-prepare=$build_key" \
    --pull=never --entrypoint /bin/sh "$source_image" -ec '
    f=$(mktemp -d)
    go build -trimpath -buildvcs=false -o "$f/product" "$1" >&2
    test -x "$f/product" || { echo "Expected an executable Go main package" >&2; exit 1; }
    cat "$f/product"
' sh "$pkg" > "$tmp/product"
binary_sha="$(shasum -a 256 < "$tmp/product" | cut -d' ' -f1)"
# Give BuildKit's incremental file transfer a distinct path for different bytes of the same size and mtime.
mkdir -p "$(dirname "$context/$binary_sha/$output")"
chmod 755 "$tmp/product"
mv "$tmp/product" "$context/$binary_sha/$output"
# Stable parent metadata keeps an identical nested binary reusable across checkouts and time zones.
find "$context" -type d -exec chmod 755 {} +
TZ=UTC find "$context" -exec touch -t 197001020000 {} +
"${docker[@]}" buildx build --builder default --load --quiet --provenance=false --tag "$output_tag" \
    --build-arg "BASE_IMAGE=$source_tag" --build-arg "BINARY_SHA=$binary_sha" --file - "$context" >/dev/null <<'DOCKERFILE'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG BINARY_SHA
COPY ${BINARY_SHA}/ /workspace/
LABEL io.micropod.ci.go-output.sha256="${BINARY_SHA}"
DOCKERFILE
image_id="$("${docker[@]}" image inspect --format '{{.Id}}' "$output_tag")"
result miss "$image_id" "$binary_sha"
