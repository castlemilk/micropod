// Count service ahead of a fresh reply that arrives during a returned bulk ready set.
#include <sys/event.h>
#include <stdint.h>
#include <unistd.h>

enum { STREAMS = 16, MAX_OFFER = 1024 * 1024 };
static const unsigned char marker = 97;
static int fresh_source, fresh_endpoint, fresh_destination, bulk_writes, insert_after;
static int poll_width, bulk_reads, poll_count, empty_polls;
static uint64_t preceding_bytes;
static unsigned preceding_writes;
static int active, injected, served;

static int observe_poll(int q, const struct kevent *changes, int n, struct kevent *events,
                        int capacity, const struct timespec *timeout) {
    if (!active || !poll_width || !events || capacity <= 0)
        return kevent(q, changes, n, events, capacity, timeout);
    int limit = capacity < poll_width ? capacity : poll_width;
    int count = kevent(q, changes, n, events, limit, timeout);
    ++poll_count;
    if (count == 0) ++empty_polls;
    if (count < 0) _exit(2);
    return count;
}

static ssize_t observe_read(int fd, void *buf, size_t len) {
    ssize_t n = read(fd, buf, len);
    if (active && fd != fresh_endpoint && n > 0) ++bulk_reads;
    return n;
}

static void insert_marker(void) {
    if (write(fresh_source, &marker, 1) != 1) _exit(2);
    injected = 1;
}

static ssize_t observe_write(int fd, const void *bytes, size_t length) {
    ssize_t sent = write(fd, bytes, length);
    if (!active || sent <= 0) return sent;
    if (fd == fresh_destination) {
        if (!injected || served || sent != 1 || *(const unsigned char *)bytes != marker) _exit(2);
        served = 1;
        return sent;
    }
    // During this drain the fixture has only bulk payload writes and the one marker.
    if (injected && !served) {
        preceding_bytes += (size_t)sent;
        ++preceding_writes;
    }
    if (++bulk_writes == insert_after) insert_marker();
    return sent;
}

#define FIXTURE_KEVENT observe_poll
#define read(...) observe_read(__VA_ARGS__)
#define write(...) observe_write(__VA_ARGS__)
#define main unused_filter_fixture_main
#include "filter_work.c"
#undef main
#undef write
#undef read
#undef FIXTURE_KEVENT

static unsigned char offered[STREAMS][MAX_OFFER];

static void roomy(int fds[2]) {
    int size = 1024 * 1024;
    for (int i = 0; i < 2; ++i)
        check(setsockopt(fds[i], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0 &&
              setsockopt(fds[i], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) == 0, "roomy sockets");
}

static void run_late_reply(int offer, int position) {
    mp_tcp_relay *owner = mp_tcp_relay_create_data("127.0.0.1");
    check(owner != NULL, "create data owner");
    mp_tcp_listener *lease = new_listener(owner, 8080, 0);
    check(lease != NULL, "create lease");
    int client[STREAMS + 1][2], guest[STREAMS + 1][2];
    struct pair *pairs[STREAMS + 1];
    for (int i = 0; i <= STREAMS; ++i) {
        pairs[i] = stage(lease, client[i], guest[i]);
        if (i < STREAMS) { roomy(client[i]); roomy(guest[i]); }
    }
    mp_tcp_relay_drain(owner, 2);
    for (int i = 0; i <= STREAMS; ++i) check(!pairs[i]->guest.connecting, "connect staged flow");

    for (int i = 0; i < STREAMS; ++i) {
        for (int j = 0; j < offer; ++j) offered[i][j] = (unsigned char)(i * 61 + j * 17 + j / 251);
        check(write(guest[i][0], offered[i], LARGE_READ) == LARGE_READ, "prime bulk classification");
    }
    mp_tcp_relay_drain(owner, 2);
    for (int i = 0; i < STREAMS; ++i) {
        expect_bytes(client[i][0], offered[i], LARGE_READ);
        check(pairs[i]->guest.bulk_read, "expected bulk endpoint");
        check(write(guest[i][0], offered[i], offer) == offer, "queue complete offered payload");
    }
    check(!pairs[STREAMS]->guest.bulk_read, "fresh endpoint classified as bulk");
    fresh_source = guest[STREAMS][0];
    fresh_endpoint = guest[STREAMS][1];
    fresh_destination = client[STREAMS][1];
    insert_after = position;
    bulk_reads = bulk_writes = served = injected = 0;
    poll_count = empty_polls = 0;
    preceding_writes = preceding_bytes = 0;
    active = 1;
    if (position == 0) insert_marker();
    mp_tcp_relay_drain(owner, 2);
    active = 0;
    check(injected && served, "fresh marker did not complete");
    expect_bytes(client[STREAMS][0], &marker, 1);
    for (int i = 0; i < STREAMS; ++i) expect_bytes(client[i][0], offered[i], offer);
    if (poll_width) {
        for (int i = 0; i <= STREAMS; ++i)
            check(shutdown(guest[i][0], SHUT_WR) == 0, "close guest send half");
        mp_tcp_relay_drain(owner, 2);
        unsigned char byte;
        for (int i = 0; i <= STREAMS; ++i) {
            check(read(client[i][0], &byte, 1) == 0, "expected ordered FIN");
            check(write(client[i][0], &marker, 1) == 1 && shutdown(client[i][0], SHUT_WR) == 0,
                  "send reverse marker and FIN");
        }
        mp_tcp_relay_drain(owner, 2);
        for (int i = 0; i <= STREAMS; ++i) {
            expect_bytes(guest[i][0], &marker, 1);
            check(read(guest[i][0], &byte, 1) == 0, "expected reverse FIN");
        }
        check(lease->active == 0, "all streams retired");
    }
    printf("{\"offer_per_stream\":%d,\"inject_after\":%d,\"writes_ahead\":%u,"
           "\"bytes_ahead\":%llu,\"bulk_writes\":%d,\"verified_bulk_bytes\":%d",
           offer, position, preceding_writes, (unsigned long long)preceding_bytes, bulk_writes, STREAMS * offer);
    if (poll_width)
        printf(",\"poll_width\":%d,\"polls\":%d,\"empty_polls\":%d,\"bulk_reads\":%d",
               poll_width, poll_count, empty_polls, bulk_reads);
    puts("}");
    mp_tcp_release(lease, NULL);
    mp_tcp_relay_destroy(owner);
    for (int i = 0; i <= STREAMS; ++i) { close(client[i][0]); close(guest[i][0]); }
}

int main(int argc, char **argv) {
    alarm(30);
    if (argc == 2 && (!strcmp(argv[1], "8") || !strcmp(argv[1], "24"))) {
        poll_width = atoi(argv[1]);
        for (int offer = 128 * 1024; offer <= MAX_OFFER; offer *= 2) {
            if (offer == 256 * 1024) continue;
            for (int position = 0; position <= STREAMS; ++position)
                run_late_reply(offer, position);
        }
    } else if (argc == 1) {
        for (int offer = 128 * 1024; offer <= 512 * 1024; offer *= 4) {
            run_late_reply(offer, 1);
            run_late_reply(offer, STREAMS);
        }
    } else {
        return 2;
    }
    return 0;
}
