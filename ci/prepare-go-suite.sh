#!/bin/bash
# Prepare reproducible vet, test binaries and a main package for repeated jobs on an immutable checkout.
set -euo pipefail
if [[ $# -lt 2 || $# -gt 3 || ! "$1" =~ ^sha256:[0-9a-f]{64}$ || ! "$2" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]]; then
    echo 'Usage: prepare-go-suite.sh SOURCE_IMAGE_ID CACHE_SCOPE [MAIN_PACKAGE]' >&2
    exit 2
fi
source_id=$1
scope=$2
main=${3:-.}
[[ "$main" != -* ]] || { echo 'Expected a main package' >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
suite="$root/ci/samples/go-app/ci-suite.sh"
cli=${MICROPOD_BIN:-$root/.build/release/micropod}
endpoint=$("$cli" ci endpoint)
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
docker=(docker --host "$endpoint")
# A fixed offline Linux profile is part of the contract. Other build profiles must have their own key.
envs=(GOENV=off GOTOOLCHAIN=local GOWORK=off 'GOFLAGS=-trimpath -p=2' CGO_ENABLED=0 GOMAXPROCS=2
      GOTELEMETRY=off GOPROXY=off GOSUMDB=off)
flags=()
for setting in "${envs[@]}"; do flags+=(-e "$setting"); done
# shellcheck disable=SC2016
compile='
    test ! -e /micropod-ci-suite && test ! -L /micropod-ci-suite || { echo "CI output path already exists" >&2; exit 1; }
    test "$(go list -f "{{.Name}}" "$1")" = main || { echo "Expected exactly one main package" >&2; exit 1; }
    out=/tmp/micropod-ci-suite
    mkdir -m 755 "$out"
    cat > "$out/suite.sh"
    sh "$out/suite.sh" compile "$out"
    go build -trimpath -buildvcs=false -o "$out/product" "$1"
    chmod -R a+rX "$out"
'
key=$( { printf '%s\0' go-suite-v2 "$source_id" "$scope" "$main" "${envs[@]}" "$compile"; cat "$suite"; } | shasum -a 256 | cut -d' ' -f1)
tag="micropod-internal/ci-go-suite:$key"
publication=null
result() {
    printf '{"event":"ci.go.suite","cache":"%s","key":"%s","image":"%s","publication":%s}\n' "$1" "$key" "$2" "$publication" >&2
    printf '%s\n' "$2"
}
reuse() {
    local info
    info=$("${docker[@]}" image inspect --format '{{.Id}} {{index .Config.Labels "io.micropod.ci.go-suite"}}' "$tag" 2>/dev/null) || return 1
    [[ "${info#* }" == "$key" ]] || return 1
    result hit "${info%% *}"
}
reuse && exit 0
locks="$(dirname "${endpoint#unix://}")/go-preparation-locks"
umask 077
mkdir -p "$locks"
exec 9>"$locks/${key:0:3}"
/usr/bin/lockf -s 9
reuse && exit 0

# The compiler and both publication paths run inside the persistent worker.
info=$("${docker[@]}" image inspect --format '{{json .}}' "$source_id")
jq -e '(.Config.Volumes // {} | keys) | all(. != "/" and . != "/tmp" and . != "/micropod-ci-suite" and
        (startswith("/micropod-ci-suite/") | not) and (startswith("/tmp/micropod-ci-suite") | not))' <<< "$info" >/dev/null || {
    echo 'The image declares a volume over a CI output directory' >&2; exit 1;
}
compiler=""
stage=""
parent="micropod-internal/ci-workspace:${source_id#sha256:}"
cleanup() {
    if [[ -n "$compiler" ]]; then "${docker[@]}" rm -fv "$compiler" >/dev/null || true; fi
    if [[ -n "$stage" ]]; then "${docker[@]}" image rm "$stage" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
compiler=$("$cli" ci create --cache go --cache-scope "$scope" --rm=false --pull=never --network none -i "${flags[@]}" \
    --label "io.micropod.ci.go-suite.compiler=$key" --entrypoint /bin/sh "$source_id" -ec "$compile" sh "$main")
"${docker[@]}" start -ai "$compiler" < "$suite" >&2
[[ "$("${docker[@]}" inspect --format '{{.State.Status}} {{.State.ExitCode}}' "$compiler")" == "exited 0" ]]
socket="$(dirname "${endpoint#unix://}")/oci.sock"
if [[ -S "$socket" ]] && jq -e '.Descriptor.mediaType == "application/vnd.oci.image.manifest.v1+json" and
    .Descriptor.digest == .Id' <<< "$info" >/dev/null; then
    reply=$(curl -sS --unix-socket "$socket" -X POST -w '\n%{http_code}' "http://localhost/oci/v1/go-suites/$key/$compiler")
    body=${reply%$'\n'*}
    case "${reply##*$'\n'}" in
        200)
            publication=$(jq -ce 'select(.method == "oci-layer" and (.image | test("^sha256:[0-9a-f]{64}$")))' <<< "$body")
            image_id=$("${docker[@]}" image inspect --format '{{.Id}} {{index .Config.Labels "io.micropod.ci.go-suite"}}' "$tag")
            [[ "$image_id" == "$(jq -r '.image' <<< "$publication") $key" ]] || { echo 'Published suite identity mismatch' >&2; exit 1; }
            result miss "${image_id%% *}"
            exit 0 ;;
        404|415) ;; # Previous worker version or an unsupported manifest.
        *) echo "Suite publication failed: $body" >&2; exit 1 ;;
    esac
fi
stage="micropod-internal/ci-go-suite-stage:$key"
publication='{"method":"buildkit"}'
"${docker[@]}" commit "$compiler" "$stage" >/dev/null
"${docker[@]}" image tag "$source_id" "$parent"
"${docker[@]}" buildx build --builder default --load --quiet --provenance=false --tag "$tag" \
    --build-arg "SOURCE=$parent" --build-arg "STAGE=$stage" --label "io.micropod.ci.go-suite=$key" - >&2 <<'DOCKERFILE'
ARG SOURCE
ARG STAGE
FROM ${STAGE} AS compiled
FROM ${SOURCE}
COPY --from=compiled /tmp/micropod-ci-suite/ /micropod-ci-suite/
DOCKERFILE
image_id=$("${docker[@]}" image inspect --format '{{.Id}}' "$tag")
result miss "$image_id"
