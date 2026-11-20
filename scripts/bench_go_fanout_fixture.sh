#!/bin/bash
# Build context for the fan-out benchmark. Supply a fresh destination directory.
set -euo pipefail
[[ $# -eq 1 ]] || { echo 'Usage: bench_go_fanout_fixture.sh NEW_DIRECTORY' >&2; exit 2; }
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir "$1"
dest=$(cd "$1" && pwd)
src="$dest/source"
mkdir -p "$src/proxy/github.com/opencontainers/runtime-spec/@v"
cp -R "$root/guest/cmd" "$src/"
cp "$root/guest"/*.go "$root/guest/go.mod" "$root/guest/go.sum" "$src/"
# Populate only the selected module's local proxy files. go.sum authenticates the zip
# in Linux. Each engine can measure a genuinely empty module store without network jitter.
metadata=$(cd "$root/guest" && go mod download -json github.com/opencontainers/runtime-spec)
for field in Info GoMod Zip; do
    file=$(jq -er ".$field" <<< "$metadata")
    cp "$file" "$src/proxy/github.com/opencontainers/runtime-spec/@v/"
done
cat > "$src/fanout_test.go" <<'GO'
package main
import ("os"; "testing")
func TestFanoutRevision(t *testing.T) {
  if want := os.Getenv("EXPECTED_REVISION"); want != "" && want != revision { t.Fatalf("built %q, want %q", revision, want) }
}
GO
printf 'package main\nconst revision = "seed"\n' > "$src/revision.go"
awk '
    {print}
    /switch cmd \{/ {
        print "\tcase \"ci-revision\":"
        print "\t\t_, err := fmt.Fprintln(stdout, revision)"
        print "\t\treturn err"
        count++
    }
    END {if (count != 1) exit 1}
' "$root/guest/main.go" > "$src/main.go"
cat > "$dest/Dockerfile" <<'DOCKERFILE'
ARG BASE
FROM ${BASE}
WORKDIR /workspace
COPY . .
ENV GOTOOLCHAIN=local GOENV=off GOWORK=off CGO_ENABLED=0 GOMAXPROCS=2 GOFLAGS="-trimpath -p=2" GOTELEMETRY=off GOPROXY=file:///workspace/proxy GOSUMDB=off
DOCKERFILE
