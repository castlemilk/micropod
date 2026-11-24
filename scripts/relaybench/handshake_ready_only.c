// Exercise the production connect-completion path with private stream descriptors.
#include <errno.h>
#include <unistd.h>
#include <sys/event.h>

static int watched_client = -1;
static unsigned client_reads, empty_reads, polls;

static ssize_t record_read(int fd, void *buffer, size_t count) {
    ssize_t n = read(fd, buffer, count);
    if (fd == watched_client) {
        ++client_reads;
        if (n < 0 && errno == EAGAIN) ++empty_reads;
    }
    return n;
}

static int record_poll(int q, const struct kevent *changes, int n, struct kevent *events,
                       int capacity, const struct timespec *timeout) {
    if (!n && capacity > 0) ++polls;
    return kevent(q, changes, n, events, capacity, timeout);
}

#define read(fd, data, length) record_read((fd), (data), (length))
#define FIXTURE_KEVENT record_poll
#define main filter_work_main
#include "filter_work.c"
#undef main
#undef read

static void one_event(mp_tcp_relay *r) {
    drain_data(r, 1);
}

static void transfer(int early, int fin, int pressured) {
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r != NULL, "create owner");
    mp_tcp_listener *l = new_listener(r, 8080, 0);
    check(l != NULL, "create lease");
    int client[2], guest[2];
    struct pair *p = stage(l, client, guest);
    const unsigned char request[] = {17, 103, 91, 8};
    size_t filled = 0;
    if (early) {
        check(write(client[0], request, sizeof(request)) == sizeof(request), "buffer request");
        if (fin) check(shutdown(client[0], SHUT_WR) == 0, "buffer FIN");
    }
    watched_client = client[1];
    client_reads = empty_reads = polls = 0;
    struct kevent connect_event;
    const struct timespec now = {0};
    check(record_poll(r->kq, NULL, 0, &connect_event, 1, &now) == 1 &&
          connect_event.udata == &p->guest.watch && connect_event.filter == EVFILT_WRITE, "connect ready");
    // Introduce backpressure only after capturing a genuine ready event.
    if (pressured) filled = fill(guest[1]);
    service_event(&connect_event);
    check(!p->guest.connecting && polls == 1, "guest completed in one poll");
    unsigned reads_at_connect = client_reads, empty_at_connect = empty_reads;
    if (!early) {
        check(write(client[0], request, sizeof(request)) == sizeof(request), "request after connect");
        if (fin) check(shutdown(client[0], SHUT_WR) == 0, "send FIN after connect");
    }
    // Let the initial request reach the relay before releasing destination pressure.
    for (int i = 0; !client_reads || client_reads == empty_reads; ++i) {
        check(i < 3, "bounded request read");
        one_event(r);
    }
    unsigned read_poll = polls;
    if (pressured) {
        check(p->guest.length == sizeof(request), "request parked under pressure");
        consume_padding(guest[0], filled);
        for (int i = 0; p->guest.length; ++i) {
            check(i < 3, "bounded pressure release");
            one_event(r);
        }
    }
    expect_bytes(guest[0], request, sizeof(request));
    unsigned delivery_poll = polls, reads_through_delivery = client_reads;
    if (!fin) check(shutdown(client[0], SHUT_WR) == 0, "send trailing FIN");
    drain(r);
    unsigned char marker = 231, byte;
    check(read(guest[0], &byte, 1) == 0, "guest receives client FIN");
    check(write(guest[0], &marker, 1) == 1 && shutdown(guest[0], SHUT_WR) == 0, "answer after FIN");
    drain(r);
    expect_bytes(client[0], &marker, 1);
    check(read(client[0], &byte, 1) == 0 && !l->active && !l->head, "reply FIN and retirement");
    printf("{\"request_before_connect\":%d,\"request_and_fin\":%d,\"pressured\":%d,"
           "\"client_reads_at_connect\":%u,\"eagain_at_connect\":%u,"
           "\"client_reads_to_delivery\":%u,\"request_read_poll\":%u,\"delivery_poll\":%u}\n",
           early, fin, pressured, reads_at_connect, empty_at_connect, reads_through_delivery, read_poll, delivery_poll);
    watched_client = -1;
    close(guest[0]); close(client[0]);
    mp_tcp_release(l, NULL);
    mp_tcp_relay_destroy(r);
}

int main(void) {
    alarm(5);
    signal(SIGPIPE, SIG_IGN);
    for (int early = 0; early < 2; ++early)
        for (int fin = 0; fin < 2; ++fin)
            for (int pressured = 0; pressured < 2; ++pressured)
                transfer(early, fin, pressured);
    return 0;
}
