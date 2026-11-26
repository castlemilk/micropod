#!/bin/sh
# Runs inside an alpine container on the gate machine, with the Go module cache
# attached by the engine (labels io.micropod.cache=+gomod and
# io.micropod.cache.scope) and the machine workspace mounted at /w.
#
#   guest_cache.sh seed   <tag>   copy /w/seed into the cache store, then hash it
#   guest_cache.sh hash   <tag>   hash what the cache store holds now
#   guest_cache.sh tamper <tag>   append one byte to the blob (deliberate-failure
#                                 mode only), then hash
#
# Writes /w/out/<tag>.manifest ("<sha256>  ./<path>" per file, sorted) and
# /w/out/<tag>.df and /w/out/<tag>.dev ("<cache device> <root device>"), then /w/out/<tag>.done with a sentinel line last. The host
# compares the manifest with the one it computed over /w/seed itself; nothing
# from this container's stdout is used.
set -eu
mode=$1
tag=$2
out=/w/out
[ -n "${GOMODCACHE:-}" ] || { echo "no GOMODCACHE attached" >"$out/$tag.err"; exit 3; }
dir="$GOMODCACHE/b26-gate"
case "$mode" in
seed)
    rm -rf "$dir"
    mkdir -p "$dir"
    cp -R /w/seed/. "$dir/"
    ;;
hash) [ -d "$dir" ] || { echo "no $dir in the cache store" >"$out/$tag.err"; exit 4; } ;;
tamper) printf 'x' >>"$dir/blob.bin" ;;
*) echo "unknown mode $mode" >"$out/$tag.err"; exit 2 ;;
esac
sync
(cd "$dir" && find . -type f | LC_ALL=C sort | while read -r f; do sha256sum "$f"; done) >"$out/$tag.manifest.tmp"
mv "$out/$tag.manifest.tmp" "$out/$tag.manifest"
df -k "$dir" >"$out/$tag.df" 2>&1 || true
echo "GOMODCACHE=$GOMODCACHE" >>"$out/$tag.df"
# The block device under the cache store and the one under the container's root.
echo "$(df -k "$dir" | awk 'END { print $1 }') $(df -k / | awk 'END { print $1 }')" >"$out/$tag.dev"
echo "B26-SENTINEL $tag" >"$out/$tag.done"
