#!/bin/bash
# Fetch a pinned guest artifact, or verify a previously downloaded copy.
set -euo pipefail
url=${1:?URL} digest=${2:?SHA-256} dest=${3:?destination} source_file=${4:-}
matches() { [[ -f "$1" && "$(shasum -a 256 "$1" | cut -d ' ' -f1)" == "$digest" ]]; }
if [[ -n "$source_file" ]] && ! matches "$source_file"; then
    echo "Unexpected checksum for $source_file" >&2
    exit 1
fi
if matches "$dest"; then exit 0; fi
mkdir -p "$(dirname "$dest")"
stage=$(mktemp "$dest.XXXXXXXX")
trap 'rm -f "$stage"' EXIT
if [[ -n "$source_file" ]]; then
    cp "$source_file" "$stage"
else
    curl --fail --location --silent --show-error --retry 2 "$url" -o "$stage"
fi
matches "$stage" || { echo "Unexpected checksum for $url" >&2; exit 1; }
chmod 0644 "$stage"
mv -f "$stage" "$dest"
