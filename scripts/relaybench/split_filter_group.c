// Extend the existing real-kqueue transfer fixture with a cross-queue control.
#define main run_transfers
#include "filter_work.c"
#undef main

int main(void) {
    if (run_transfers() != 0) return 1;
    mp_tcp_relay *r = mp_tcp_relay_create("127.0.0.1");
    check(r && r->bulk.fd >= 0, "split owner");
    int a[2], b[2];
    sockets(a);
    sockets(b);
    struct pair p = {0};
    p.client = (struct endpoint){ .watch = { STREAM, a[0] }, .pair = &p };
    p.guest = (struct endpoint){ .watch = { STREAM, b[0] }, .pair = &p, .bulk_read = true };
    struct kevent changes[] = {filter_change(&p.client.watch, EVFILT_READ, EV_ADD),
                               filter_change(&p.guest.watch, EVFILT_READ, EV_ADD)};
    calls = filters = 0;
    check(update_stream_filters(r, changes, 2) == 0 && calls == 2 && filters == 2,
          "preserve split-queue registrations");
    check(write(a[1], "a", 1) == 1 && write(b[1], "b", 1) == 1, "queue two markers");
    struct timespec poll = {0};
    struct kevent ev;
    check(kevent(r->kq, NULL, 0, &ev, 1, &poll) == 1 && ev.udata == &p.client.watch,
          "retrieve nonbulk read from main queue");
    check(kevent(r->bulk.fd, NULL, 0, &ev, 1, &poll) == 1 && ev.udata == &p.guest.watch,
          "retrieve bulk read from bulk queue");
    expect_bytes(a[0], (const unsigned char *)"a", 1);
    expect_bytes(b[0], (const unsigned char *)"b", 1);
    close(a[0]); close(a[1]); close(b[0]); close(b[1]);
    mp_tcp_relay_destroy(r);
    puts("{\"mixed_queue_submissions\":2,\"correctly_routed_events\":2}");
    return 0;
}
