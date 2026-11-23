// Count service ahead of a fresh reply that arrives during a returned bulk ready set.
#include <stdint.h>
#include <unistd.h>

enum { STREAMS = 16, MAX_OFFER = 512 * 1024 };
static const unsigned char marker = 97;
static int fresh_source, fresh_destination, bulk_writes, insert_after;
static uint64_t preceding_bytes;
static unsigned preceding_writes;
static int active, injected, served;

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
    if (++bulk_writes == insert_after) {
        if (write(fresh_source, &marker, 1) != 1) _exit(2);
        injected = 1;
    }
    return sent;
}

#define write(...) observe_write(__VA_ARGS__)
#define main unused_filter_fixture_main
#include "filter_work.c"
#undef main
#undef write

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
    fresh_destination = client[STREAMS][1];
    insert_after = position;
    bulk_writes = served = injected = 0;
    preceding_writes = preceding_bytes = 0;
    active = 1;
    mp_tcp_relay_drain(owner, 2);
    active = 0;
    check(injected && served, "fresh marker did not complete");
    expect_bytes(client[STREAMS][0], &marker, 1);
    for (int i = 0; i < STREAMS; ++i) expect_bytes(client[i][0], offered[i], offer);
    printf("{\"offer_per_stream\":%d,\"inject_after\":%d,\"writes_ahead\":%u,"
           "\"bytes_ahead\":%llu,\"bulk_writes\":%d,\"verified_bulk_bytes\":%d}\n",
           offer, position, preceding_writes, (unsigned long long)preceding_bytes, bulk_writes, STREAMS * offer);
    mp_tcp_release(lease, NULL);
    mp_tcp_relay_destroy(owner);
    for (int i = 0; i <= STREAMS; ++i) { close(client[i][0]); close(guest[i][0]); }
}

int main(void) {
    alarm(15);
    for (int offer = 128 * 1024; offer <= MAX_OFFER; offer *= 4) {
        run_late_reply(offer, 1);
        run_late_reply(offer, STREAMS);
    }
    return 0;
}
