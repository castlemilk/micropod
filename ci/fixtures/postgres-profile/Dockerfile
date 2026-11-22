# BASE is the content digest of an already provisioned PostgreSQL 16 image.
ARG BASE=docker.io/library/postgres:16
FROM ${BASE} AS fresh
COPY --chmod=0755 fixture.sh /usr/local/bin/micropod-pg-fixture
ARG FIXTURE_BUILD
RUN test -n "$FIXTURE_BUILD" && ln -s /usr/local/bin/micropod-pg-fixture /docker-entrypoint-initdb.d/99-micropod-finish.sh
ENTRYPOINT ["/usr/local/bin/micropod-pg-fixture"]
CMD ["postgres"]

FROM fresh AS prepared
# Outside the upstream VOLUME. Each database writes into its own container overlay.
ENV PGDATA=/var/lib/micropod-fixture/data
ARG FIXTURE_BUILD
RUN test -n "$FIXTURE_BUILD" && install -d -m 0700 -o postgres -g postgres "$PGDATA" && \
    gosu postgres micropod-pg-fixture prepare
