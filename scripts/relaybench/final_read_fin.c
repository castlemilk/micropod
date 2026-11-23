// Compare the stock and patched owners on real Darwin EVFILT_READ events.
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <unistd.h>

static int guest_reader = -1, client_writer = -1;
static unsigned reads, empty_reads, writes, partial_writes, polls, delivered_events, disabled_reads;
static unsigned eof_payload_events, eof_empty_events;
static bool limit_first_read, flag_final_error;
static size_t first_eof_bytes;

static ssize_t record_read(int fd, void *data, size_t len) {
    if (fd == guest_reader && limit_first_read && reads == 0 && len > 17) len = 17;
    ssize_t n = read(fd, data, len);
    if (fd == guest_reader) {
        ++reads;
        if (n == 0) ++empty_reads;
    }
    return n;
}

static ssize_t record_write(int fd, const void *data, size_t len) {
    ssize_t n = write(fd, data, len);
    if (fd == client_writer) {
        ++writes;
        if (n >= 0 && (size_t)n < len) ++partial_writes;
    }
    return n;
}

static int record_kevent(int kq, const struct kevent *changes, int count,
                         struct kevent *events, int capacity, const struct timespec *timeout) {
    int n = kevent(kq, changes, count, events, capacity, timeout);
    if (guest_reader < 0 || n < 0) return n;
    for (int i = 0; i < count; ++i) {
        if (changes[i].ident == (uintptr_t)guest_reader && changes[i].filter == EVFILT_READ &&
            (changes[i].flags & EV_DISABLE)) ++disabled_reads;
    }
    if (events && capacity > 0) ++polls;
    for (int i = 0; i < n; ++i) {
        ++delivered_events;
        struct kevent *e = &events[i];
        if (e->ident != (uintptr_t)guest_reader || e->filter != EVFILT_READ || !(e->flags & EV_EOF)) continue;
        if (e->data == 0) ++eof_empty_events;
        if (e->data > 0) {
            if (eof_payload_events++ == 0) first_eof_bytes = (size_t)e->data;
            // Diagnostic fault on the data-bearing event only. The final
            // zero-byte event is still the real one returned by the kernel.
            if (flag_final_error) e->fflags = ECONNRESET;
        }
    }
    return n;
}

#define read(...) record_read(__VA_ARGS__)
#define write(...) record_write(__VA_ARGS__)
#define FIXTURE_KEVENT record_kevent
#define main filter_fixture_main
#include "filter_work.c"
#undef main
#undef read
#undef write

static unsigned char body[CHUNK + 113], got[sizeof(body)];
static void enlarge(int pair[2]) {
    int n = 1024 * 1024;
    for (int i = 0; i < 2; ++i) {
        check(setsockopt(pair[i], SOL_SOCKET, SO_SNDBUF, &n, sizeof(n)) == 0 &&
              setsockopt(pair[i], SOL_SOCKET, SO_RCVBUF, &n, sizeof(n)) == 0, "socket buffer");
    }
}

static void scenario(const char *name, size_t bytes, bool delayed, bool pressure, bool cap_read, bool error) {
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r != NULL, "new data owner");
    mp_tcp_listener *l = new_listener(r, 8080, 0);
    check(l != NULL, "new lease");
    int client[2], guest[2];
    struct pair *p = stage(l, client, guest);
    enlarge(guest);
    if (!pressure) enlarge(client);
    const unsigned char request[] = {0x06, 0xed, 0x43};
    check(write(client[0], request, sizeof(request)) == sizeof(request), "request");
    mp_tcp_relay_drain(r, 2);
    expect_bytes(guest[0], request, sizeof(request));

    reads = empty_reads = writes = partial_writes = polls = delivered_events = disabled_reads = 0;
    first_eof_bytes = eof_payload_events = eof_empty_events = 0;
    limit_first_read = cap_read;
    flag_final_error = error;
    guest_reader = guest[1];
    client_writer = client[1];
    if (bytes) check(write(guest[0], body, bytes) == (ssize_t)bytes, "offer whole response");
    if (delayed) {
        mp_tcp_relay_drain(r, 2);
        check(!p->guest.eof, "open response was half-closed early");
    }
    check(shutdown(guest[0], SHUT_WR) == 0, "orderly guest FIN");
    size_t total = 0;
    bool finished = false, saw_pending = false;
    for (int turn = 0; turn < 100 && !finished; ++turn) {
        mp_tcp_relay_drain(r, 2);
        check(l->head == p, "reverse direction lost");
        if (p->client.length) {
            saw_pending = true;
            check(!p->guest.eof, "half-close before pending write");
        }
        unsigned char chunk[8192];
        ssize_t n;
        while ((n = read(client[0], chunk, sizeof(chunk))) > 0) {
            check(total + (size_t)n <= bytes, "unexpected response length");
            memcpy(got + total, chunk, (size_t)n);
            total += (size_t)n;
        }
        finished = n == 0;
        check(finished || errno == EAGAIN, "response read failed");
    }
    check(finished && p->guest.eof && total == bytes && memcmp(body, got, bytes) == 0,
          "stream bytes or FIN incorrect");
    check(!pressure || (saw_pending && partial_writes > 0), "expected actual partial write");
    printf("{\"case\":\"%s\",\"bytes\":%zu,\"reads\":%u,\"zero_reads\":%u,\"writes\":%u,"
           "\"partial_writes\":%u,\"ready_polls\":%u,\"ready_events\":%u,\"disable_reads\":%u,"
           "\"data_fin_events\":%u,\"empty_fin_events\":%u,\"first_fin_bytes\":%zu}\n",
           name, bytes, reads, empty_reads, writes, partial_writes, polls, delivered_events,
           disabled_reads, eof_payload_events, eof_empty_events, first_eof_bytes);
    guest_reader = client_writer = -1;
    check(write(client[0], request, sizeof(request)) == sizeof(request) &&
          shutdown(client[0], SHUT_WR) == 0, "reply after receiving FIN");
    mp_tcp_relay_drain(r, 2);
    expect_bytes(guest[0], request, sizeof(request));
    check(read(guest[0], got, 1) == 0 && !l->head && !l->active && !r->retired, "reverse FIN and reap");
    close(client[0]);
    close(guest[0]);
    mp_tcp_release(l, NULL);
    mp_tcp_relay_destroy(r);
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "qualify") == 0) return filter_fixture_main();
    if (argc != 1) return 2;
    alarm(10);
    for (size_t i = 0; i < sizeof(body); ++i) body[i] = (unsigned char)(i * 37 + i / 257);
    scenario("empty", 0, false, false, false, false);
    scenario("short", 148, false, false, false, false);
    scenario("over-cap", sizeof(body), false, false, false, false);
    scenario("delayed-fin", 148, true, false, false, false);
    scenario("limited-read", 148, false, false, true, false);
    scenario("short-write", CHUNK, false, true, false, false);
    scenario("flagged-terminal-event", 148, false, false, false, true);
    return 0;
}
