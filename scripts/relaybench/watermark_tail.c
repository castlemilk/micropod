// The driver supplies the archived prototype and its matching header. No network listener is opened.
#include <pthread.h>
#include <pthread/qos.h>
#define RELAY_SOURCE "archive_lowat.c"
#define main unused_filter_test_main
#include "filter_work.c"
#undef main

static struct kevent event_for(mp_tcp_relay *r, struct watch *watch) {
    const struct timespec timeout = {1, 0};
    for (int attempt = 0; attempt < 4; ++attempt) {
        struct kevent events[4];
        int n = kevent(r->kq, NULL, 0, events, 4, &timeout);
        check(n > 0, "missing timer or stream event");
        int found = -1;
        for (int i = 0; i < n; ++i) {
            if (events[i].udata == watch) found = i;
            // A co-ready demotion timer is left unserviced when testing EOF above a short tail.
            else check(((struct watch *)events[i].udata)->kind == LOW_READY, "unexpected stream readiness");
        }
        if (found >= 0) return events[found];
    }
    check(false, "expected stream or timer event");
    abort();
}

static void case_tail(bool fin) {
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r != NULL, "create data owner");
    mp_tcp_listener *l = new_listener(r, 8080, 0);
    check(l != NULL, "create listener record");
    int client[2], guest[2];
    struct pair *p = stage(l, client, guest);
    drain(r);
    check(l->head == p && !p->guest.connecting, "complete connection");
    int buffer = 2 * MP_LOW;
    for (int i = 0; i < 2; ++i) {
        check(setsockopt(guest[i], SOL_SOCKET, SO_RCVBUF, &buffer, sizeof(buffer)) == 0 &&
              setsockopt(guest[i], SOL_SOCKET, SO_SNDBUF, &buffer, sizeof(buffer)) == 0,
              "input socket must hold threshold");
    }
    unsigned history = 0;
    while (history < CHUNK) {
        size_t step = history ? sizeof(payload) : 1;
        if (step > CHUNK - history) step = CHUNK - history;
        check(!p->guest.raised && write(guest[0], payload, step) == (ssize_t)step, "seed unpromoted flow");
        struct kevent event = event_for(r, &p->guest.watch);
        check(event.filter == EVFILT_READ && event.data == (intptr_t)step, "fresh or bulk readiness amount");
        service_event(&event);
        expect_bytes(client[0], payload, step);
        history += (unsigned)step;
    }
    check(p->guest.raised && !p->client.raised, "only guest direction promoted at exactly 256 KiB");
    const unsigned char trailer[] = "0123456789abcdef";
    check(write(guest[0], trailer, sizeof(trailer)) == sizeof(trailer), "queue short trailer");
    unsigned char extra;
    uint64_t waited_us = 0;
    if (fin) {
        check(shutdown(guest[0], SHUT_WR) == 0, "queue FIN behind trailer");
        struct kevent ready = event_for(r, &p->guest.watch);
        check(ready.flags & EV_EOF && ready.data == sizeof(trailer) && p->guest.raised, "unread EOF before timer demotion");
        service_event(&ready);
        expect_bytes(client[0], trailer, sizeof(trailer));
        check(read(client[0], &extra, 1) < 0 && errno == EAGAIN, "full data precedes propagated FIN");
        ready = event_for(r, &p->guest.watch);
        check(ready.flags & EV_EOF && ready.data == 0, "EOF after bytes consumed");
        service_event(&ready);
        check(read(client[0], &extra, 1) == 0, "peer observed FIN");
    } else {
        uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        struct kevent timer = event_for(r, &p->guest.low_timer);
        waited_us = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1000;
        check(timer.filter == EVFILT_TIMER && p->guest.raised, "one-shot promotion timer");
        check(read(client[0], &extra, 1) < 0 && errno == EAGAIN, "no premature forwarding");
        service_event(&timer);
        check(!p->guest.raised, "timer demotes short open flow");
        struct kevent ready = event_for(r, &p->guest.watch);
        check(!(ready.flags & EV_EOF) && ready.data == sizeof(trailer), "queued open trailer wakes after demotion");
        service_event(&ready);
        expect_bytes(client[0], trailer, sizeof(trailer));
        check(read(client[0], &extra, 1) < 0 && errno == EAGAIN, "open peer remains open");
    }
    check(write(client[0], trailer, 1) == 1, "queue reverse marker");
    struct kevent ready = event_for(r, &p->client.watch);
    service_event(&ready);
    expect_bytes(guest[0], trailer, 1);
    mp_tcp_release(l, NULL);
    mp_tcp_relay_destroy(r);
    close(client[0]);
    close(guest[0]);
    printf("{\"fin\":%s,\"promoted_history_bytes\":%u,\"watermark_bytes\":%d,\"short_tail_bytes\":%zu,\"reverse_marker_bytes\":1,\"wait_for_demotion_us\":%llu}\n",
           fin ? "true" : "false", history, MP_LOW, sizeof(trailer), (unsigned long long)waited_us);
}

int main(void) {
    check(pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0) == 0, "background test thread");
    alarm(3);
    for (size_t i = 0; i < sizeof(payload); ++i) payload[i] = (unsigned char)(i * 193 + i / 257);
    case_tail(false);
    case_tail(true);
    return 0;
}
