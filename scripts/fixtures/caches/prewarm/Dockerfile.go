# T3: an image whose Go caches are baked in. Build context: the fixtures dir.
# The engine must leave GOMODCACHE/GOCACHE alone (reason image-prewarmed).
FROM golang:alpine
ENV GOTOOLCHAIN=local
COPY go/base /prewarm/go
RUN cd /prewarm/go && go mod download && go build -o /dev/null .
