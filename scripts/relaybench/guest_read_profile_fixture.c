// Exercise an established stream synchronously on its actual Swift release queue.
// Socketpairs replace the dial and listen steps. The native pumps, release fence,
// worker merge, and lease JSON all run normally.
#define mp_tcp_listen unused_tcp_listen
#define mp_tcp_release native_release
#define main unused_filter_fixture_main
#include "filter_work.c"
#undef main
#undef mp_tcp_release
#undef mp_tcp_listen

enum { KIB = 1024, MAX_OFFER = 512 * KIB + 1 };
static unsigned char offered[MAX_OFFER];

mp_tcp_listener *mp_tcp_listen(mp_tcp_relay *relay, uint16_t host, uint16_t guest, uint16_t *port, int profile) {
    *port = host;
    return new_listener(relay, guest, profile);
}

static void enlarge(int fd[2]) {
    int size = 1024 * KIB;
    for (int i = 0; i < 2; ++i)
        check(setsockopt(fd[i], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0 &&
              setsockopt(fd[i], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) == 0, "enlarge socketpair");
}

static struct pair *connect_pair(mp_tcp_listener *l, int client[2], int guest[2]) {
    struct pair *p = stage(l, client, guest);
    if (l->profile && l->parent) atomic_fetch_add(&l->parent->group_active, 1); // normally done by adopt
    drain(l->relay);
    check(!p->guest.connecting, "establish stream");
    return p;
}

static void exercise_supply(mp_tcp_listener *l) {
    mp_tcp_relay *r = l->relay;
    unsigned cap = mp_tcp_relay_read_bytes(r);
    int client[2], guest[2];
    struct pair *p = connect_pair(l, client, guest);
    enlarge(client);
    enlarge(guest);
    for (size_t i = 0; i < sizeof(offered); ++i) offered[i] = (unsigned char)(i * 13 + i / 251);
    const size_t offers[] = {128*KIB, 128*KIB+1, 256*KIB-1, 256*KIB, 256*KIB+1, 512*KIB, 512*KIB+1};
    for (size_t i = 0; i < sizeof(offers) / sizeof(offers[0]); ++i) {
        size_t n = offers[i];
        check(write(guest[0], offered, n) == (ssize_t)n, "supply guest offer");
        drain(r);
        expect_bytes(client[0], offered, n);
    }
    check(write(client[0], offered, MAX_OFFER) == MAX_OFFER, "supply reverse offer");
    drain(r);
    expect_bytes(guest[0], offered, MAX_OFFER);

    // Even a too-large advisory hint must not count a short read or EAGAIN as a cap fill.
    struct kevent stale = filter_change(&p->guest.watch, EVFILT_READ, 0);
    stale.data = cap + 1;
    check(write(guest[0], offered, 17) == 17, "queue short read");
    service_event(&stale);
    expect_bytes(client[0], offered, 17);
    service_event(&stale);
    check(shutdown(guest[0], SHUT_WR) == 0, "queue FIN");
    drain(r);
    char eof;
    check(read(client[0], &eof, 1) == 0, "forward FIN");
    close(client[0]);
    close(guest[0]);

    p = connect_pair(l, client, guest);
    size_t filled = fill(client[1]);
    check(write(guest[0], offered, PAYLOAD) == PAYLOAD, "queue pressured guest offer");
    drain(r);
    check(p->client.pending && p->client.length == PAYLOAD, "expected a blocked guest write");
    pump(&p->guest, &p->client);
    check(p->client.length == PAYLOAD, "retry remained blocked");
    consume_padding(client[0], filled);
    drain(r);
    expect_bytes(client[0], offered, PAYLOAD);
    check(!p->client.pending, "flush pending retry");
    close(client[0]);
    close(guest[0]);
}

void mp_tcp_release(mp_tcp_listener *l, mp_tcp_stats *stats) {
    if (l->parent || !l->handoff) exercise_supply(l);
    if (!l->profile) {
        check(!l->stats.guest_read_bytes && !l->stats.guest_full_cap_reads &&
              !l->stats.guest_full_cap_ready_above_cap, "supply counters changed without profiling");
        for (unsigned i = 0; i < 4; ++i)
            check(!l->stats.guest_reads_by_size[i], "supply bin changed without profiling");
    }
    native_release(l, stats);
}
