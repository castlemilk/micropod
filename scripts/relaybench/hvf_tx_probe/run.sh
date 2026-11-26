#!/bin/sh
set -eu
mode=${1:---native}
case "$mode" in
    --native|--test|--hvf|--paired) ;;
    *) echo "usage: sh run.sh [--native|--test|--hvf|--paired]" >&2; exit 2 ;;
esac
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
xcrun clang -arch arm64 -Wall -Wextra -Werror -O2 -c apple.c -o "$work/apple.o"
xcrun clang -arch arm64 -c guest.S -o "$work/guest.o"
build() {
    rustc --edition 2024 -D warnings -O -C "link-arg=$work/apple.o" \
        -C "link-arg=$work/guest.o" main.rs -o "$work/probe" "$@"
}
if [ "$mode" = --test ]; then
    build --test
    "$work/probe"
else
    build
    if [ "$mode" = --hvf ] || [ "$mode" = --paired ]; then
        cat >"$work/entitlements.plist" <<'PLIST'
<plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>
PLIST
        codesign --sign - --force --entitlements "$work/entitlements.plist" "$work/probe"
        python3 - "$work/probe" "$mode" <<'PY'
import subprocess
import sys
try:
    result = subprocess.run(sys.argv[1:], timeout=10)
except subprocess.TimeoutExpired:
    sys.exit("Guest device probe timed out")
sys.exit(result.returncode)
PY
    else
        "$work/probe" "$mode"
    fi
fi
