#!/bin/sh
# Run locally with the normal shared Go cache. Reusing test executables must still reveal a failure.
set -eu
suite=$(cd "$(dirname "$0")" && pwd)/samples/go-app/ci-suite.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
module="$tmp/work tree"
mkdir -p "$module/first/common/testdata" "$module/second/common/testdata" "$tmp/out" "$tmp/invalid"
cd "$module"
printf 'module example.test/suite\n\ngo 1.25\n' > go.mod
for dir in first/common second/common; do
    printf 'package common\n' > "$dir/common.go"
    printf 'ok\n' > "$dir/testdata/verdict"
    cat > "$dir/common_test.go" <<'GO'
package common_test

import (
    "os"
    "strings"
    "testing"
)

func TestReadsCurrentFixture(t *testing.T) {
    b, err := os.ReadFile("testdata/verdict")
    if err != nil || strings.TrimSpace(string(b)) != "ok" {
        t.Fatalf("unexpected live verdict %q (%v)", b, err)
    }
}
GO
done
sh "$suite" compile "$tmp/out"
test "$(cat "$tmp/out/test-count")" = 2
sh "$suite" test "$tmp/out" > "$tmp/pass"
test "$(grep -c '^--- PASS: TestReadsCurrentFixture' "$tmp/pass")" = 2
printf 'fail\n' > second/common/testdata/verdict
for attempt in 1 2; do
    if sh "$suite" test "$tmp/out" > "$tmp/fail"; then echo "Cached a failing test on attempt $attempt" >&2; exit 1; fi
    grep -q 'unexpected live verdict' "$tmp/fail"
done
printf 'package common\nimport "fmt"\nfunc broken() { fmt.Printf("%%d", "oops") }\n' > first/common/broken.go
if sh "$suite" compile "$tmp/invalid" > "$tmp/vet" 2>&1; then echo "Accepted invalid vet result" >&2; exit 1; fi
grep -q 'format %d' "$tmp/vet"
