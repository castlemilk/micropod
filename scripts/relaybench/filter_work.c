// Fixed-work Darwin check. Count real filter-change syscalls in the relay while
// driving readiness with two connected local socket pairs and no VM or listener.
#include <sys/event.h>
#include <signal.h>
#include <sys/ioctl.h>

static unsigned calls, filters;
static int counted_kevent(int q, const struct kevent *changes, int n, struct kevent *events,
                          int capacity, const struct timespec *timeout) {
    if (n) { ++calls; filters += (unsigned)n; }
    return kevent(q, changes, n, events, capacity, timeout);
}

#define kevent(...) counted_kevent(__VA_ARGS__)
#ifndef RELAY_SOURCE
#define RELAY_SOURCE "../../Sources/CPublishedTCP/PublishedTCP.c"
#endif
#include RELAY_SOURCE
#undef kevent

enum { PAYLOAD = 32 * 1024, SOCKET_BUFFER = 64 * 1024 };
static unsigned char payload[PAYLOAD], padding[4096];

static void check(bool ok, const char *message) {
    if (!ok) { fprintf(stderr, "%s (errno %d)\n", message, errno); exit(1); }
}

static void sockets(int fd[2]) {
    check(socketpair(AF_UNIX, SOCK_STREAM, 0, fd) == 0, "socketpair");
    int size = SOCKET_BUFFER;
    for (int i = 0; i < 2; ++i) {
        check(fcntl(fd[i], F_SETFL, O_NONBLOCK) == 0 &&
              setsockopt(fd[i], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0 &&
              setsockopt(fd[i], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) == 0, "socket options");
    }
}

static void expect_bytes(int fd, const unsigned char *expected, size_t count) {
    unsigned char got[4096];
    while (count) {
        ssize_t n = read(fd, got, count < sizeof(got) ? count : sizeof(got));
        check(n > 0 && memcmp(got, expected, (size_t)n) == 0, "payload mismatch or missing bytes");
        expected += n;
        count -= (size_t)n;
    }
}

static void result(const char *name) {
    printf(",\"%s\":{\"syscalls\":%u,\"filters\":%u}", name, calls, filters);
    calls = filters = 0;
}

// Start where the guest socket becomes writable after an asynchronous connect.
// The descriptor options and filter state used here are the ones finish_connect consumes.
static struct pair *stage(mp_tcp_listener *l, int client[2], int guest[2]) {
    sockets(client);
    sockets(guest);
    struct pair *p = calloc(1, sizeof(*p));
    check(p != NULL, "allocate pair");
    p->listener = l;
    p->client = (struct endpoint){ .watch = { STREAM, client[1] }, .pair = p };
    p->guest = (struct endpoint){ .watch = { STREAM, guest[1] }, .pair = p, .connecting = true };
    p->next = l->head;
    if (p->next) p->next->prev = p;
    l->head = p;
    ++l->active;
    check(watch_fd(l->relay, &p->client.watch, EVFILT_READ, EV_ADD | EV_DISABLE) == 0 &&
          watch_fd(l->relay, &p->guest.watch, EVFILT_READ, EV_ADD | EV_DISABLE) == 0 &&
          watch_fd(l->relay, &p->guest.watch, EVFILT_WRITE, EV_ADD) == 0, "stage async filters");
    return p;
}

static void drain(mp_tcp_relay *r) {
    // The split owner yields to dispatch between readiness changes (e.g. data,
    // then EOF). Drive those callbacks explicitly in this single-threaded fixture.
    for (int turn = 0; turn < 4; ++turn) mp_tcp_relay_drain(r, r->bulk.fd < 0 ? 2 : 0);
}

static size_t fill(int fd) {
    size_t filled = 0;
    ssize_t n;
    while ((n = write(fd, padding, sizeof(padding))) > 0) {
        filled += (size_t)n;
        check(filled < 1U << 20, "socket buffer was not bounded");
    }
    check(n < 0 && errno == EAGAIN && filled >= PAYLOAD, "destination backpressure");
    return filled;
}

static void consume_padding(int fd, size_t count) {
    while (count) {
        size_t chunk = count < sizeof(padding) ? count : sizeof(padding);
        expect_bytes(fd, padding, chunk);
        count -= chunk;
    }
}

static void exercise(bool dedicated, size_t room) {
    mp_tcp_relay *r = dedicated ? mp_tcp_relay_create_data("127.0.0.1") : mp_tcp_relay_create("127.0.0.1");
    check(r != NULL, "kqueue owner");
    mp_tcp_listener *l = new_listener(r, 8080, 0);
    check(l != NULL, "lease");
    int client[2], guest[2];
    struct pair *p = stage(l, client, guest);
    unsigned char marker = 93, unused;
    check(write(client[0], &marker, 1) == 1, "queue initial request");
    printf("{\"owner\":\"%s\",\"room_bytes\":%zu", dedicated ? "dedicated" : "split", room);
    calls = filters = 0;
    drain(r);
    check(l->head == p && !p->guest.connecting, "complete connect");
    expect_bytes(guest[0], &marker, 1);
    result("connect_complete");

    // Classify the download as bulk before counting the steady-state control.
    for (int i = 0; i < 2; ++i) {
        check(write(guest[0], payload, PAYLOAD) == PAYLOAD, "queue bulk payload");
        calls = filters = 0;
        drain(r);
        expect_bytes(client[0], payload, PAYLOAD);
    }
    result("unblocked_bulk");

    size_t filled = fill(client[1]);
    consume_padding(client[0], room);
    check(write(guest[0], payload, PAYLOAD) == PAYLOAD, "queue pressured payload");
    calls = filters = 0;
    drain(r);
    check(l->head == p && p->client.pending && p->client.length <= PAYLOAD, "save suffix");
    size_t sent = PAYLOAD - p->client.length;
    check(room ? sent > 0 && sent < PAYLOAD : sent == 0, "expected partial or blocked write");
    result("pause_reader");
    printf(",\"first_write_bytes\":%zu", sent);

    consume_padding(client[0], filled - room);
    expect_bytes(client[0], payload, sent);
    calls = filters = 0;
    drain(r);
    check(l->head == p && !p->client.pending, "flush suffix");
    expect_bytes(client[0], payload + sent, PAYLOAD - sent);
    result("resume_reader");

    // A FIN received behind a second pending suffix must follow its last byte.
    filled = fill(client[1]);
    check(write(guest[0], payload, PAYLOAD) == PAYLOAD && shutdown(guest[0], SHUT_WR) == 0, "queue data + FIN");
    drain(r);
    check(l->head == p && p->client.length == PAYLOAD, "FIN behind pending data");
    consume_padding(client[0], filled);
    check(read(client[0], &unused, 1) < 0 && errno == EAGAIN, "premature FIN");
    drain(r);
    expect_bytes(client[0], payload, PAYLOAD);
    check(read(client[0], &unused, 1) == 0, "forward guest FIN");
    check(write(client[0], &marker, 1) == 1 && shutdown(client[0], SHUT_WR) == 0, "reply after FIN");
    drain(r);
    expect_bytes(guest[0], &marker, 1);
    check(read(guest[0], &unused, 1) == 0 && !l->head, "close both halves");
    close(client[0]);
    close(guest[0]);

    // Fail the final registration after a successful prefix and reuse the owner.
    p = stage(l, client, guest);
#if defined(MICROPOD_BENCH_DEFER_HANDSHAKE_READS) && MICROPOD_BENCH_DEFER_HANDSHAKE_READS
    // EV_ADD can recreate a missing filter. Invalidate its descriptor instead.
    check(close(client[1]) == 0, "invalidate client filter descriptor");
    p->client.watch.fd = -1;
#else
    check(watch_fd(r, &p->client.watch, EVFILT_READ, EV_DELETE) == 0, "remove client filter");
#endif
    drain(r);
    check(!l->head && read(client[0], &unused, 1) == 0 && read(guest[0], &unused, 1) == 0,
          "failed group left a stream open");
    close(client[0]);
    close(guest[0]);
    p = stage(l, client, guest);
    check(write(guest[0], &marker, 1) == 1, "queue server-first marker");
    drain(r);
    expect_bytes(client[0], &marker, 1);
    filled = fill(client[1]);
    check(write(guest[0], payload, PAYLOAD) == PAYLOAD, "queue payload before revocation");
    drain(r);
    check(l->head == p && p->client.length == PAYLOAD, "revoke during backpressure");
    mp_tcp_release(l, NULL);
    consume_padding(client[0], filled);
    check(read(client[0], &unused, 1) == 0 && read(guest[0], &unused, 1) == 0, "revoke live lease");
    close(client[0]);
    close(guest[0]);
    mp_tcp_relay_destroy(r);
    printf(",\"verified_payload_bytes\":%u}\n", 4 * PAYLOAD + 3);
}

#ifdef CHECK_PENDING_COPY_PROFILE
// Built against the current stats struct. The historical filter controls use
// this fixture without the define, including versions that predate these fields.
static void exercise_pending_copies(bool profile) {
    mp_tcp_relay *accept = mp_tcp_relay_create("127.0.0.1");
    check(accept != NULL, "create accept owner");
    mp_tcp_listener *parent = new_listener(accept, 8080, profile);
    check(parent != NULL, "create parent listener");
    size_t expected_total = 0;
    for (unsigned i = 0; i < 2; ++i) {
        mp_tcp_relay *owner = mp_tcp_relay_create_data("127.0.0.1");
        check(owner != NULL, "create data owner");
        mp_tcp_listener *target = mp_tcp_target(owner, parent);
        check(target != NULL, "create target");
        int client[2], guest[2];
        struct pair *p = stage(target, client, guest);
        if (profile) atomic_fetch_add(&parent->group_active, 1); // normally done by adopt
        drain(owner);

        check(write(guest[0], payload, PAYLOAD) == PAYLOAD, "unpressured payload");
        drain(owner);
        expect_bytes(client[0], payload, PAYLOAD);
        check(!target->stats.pending_allocations && !target->stats.pending_copy_bytes, "full write copied");

        size_t filled = fill(client[1]), room = i ? PAYLOAD / 2 : 0;
        consume_padding(client[0], room);
        check(write(guest[0], payload, PAYLOAD) == PAYLOAD, "pressured payload");
        drain(owner);
        check(target->head == p && p->client.pending, "expected pending data");
        uint64_t blocked = target->stats.blocked_writes;
        pump(&p->guest, &p->client); // retry while the destination is still full
        check(!profile || target->stats.blocked_writes == blocked + 1, "expected blocked retry");

        consume_padding(client[0], filled - room);
        int prefix = -1;
        check(ioctl(client[0], FIONREAD, &prefix) == 0, "read delivered prefix length");
        check(room ? prefix > 0 && prefix < PAYLOAD : prefix == 0, "partial or blocked write");
        expect_bytes(client[0], payload, (size_t)prefix);
        size_t suffix = PAYLOAD - (size_t)prefix;
        drain(owner);
        expect_bytes(client[0], payload + prefix, suffix);
        mp_tcp_stats stats;
        mp_tcp_release(target, &stats);
        check(stats.pending_allocations == (unsigned)profile &&
              stats.pending_copy_bytes == (profile ? suffix : 0), "target pending-copy totals");
        expected_total += suffix;
        close(client[0]);
        close(guest[0]);
        mp_tcp_relay_destroy(owner);
    }
    mp_tcp_stats stats;
    mp_tcp_release(parent, &stats);
    check(stats.pending_allocations == (profile ? 2U : 0U) &&
          stats.pending_copy_bytes == (profile ? expected_total : 0), "merged pending-copy totals");
    printf("{\"profile\":%d,\"pending_allocations\":%llu,\"pending_copy_bytes\":%llu}\n",
           profile, stats.pending_allocations, stats.pending_copy_bytes);
    mp_tcp_relay_destroy(accept);
}
#endif

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    alarm(5);
    for (size_t i = 0; i < sizeof(payload); ++i) payload[i] = (unsigned char)(i * 193 + i / 257);
    for (int dedicated = 0; dedicated <= 1; ++dedicated) {
        exercise(dedicated, 0);
        exercise(dedicated, PAYLOAD / 2);
    }
#ifdef CHECK_PENDING_COPY_PROFILE
    exercise_pending_copies(false);
    exercise_pending_copies(true);
#endif
    return 0;
}
