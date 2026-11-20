#!/bin/bash
set -euo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
exec bash "$dir/fetch-guest-artifact.sh" \
    https://github.com/containers/crun/releases/download/1.31/crun-1.31-linux-arm64 \
    f54fd58603ae031aa7a255af550bcffb035f28058aa1a971e6691b53f7f5a32e "${1:?destination}" "${MICROPOD_CRUN_FILE:-}"
