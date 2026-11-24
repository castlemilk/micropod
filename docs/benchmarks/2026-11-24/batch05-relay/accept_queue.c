// Anonymous UNIX readiness queues stand in for listen sockets. Stock kqueue dispatch,
// accept_ready, handoff and the connected descriptor used for each reply are real.
#include <sys/socket.h>
#include <errno.h>
#include <stdlib.h>
#include <sys/event.h>
#include <unistd.h>
#include <stdint.h>
#include <stdbool.h>

static bool measured;
static int ready_events, nonempty_polls;
static int counted_poll(int q, const struct kevent *change, int n, struct kevent *events,
                        int capacity, const struct timespec *timeout) {
    int got = kevent(q, change, n, events, capacity, timeout);
    if (measured && got > 0 && events) {
        ++nonempty_polls;
        ready_events += got;
    }
    return got;
}
struct queue_model { int ends[2], pending[41], queued, taken; };
static struct queue_model channels[2];

static int take_connection(int fd, struct sockaddr *addr, socklen_t *size) {
    (void)addr; (void)size;
    struct queue_model *channel = &channels[fd == channels[1].ends[0]];
    if (fd != channel->ends[0]) abort();
    unsigned char token;
    ssize_t n = read(fd, &token, 1);
    if (n == -1 && errno == EAGAIN) return -1;
    if (n != 1 || channel->taken >= channel->queued) abort();
    return channel->pending[channel->taken++];
}
#define accept(...) take_connection(__VA_ARGS__)
#define FIXTURE_KEVENT counted_poll
#define main unused_filter_fixture_main
#include "filter_work.c"
#undef main

enum { BURST = 40 };
struct client_slot { int fd; unsigned char id; };
struct accept_role { bool sparse; };
static int busy_seen, ahead_of_sparse, handed_off;

static void handoff(void *context, int fd, uint64_t accepted_at) {
    (void)accepted_at;
    struct accept_role *role = context;
    unsigned char id;
    check(read(fd, &id, 1) == 1, "read exact request marker");
    if (role->sparse) {
        check(ahead_of_sparse < 0 && id == 250, "unique sparse request");
        ahead_of_sparse = busy_seen;
    } else {
        ++busy_seen;
    }
    ++handed_off;
    check(write(fd, &id, 1) == 1 && shutdown(fd, SHUT_WR) == 0, "reply and FIN");
    close(fd);
}

static mp_tcp_listener *listener(mp_tcp_relay *relay, struct queue_model *channel, struct accept_role *role) {
    mp_tcp_listener *lease = new_listener(relay, 8080, 0);
    check(lease != NULL, "allocate listener");
    *channel = (struct queue_model){0};
    sockets(channel->ends);
    lease->watch.fd = channel->ends[0];
    check(watch_fd(relay, &lease->watch, EVFILT_READ, EV_ADD) == 0, "lease registration");
    mp_tcp_set_handoff(lease, handoff, role);
    return lease;
}

static struct client_slot offer(struct queue_model *channel, unsigned char id) {
    int pair[2];
    sockets(pair);
    check(channel->queued < BURST + 1, "offer capacity");
    channel->pending[channel->queued++] = pair[1];
    check(write(pair[0], &id, 1) == 1 && shutdown(pair[0], SHUT_WR) == 0, "request and FIN");
    check(write(channel->ends[1], &id, 1) == 1, "ready token");
    return (struct client_slot){pair[0], id};
}

static void run(int sparse_at, int busy_count) {
    mp_tcp_relay *relay = mp_tcp_relay_create("127.0.0.1");
    check(relay != NULL, "create owner");
    struct accept_role busy = {false}, sparse = {true};
    mp_tcp_listener *hot = listener(relay, &channels[0], &busy);
    mp_tcp_listener *cold = listener(relay, &channels[1], &sparse);
    struct client_slot clients[BURST + 1];
    int total = 0;
    for (int i = 0; i <= busy_count; ++i) {
        if (i == sparse_at) clients[total++] = offer(&channels[1], 250);
        if (i < busy_count) clients[total++] = offer(&channels[0], i + 1);
    }
    ahead_of_sparse = -1;
    busy_seen = handed_off = ready_events = nonempty_polls = 0;
    measured = true;
    for (int i = 0; i < BURST + 2 && handed_off < total; ++i) mp_tcp_relay_drain(relay, 2);
    measured = false;
    check(handed_off == total && busy_seen == busy_count, "all first offers accepted");
    for (int i = 0; i < total; ++i) {
        unsigned char result;
        check(read(clients[i].fd, &result, 1) == 1 && result == clients[i].id &&
              read(clients[i].fd, &result, 1) == 0, "distinct reply and FIN");
        close(clients[i].fd);
    }
    printf("{\"busy_offered\":%d,\"sparse_queued_after_busy\":%d,\"verified_replies\":%d,"
           "\"busy_handoffs_before_sparse\":%d,\"ready_events\":%d,\"nonempty_polls\":%d}\n",
           busy_count, sparse_at, total, ahead_of_sparse, ready_events, nonempty_polls);
    mp_tcp_release(hot, NULL); mp_tcp_release(cold, NULL); mp_tcp_relay_destroy(relay);
    for (int i = 0; i < 2; ++i) {
        check(channels[i].queued == channels[i].taken, "queue drained");
        close(channels[i].ends[1]);
    }
}

int main(void) {
    alarm(15);
    run(-1, BURST);
    run(0, BURST);
    run(1, BURST);
    run(BURST / 2, BURST);
    run(BURST, BURST);
    run(1, 1);
    return 0;
}
