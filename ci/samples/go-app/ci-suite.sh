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
    # Go 1.21 added multi-package test binary output. Import paths can differ
    # from checkout directory names, especially for the module root.
    multi='{{range context.ReleaseTags}}{{if eq . "go1.21"}}multi{{end}}{{end}}'
    go list "$@" -f "{{if or .TestGoFiles .XTestGoFiles}}$multi/{{context.GOOS}} {{.ImportPath}} {{.Dir}}{{end}}" \
        ./... > "$out/packages"
    root=$(pwd -P)
    number=0
    batch=false
    # The suite preparer supplies this bounded, offline Go profile. Other flags
    # and older toolchains keep their original one-package invocation.
    if [ "$#" -eq 0 ] && [ "${GOENV:-}" = off ] && [ "${GOFLAGS:-}" = '-trimpath -p=2' ]; then
        batch=true
    fi
    names=''
    while IFS= read -r record; do
        [ -n "$record" ] || continue
        case "$record" in 'multi/linux '*|'multi/darwin '*) ;; *) batch=false ;; esac
        record=${record#* }
        import=${record%% *}
        dir=${record#* }
        case "$dir" in
            "$root") pkg=. ;;
            "$root"/*) pkg=./${dir#"$root"/} ;;
            *) echo "Test package is outside the module: $dir" >&2; exit 1 ;;
        esac
        number=$((number + 1))
        target="$out/tests/$number"
        mkdir "$target"
        printf '%s\n' "$pkg" > "$target/package"
        if [ "$batch" = true ]; then
            name=${import##*/}
            # Go treats /v2 etc. specially. A case-folding filesystem can also
            # alias output names. Let the original compiler choose those paths.
            case "$name" in ''|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*|v[0123456789]*|command-line-arguments) batch=false ;; esac
            case " $names " in *" $name "*) batch=false ;; esac
            names="$names $name"
            # Bound argv and the duplicate-name scan for very large workspaces.
            [ "$number" -le 32 ] || batch=false
        fi
    done < "$out/packages"
    if [ "$batch" = true ] && [ "$number" -gt 1 ]; then
        mkdir "$out/binaries"
        i=0
        for name in $names; do
            i=$((i + 1))
            IFS= read -r pkg < "$out/tests/$i/package"
            set -- "$@" "$pkg"
        done
        go test -c -o "$out/binaries/" "$@"
        i=0
        for name in $names; do
            i=$((i + 1))
            mv "$out/binaries/$name.test" "$out/tests/$i/test"
        done
        rmdir "$out/binaries"
    else
        i=0
        while [ "$i" -lt "$number" ]; do
            i=$((i + 1))
            target="$out/tests/$i"
            IFS= read -r pkg < "$target/package"
            go test "$@" -c -o "$target/test" "$pkg"
        done
    fi
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
