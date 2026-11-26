#!/bin/sh
set -eu
cd "$(dirname "$0")"
test "$(uname -s)" = Darwin
for wait_ns in 0 50000; do
    xcrun clang -O3 -Wall -Wextra -Werror -fblocks "-DWAIT_NS=$wait_ns" -I . dispatch-probe.c hot.c -o "relay-$wait_ns"
done
go_bin="${GO_BIN:-go}"
go_root="${GO_ROOT:-$(env -u GOROOT "$go_bin" env GOROOT)}"
export GOROOT="$go_root"
export GOTOOLCHAIN=local GOPROXY=off GOMAXPROCS=2 GOCACHE="$PWD/go-cache"
"$go_root/bin/go" build -p=2 -trimpath -o server server.go
"$go_root/bin/go" build -p=2 -trimpath -o fixed fixed.go
cc -O2 -Wall -Wextra -Werror -dynamiclib meter.c -o meter.dylib
