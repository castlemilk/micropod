#!/bin/sh
set -eu

# Linux uptime is monotonic with a 10 ms display resolution. These nested spans
# share the guest clock and can be correlated with the in-test spans.
mark() {
    read -r uptime _ < /proc/uptime
    printf '%s\n' "$uptime" > "/dev/shm/micropod-pg-$1"
    printf 'MP_PG_FIXTURE %s %s\n' "$1" "$uptime"
}

if [ "${0##*/}" = 99-micropod-finish.sh ]; then
    mark materialized
    exit 0
fi

case "${1:-}" in
    prepare)
        test "$MICROPOD_PG_FIXTURE_MODE" = prepared
        test "$(id -u)" != 0
        test "$PGDATA" = /var/lib/micropod-fixture/data
        test "$(postgres -V | cut -d' ' -f3 | cut -d. -f1)" = 16
        # PostgreSQL's own stock catalog and an empty ci database. No database
        # from a previous run, role password, application data or WAL archive.
        initdb -U ci --auth-local=trust --auth-host=scram-sha-256 -D "$PGDATA"
        printf '\nhost all all all scram-sha-256\n' >> "$PGDATA/pg_hba.conf"
        printf 'CREATE DATABASE ci;\n' | postgres --single -D "$PGDATA" template1 >/dev/null
        # Verify the prebuilt catalog directly, before a job supplies its password.
        catalog=$(printf '%s\n' "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_authid WHERE rolpassword IS NOT NULL) OR EXISTS (SELECT 1 FROM pg_class WHERE relnamespace='public'::regnamespace) THEN 'dirty' ELSE 'pristine' END AS state;" |
            postgres --single -D "$PGDATA" ci)
        printf '%s\n' "$catalog" | grep -Eq '= "pristine"'
        LC_ALL=C pg_controldata "$PGDATA" | grep -Eq '^Database cluster state: *shut down$'
        test ! -e "$PGDATA/postmaster.pid"
        ;;
    open)
        test "$MICROPOD_PG_FIXTURE_MODE" = prepared
        test "$(id -u)" != 0
        test "$(cat "$PGDATA/PG_VERSION")" = 16
        # Only the benchmark's fixed synthetic account is supported. A unique
        # password is installed in the disposable writable layer of each job.
        case "$POSTGRES_PASSWORD" in ''|*[!0-9a-f]*) exit 2 ;; esac
        test "$POSTGRES_USER" = ci && test "$POSTGRES_DB" = ci
        printf "ALTER ROLE ci PASSWORD '%s';\n" "$POSTGRES_PASSWORD" |
            postgres --single -D "$PGDATA" template1 >/dev/null
        mark materialized
        exec /usr/local/bin/docker-entrypoint.sh postgres
        ;;
    postgres)
        case "$MICROPOD_PG_FIXTURE_MODE" in
            fresh) test "$PGDATA" = /var/lib/postgresql/data ;;
            fresh-overlay|prepared) test "$PGDATA" = /var/lib/micropod-fixture/data ;;
            *) echo "Unknown PostgreSQL fixture mode" >&2; exit 2 ;;
        esac
        mark begin
        if [ "$MICROPOD_PG_FIXTURE_MODE" = prepared ]; then
            exec gosu postgres micropod-pg-fixture open
        fi
        test ! -e "$PGDATA/PG_VERSION"
        exec /usr/local/bin/docker-entrypoint.sh "$@"
        ;;
    *) exit 2 ;;
esac
