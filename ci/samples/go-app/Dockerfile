# syntax=docker/dockerfile:1.6
# Deps-first ordering + cache mounts: re-running after a source-only change
# reuses every layer below COPY . . and the warm Go module/build caches.
FROM golang:1.25-alpine AS build
WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -o /out/app .

FROM alpine:3.20
COPY --from=build /out/app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
