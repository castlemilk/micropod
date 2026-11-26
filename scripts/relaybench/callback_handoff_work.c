// Hold the owner topology fixed and count bulk service before a queued serial handoff.
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>

enum { FLOWS = 8, OFFER = 1024 * 1024 };
static dispatch_queue_t queue;
static void enter_handoff(void *);
static int position, writes_done, writes_at_entry, writes_at_reply;
static uint64_t bytes_done, bytes_at_entry, bytes_at_reply;
static bool counting;
static int clients[FLOWS + 1][2], guests[FLOWS + 1][2];

static ssize_t relay_write(int fd, const void *data, size_t size) {
    ssize_t n = write(fd, data, size);
    if (!counting || n <= 0) return n;
    for (int i = 0; i < FLOWS; ++i) {
        if (clients[i][1] != fd) continue;
        ++writes_done;
        bytes_done += (size_t)n;
        if (writes_done == position) dispatch_async_f(queue, NULL, enter_handoff);
        return n;
    }
    if (fd == clients[FLOWS][1]) {
        if (n != 1 || writes_at_reply >= 0) _exit(2);
        writes_at_reply = writes_done;
        bytes_at_reply = bytes_done;
    }
    return n;
}

#define write(...) relay_write(__VA_ARGS__)
#define main unused_filter_fixture_main
#include "filter_work.c"
#undef main
#undef write

static mp_tcp_relay *owner;
static mp_tcp_listener *lease;
static const unsigned char marker = 91;
static unsigned char offered[FLOWS][OFFER];

static void drain_owner(void *context) {
    (void)context;
    mp_tcp_relay_drain(owner, 4);
}

static void enter_handoff(void *context) {
    (void)context;
    check(writes_at_entry < 0, "one handoff only");
    writes_at_entry = writes_done;
    bytes_at_entry = bytes_done;
    stage(lease, clients[FLOWS], guests[FLOWS]);
    check(write(guests[FLOWS][0], &marker, 1) == 1, "queue fresh reply");
}

static void reserve_room(int pair[2]) {
    int room = OFFER;
    for (int i = 0; i < 2; ++i) {
        check(setsockopt(pair[i], SOL_SOCKET, SO_SNDBUF, &room, sizeof(room)) == 0 &&
              setsockopt(pair[i], SOL_SOCKET, SO_RCVBUF, &room, sizeof(room)) == 0, "socket room");
    }
}

static void trial(int after) {
    position = after;
    writes_done = 0;
    bytes_done = bytes_at_entry = bytes_at_reply = 0;
    writes_at_entry = writes_at_reply = -1;
    clients[FLOWS][1] = -1;
    queue = dispatch_queue_create("micropod.fixture.data-owner", DISPATCH_QUEUE_SERIAL);
    owner = mp_tcp_relay_create_data("127.0.0.1");
    check(queue && owner, "create serial owner");
    lease = new_listener(owner, 8080, 0);
    check(lease != NULL, "lease");
    for (int i = 0; i < FLOWS; ++i) {
        stage(lease, clients[i], guests[i]);
        reserve_room(clients[i]);
        reserve_room(guests[i]);
    }
    dispatch_sync_f(queue, NULL, drain_owner);
    for (int i = 0; i < FLOWS; ++i) {
        check(write(guests[i][0], offered[i], LARGE_READ) == LARGE_READ, "prime bulk class");
    }
    dispatch_sync_f(queue, NULL, drain_owner);
    for (int i = 0; i < FLOWS; ++i) {
        expect_bytes(clients[i][0], offered[i], LARGE_READ);
        check(write(guests[i][0], offered[i], OFFER) == OFFER, "queue bulk");
    }

    counting = true;
    // The handoff, queued by the scored write, runs on the same serial queue before
    // the following synchronously submitted drain. No assumptions about elapsed time.
    for (int i = 0; i < 5; ++i) dispatch_sync_f(queue, NULL, drain_owner);
    counting = false;
    check(writes_at_entry >= position && writes_at_reply >= writes_at_entry &&
          bytes_done == (uint64_t)FLOWS * OFFER && writes_done == FLOWS * OFFER / CHUNK,
          "handoff, reply, or bulk delivery count");
    for (int i = 0; i < FLOWS; ++i) expect_bytes(clients[i][0], offered[i], OFFER);
    expect_bytes(clients[FLOWS][0], &marker, 1);
    for (int i = 0; i <= FLOWS; ++i) check(shutdown(guests[i][0], SHUT_WR) == 0, "guest FIN");
    for (int i = 0; i < 3; ++i) dispatch_sync_f(queue, NULL, drain_owner);
    for (int i = 0; i <= FLOWS; ++i) {
        unsigned char byte;
        check(read(clients[i][0], &byte, 1) == 0 && write(clients[i][0], &marker, 1) == 1 &&
              shutdown(clients[i][0], SHUT_WR) == 0, "forward FIN and reverse marker");
    }
    for (int i = 0; i < 3; ++i) dispatch_sync_f(queue, NULL, drain_owner);
    for (int i = 0; i <= FLOWS; ++i) {
        unsigned char byte;
        expect_bytes(guests[i][0], &marker, 1);
        check(read(guests[i][0], &byte, 1) == 0, "reverse FIN");
        close(clients[i][0]);
        close(guests[i][0]);
    }
    check(lease->active == 0, "retire all flows");
    printf("{\"budget\":%d,\"enqueue_after_write\":%d,\"bulk_writes\":%d,\"bulk_bytes\":%llu,"
           "\"bulk_bytes_after_enqueue_before_entry\":%llu,\"bulk_bytes_after_enqueue_before_reply\":%llu}\n",
           mp_tcp_data_callback_events(4), position, writes_done, (unsigned long long)bytes_done,
           (unsigned long long)(bytes_at_entry - (uint64_t)position * CHUNK),
           (unsigned long long)(bytes_at_reply - (uint64_t)position * CHUNK));
    mp_tcp_release(lease, NULL);
    mp_tcp_relay_destroy(owner);
    dispatch_release(queue);
}

int main(void) {
    alarm(20);
    for (int i = 0; i < FLOWS; ++i)
        for (int j = 0; j < OFFER; ++j) offered[i][j] = (unsigned char)(i * 61 + j * 17 + j / 251);
    const int positions[] = {1, 16, 24, 25, 31};
    for (size_t i = 0; i < sizeof(positions) / sizeof(positions[0]); ++i) trial(positions[i]);
    return 0;
}
