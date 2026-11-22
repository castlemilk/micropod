# BASE is the content digest of an already provisioned PostgreSQL 16 image.
ARG BASE=docker.io/library/postgres:16
FROM ${BASE} AS fresh
ENV MICROPOD_PG_FIXTURE_MODE=fresh
COPY --chmod=0755 fixture.sh /usr/local/bin/micropod-pg-fixture
ARG FIXTURE_BUILD
RUN test -n "$FIXTURE_BUILD" && ln -s /usr/local/bin/micropod-pg-fixture /docker-entrypoint-initdb.d/99-micropod-finish.sh
ENTRYPOINT ["/usr/local/bin/micropod-pg-fixture"]
CMD ["postgres"]

FROM fresh AS fresh-overlay
# Both overlay cases inherit the same empty directory, ownership and permissions.
ENV PGDATA=/var/lib/micropod-fixture/data MICROPOD_PG_FIXTURE_MODE=fresh-overlay
RUN install -d -m 0700 -o postgres -g postgres "$PGDATA"

FROM fresh-overlay AS prepared
ENV MICROPOD_PG_FIXTURE_MODE=prepared
ARG FIXTURE_BUILD
RUN test -n "$FIXTURE_BUILD" && gosu postgres micropod-pg-fixture prepare
