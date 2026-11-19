# Build once for linux/arm64. Export the resulting image to each engine for a matched run.
FROM node:24-bookworm-slim AS node
FROM golang:1.26-bookworm AS go
FROM python:3.12-slim-bookworm
COPY --from=go /usr/local/go /usr/local/go
COPY --from=node /usr/local/bin/ /usr/local/bin/
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
ENV PATH=/usr/local/go/bin:$PATH
