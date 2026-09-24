#!/usr/bin/env bash
# Regenerate every publishable client surface from proto/.
#
#   scripts/gen-sdk.sh          # regen all languages
#   scripts/gen-sdk.sh --check  # regen into place, fail if git diff is dirty
#
# Layout:
#   sdk/go/gen/     Go messages + connect-go + grpc stubs  (buf.gen.yaml)
#   sdk/ts/src/gen/ protobuf-es v2 messages + service stubs (buf.gen.sdk.yaml)
#   sdk/swift/…/Generated/  SwiftProtobuf messages            (buf.gen.sdk.yaml)
set -euo pipefail
cd "$(dirname "$0")/.."

# Go + host-Swift gen share the main template (api/ consumes sdk/go via
# replace; MicropodCore/Generated serves the app internals).
buf generate --template buf.gen.yaml
# SDK-only surfaces (TypeScript + standalone Swift copy).
buf generate --template buf.gen.sdk.yaml

if [[ "${1:-}" == "--check" ]]; then
    if ! git diff --quiet -- sdk/ Sources/MicropodCore/Generated api/; then
        echo "error: generated code out of sync — run scripts/gen-sdk.sh" >&2
        git status --short -- sdk/ Sources/MicropodCore/Generated api/
        exit 1
    fi
fi
