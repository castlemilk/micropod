#!/bin/sh
# Run from the module root. Each test executable still runs in its own package directory.
set -eu
action=${1:?expected compile or test}
out=${2:?expected an absolute suite directory}
shift 2
case "$out" in /*) ;; *) exit 2 ;; esac
case "$action" in
compile)
    # All flags here (e.g. -race) are passed to package discovery as well as compilation.
    # Go can preserve the logical PWD in .Dir, including /var vs /private/var on macOS.
    CDPATH='' cd -P .
    mkdir "$out/tests"
    go vet "$@" ./...
    go list "$@" -f '{{if or .TestGoFiles .XTestGoFiles}}{{.Dir}}{{end}}' ./... > "$out/packages"
    root=$(pwd -P)
    number=0
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        case "$dir" in
            "$root") pkg=. ;;
            "$root"/*) pkg=./${dir#"$root"/} ;;
            *) echo "Test package is outside the module: $dir" >&2; exit 1 ;;
        esac
        number=$((number + 1))
        target="$out/tests/$number"
        mkdir "$target"
        printf '%s\n' "$pkg" > "$target/package"
        go test "$@" -c -o "$target/test" "$pkg"
    done < "$out/packages"
    rm "$out/packages"
    printf '%s\n' "$number" > "$out/test-count"
    ;;
test)
    root=$(pwd -P)
    count=$(cat "$out/test-count")
    i=1
    while [ "$i" -le "$count" ]; do
        target="$out/tests/$i"
        IFS= read -r pkg < "$target/package"
        (cd "$root/$pkg" && exec "$target/test" -test.v -test.paniconexit0 -test.timeout=10m "$@")
        i=$((i + 1))
    done
    ;;
*) exit 2 ;;
esac
