#!/bin/bash
# Refuses a Sparkle release archive whose SHA-256 is not pinned here. The
# release workflow hands sign_update the release signing key, so it must run
# only reviewed bytes. Bumping Sparkle in Package.resolved needs a new pin.
set -euo pipefail
version="${1:?usage: verify_sparkle_tools.sh <version> <archive>}"
archive="${2:?usage: verify_sparkle_tools.sh <version> <archive>}"
case "$version" in
    2.10.0) expected=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c ;;
    *) echo "::error::Sparkle $version has no pinned SHA-256 in scripts/verify_sparkle_tools.sh" >&2; exit 1 ;;
esac
actual=$(shasum -a 256 "$archive" | cut -d' ' -f1)
if [ "$actual" != "$expected" ]; then
    echo "::error::Sparkle-$version.tar.xz is $actual, not the pinned $expected" >&2
    exit 1
fi
