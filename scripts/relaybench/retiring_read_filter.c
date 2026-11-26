// Count the filter submissions and explicit shutdowns for two successive FINs.
#include <errno.h>
#include <stdbool.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <unistd.h>

static int terminal_error_fd = -1;
static unsigned injected_errors, eof_reads, write_shutdowns;

static ssize_t observed_read(int fd, void *buf, size_t size) {
    ssize_t n = read(fd, buf, size);
    if (n == 0) ++eof_reads;
    return n;
}

static int observed_shutdown(int fd, int how) {
    int status = shutdown(fd, how);
    if (status == 0 && how == SHUT_WR) ++write_shutdowns;
    return status;
}

static int observed_kevent(int q, const struct kevent *changes, int count, struct kevent *events,
                           int capacity, const struct timespec *timeout) {
    int n = kevent(q, changes, count, events, capacity, timeout);
    for (int i = 0; i < n; ++i) {
        if (events[i].ident == (uintptr_t)terminal_error_fd && events[i].filter == EVFILT_READ &&
            (events[i].flags & EV_EOF) && events[i].data == 0) {
            events[i].fflags = ECONNRESET;
            ++injected_errors;
        }
    }
    return n;
}

#define read observed_read
#define shutdown observed_shutdown
#define FIXTURE_KEVENT observed_kevent
#define main filter_fixture_main
#include "filter_work.c"
#undef main
#undef read
#undef shutdown

static void scenario(bool dedicated, bool guest_first, bool pressure, bool reset) {
    mp_tcp_relay *r = dedicated ? mp_tcp_relay_create_data("127.0.0.1") : mp_tcp_relay_create("127.0.0.1");
    check(r != NULL, "create owner");
    mp_tcp_listener *l = new_listener(r, 8080, false);
    check(l != NULL, "create listener");
    int client[2], guest[2];
    struct pair *p = stage(l, client, guest);
    drain(r);
    check(l->head == p && !p->guest.connecting, "establish stream");
    int *first = guest_first ? guest : client, *last = guest_first ? client : guest;
    struct endpoint *first_end = guest_first ? &p->guest : &p->client;

    unsigned char first_byte = 127, unused;
    calls = filters = eof_reads = write_shutdowns = 0;
    check(write(first[0], &first_byte, 1) == 1 && shutdown(first[0], SHUT_WR) == 0, "first payload and FIN");
    drain(r);
    expect_bytes(last[0], &first_byte, 1);
    check(read(last[0], &unused, 1) == 0 && l->head == p && l->active == 1 && first_end->eof &&
          !opposite(first_end)->eof && calls == 1 && filters == 1 && eof_reads == 1 && write_shutdowns == 1,
          "first FIN must forward and keep the reverse direction available");
    unsigned first_calls = calls;

    // Queue data after the first FIN. In the pressured case its tail has to
    // survive until a later writable callback, ahead of the final FIN.
    size_t body = pressure ? sizeof(payload) : 148;
    size_t filled = pressure ? fill(first[1]) : 0;
    if (pressure) consume_padding(first[0], PAYLOAD / 2);
    calls = filters = eof_reads = write_shutdowns = injected_errors = 0;
    check(write(last[0], payload, body) == (ssize_t)body, "reverse payload");
    if (reset) {
        drain(r);
        expect_bytes(first[0], payload, body);
        terminal_error_fd = last[1];
    }
    check(shutdown(last[0], SHUT_WR) == 0, "final FIN");
    drain(r);
    if (pressure) {
        check(l->head == p && first_end->pending && first_end->length > 0 && first_end->length < body &&
              eof_reads == 0 && write_shutdowns == 0, "pending suffix must delay final FIN and retirement");
        size_t prefix = body - first_end->length;
        consume_padding(first[0], filled - PAYLOAD / 2);
        expect_bytes(first[0], payload, prefix);
        check(read(first[0], &unused, 1) < 0 && errno == EAGAIN, "no EOF before the retained suffix");
        drain(r);
        expect_bytes(first[0], payload + prefix, body - prefix);
    } else if (!reset) {
        expect_bytes(first[0], payload, body);
    }
    check(read(first[0], &unused, 1) == 0 && !l->head && !l->active && !r->retired &&
          eof_reads == 1 && write_shutdowns == (reset ? 0U : 1U) && injected_errors == (reset ? 1U : 0U),
          "terminal event, explicit shutdown and owner reap");
    printf("{\"owner\":\"%s\",\"first_fin\":\"%s\",\"scenario\":\"%s\",\"bytes\":%zu,"
           "\"first_filter_calls\":%u,\"last_filter_calls\":%u,\"last_zero_reads\":%u,"
           "\"last_write_shutdowns\":%u}\n",
           dedicated ? "flat" : "split", guest_first ? "guest" : "client",
           reset ? "flagged_error" : pressure ? "partial_write" : "ordinary",
           body + 1, first_calls, calls, eof_reads, write_shutdowns);
    terminal_error_fd = -1;
    close(client[0]);
    close(guest[0]);
    mp_tcp_release(l, NULL);
    mp_tcp_relay_destroy(r);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    alarm(10);
    for (size_t i = 0; i < sizeof(payload); ++i) payload[i] = (unsigned char)(i * 193 + i / 257);
    for (int dedicated = 0; dedicated < 2; ++dedicated) {
        for (int guest_first = 0; guest_first < 2; ++guest_first) {
            scenario(dedicated, guest_first, false, false);
            scenario(dedicated, guest_first, true, false);
            scenario(dedicated, guest_first, false, true);
        }
    }
    return 0;
}
