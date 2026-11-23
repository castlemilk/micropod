// Observe the real pump syscalls while draining one Darwin ready set at a time.
#include <stdlib.h>
#include <unistd.h>

static size_t expected_cap;
static int tracing, reads_seen, writes_seen, sources[2];
static ssize_t amounts[2];

static ssize_t trace_read(int fd, void *buffer, size_t capacity) {
    ssize_t n = read(fd, buffer, capacity);
    if (tracing) {
        if (capacity != expected_cap || reads_seen != writes_seen || reads_seen >= 2 || n <= 0) abort();
        sources[reads_seen] = fd;
        amounts[reads_seen++] = n;
    }
    return n;
}

static ssize_t trace_write(int fd, const void *buffer, size_t count) {
    ssize_t n = write(fd, buffer, count);
    if (tracing) {
        if (reads_seen != writes_seen + 1 || n != amounts[writes_seen] || count != (size_t)n) abort();
        ++writes_seen;
    }
    return n;
}

#define read(...) trace_read(__VA_ARGS__)
#define write(...) trace_write(__VA_ARGS__)
#define main unused_filter_fixture_main
#include "filter_work.c"
#undef main
#undef write
#undef read

static void ready(mp_tcp_relay *owner, int count) {
    reads_seen = writes_seen = 0;
    tracing = 1;
    drain_data(owner, count);
    tracing = 0;
    check(reads_seen == count && writes_seen == count, "one read and one write per ready endpoint");
}

int main(int argc, char **argv) {
    check(argc == 2, "expected read capacity");
    expected_cap = (size_t)atoi(argv[1]) * 1024;
    alarm(5);
    static const unsigned char marker[] = "fresh-on-new-flow";
    enum { BODY = 768 * 1024 + 17, MARKER = sizeof(marker) - 1 };
    static unsigned char body[BODY];
    for (size_t j = 0; j < BODY; ++j) body[j] = (unsigned char)(j * 193 + j / 257);
    mp_tcp_relay *owner = mp_tcp_relay_create_data("127.0.0.1");
    check(owner != NULL, "create owner");
    mp_tcp_listener *l = new_listener(owner, 8080, 0);
    check(l != NULL, "create lease");
    int client[2][2], guest[2][2];
    struct pair *bulk = stage(l, client[0], guest[0]);
    struct pair *fresh = stage(l, client[1], guest[1]);
    drain(owner);
    int size = 1024 * 1024;
    check(setsockopt(guest[0][0], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0 &&
          setsockopt(guest[0][1], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) == 0 &&
          setsockopt(client[0][1], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0 &&
          setsockopt(client[0][0], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) == 0, "bulk buffers");

    check(write(guest[0][0], body, LARGE_READ) == LARGE_READ, "prime classification");
    ready(owner, 1);
    expect_bytes(client[0][0], body, LARGE_READ);
    check(bulk->guest.bulk_read && !fresh->guest.bulk_read, "classify only the bulk flow");
    check(write(guest[0][0], body, BODY) == BODY, "queue bulk bytes");
    size_t offset = 0;
    int turns = 0;
    while (offset < BODY) {
        // A fresh marker arrives between the first and second established bulk reads.
        int mixed = turns == 1;
        if (mixed) check(write(guest[1][0], marker, MARKER) == MARKER, "queue fresh marker");
        ready(owner, 1 + mixed);
        if (mixed) {
            check(sources[0] == guest[1][1] && amounts[0] == MARKER, "fresh flow serviced first");
            expect_bytes(client[1][0], marker, MARKER);
        }
        size_t n = BODY - offset < expected_cap ? BODY - offset : expected_cap;
        check(sources[mixed] == guest[0][1] && amounts[mixed] == (ssize_t)n, "bulk read length");
        expect_bytes(client[0][0], body + offset, n);
        offset += n;
        ++turns;
    }
    printf("%zu %d %d %d\n", expected_cap, turns, BODY, MARKER);
    mp_tcp_release(l, NULL);
    mp_tcp_relay_destroy(owner);
    for (int i = 0; i < 2; ++i) { close(client[i][0]); close(guest[i][0]); }
    return 0;
}
