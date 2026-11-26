# Cache-mount build used by section T6 of scripts/e2e_hvf_caches.sh. The RUN
# step prints one QUALCOUNTS line (read from the build log on the host) and
# keeps the same counts in /out/counts.
FROM golang:alpine
ENV GOFLAGS=-trimpath GOTOOLCHAIN=local
WORKDIR /src
COPY . .
RUN --mount=type=cache,id=qual-build-gomod,target=/go/pkg/mod \
    --mount=type=cache,id=qual-build-gobuild,target=/root/.cache/go-build \
    mkdir -p /out; go build -x -o /out/app . >/tmp/build.log 2>&1; rc=$?; \
    c=$(grep -c '/compile ' /tmp/build.log); d=$(grep -c '^go: downloading' /tmp/build.log); \
    echo "QUALCOUNTS compiles=$c downloads=$d rc=$rc"; printf 'compiles=%s\ndownloads=%s\n' "$c" "$d" >/out/counts; \
    [ "$rc" = 0 ] || cat /tmp/build.log; exit $rc
CMD ["/out/app"]
