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
# Record compiler invocations under the same flag profile as prepare-go-suite.
mkdir "$tmp/bin"
REAL_GO=$(command -v go)
COMPILE_LOG="$tmp/compile-log"
export REAL_GO COMPILE_LOG GOENV=off GOFLAGS='-trimpath -p=2'
cat > "$tmp/bin/go" <<'SH'
#!/bin/sh
if [ "$1" = test ]; then printf 'compile\n' >> "$COMPILE_LOG"; fi
exec "$REAL_GO" "$@"
SH
chmod +x "$tmp/bin/go"
PATH="$tmp/bin:$PATH"
export PATH
sh "$suite" compile "$tmp/out"
test "$(wc -l < "$COMPILE_LOG" | tr -d ' ')" = 2
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

# The import-path leaf names now differ. Include the module root so the
# checkout's basename ("work tree") cannot stand in for its import path.
rm first/common/broken.go
mv second/common second/client
printf 'ok\n' > second/client/testdata/verdict
cp first/common/common_test.go root_test.go
mkdir testdata "$tmp/batched"
printf 'ok\n' > testdata/verdict
: > "$COMPILE_LOG"
sh "$suite" compile "$tmp/batched"
test "$(wc -l < "$COMPILE_LOG" | tr -d ' ')" = 1
test "$(cat "$tmp/batched/test-count")" = 3
test "$(cat "$tmp/batched/tests/1/package")" = .
test "$(cat "$tmp/batched/tests/2/package")" = ./first/common
test "$(cat "$tmp/batched/tests/3/package")" = ./second/client
sh "$suite" test "$tmp/batched" > "$tmp/pass"
test "$(grep -c '^--- PASS: TestReadsCurrentFixture' "$tmp/pass")" = 3

# A case-folding output directory would alias these two test binary names.
mv second/client second/Common
mkdir "$tmp/mixed-case"
: > "$COMPILE_LOG"
sh "$suite" compile "$tmp/mixed-case"
test "$(wc -l < "$COMPILE_LOG" | tr -d ' ')" = 3
sh "$suite" test "$tmp/mixed-case" > "$tmp/pass"
test "$(grep -c '^--- PASS: TestReadsCurrentFixture' "$tmp/pass")" = 3
