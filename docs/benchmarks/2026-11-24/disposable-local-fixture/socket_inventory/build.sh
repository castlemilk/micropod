#!/bin/sh
# Build the diagnostic guest binary with only the Go standard library.
set -eu
if [ "$#" -ne 1 ]; then
    echo 'usage: build.sh OUTPUT' >&2
    exit 2
fi
case "$1" in
    /*) output=$1 ;;
    *) output=$PWD/$1 ;;
esac
cd "$(dirname "$0")"
export GOTOOLCHAIN=local GOWORK=off GOENV=off GOFLAGS= GOEXPERIMENT= CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOARM64=v8.0
go_bin="$(go env GOROOT)/bin/go"
if [ "$("$go_bin" env GOVERSION)" != go1.27.2 ]; then
    echo 'socket-inventory requires the pinned Go 1.27.2 toolchain' >&2
    exit 1
fi
"$go_bin" build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' -o "$output" main.go
