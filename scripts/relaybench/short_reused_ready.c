// Compare real kqueue scheduling of fresh and previously bulk-classified directions.
#include <sys/event.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>

enum { MAX_FLOWS = 34, LARGE_PIECE = 64 * 1024, SMALL_PIECE = 4096 };
static unsigned char content[MAX_FLOWS][LARGE_PIECE + SMALL_PIECE + 1];
static int destination[MAX_FLOWS], flows, tagged, fresh;
static int tracking, grow_after_hint, appended, tagged_source, tagged_endpoint;
static size_t sized[MAX_FLOWS], writes_seen[MAX_FLOWS], first_bytes[MAX_FLOWS];
static size_t first_write[MAX_FLOWS], delivered, polls, tagged_snapshot;

static int poll_ready(int q, const struct kevent *changes, int n, struct kevent *events,
                      int capacity, const struct timespec *timeout) {
    int count = kevent(q, changes, n, events, capacity, timeout);
    if (!tracking || !events || count <= 0) return count;
    ++polls;
    for (int i = 0; i < count; ++i) {
        if (events[i].ident != (uintptr_t)tagged_endpoint || events[i].filter != EVFILT_READ || tagged_snapshot)
            continue;
        if (events[i].data != (intptr_t)sized[tagged]) abort();
        tagged_snapshot = (size_t)events[i].data;
        // Leave the real event untouched as additional bytes arrive on this flow.
        if (grow_after_hint) {
            if (write(tagged_source, content[tagged] + sized[tagged], LARGE_PIECE) != LARGE_PIECE) abort();
            sized[tagged] += LARGE_PIECE;
            appended = 1;
        }
    }
    return count;
}

static ssize_t record_write(int fd, const void *buffer, size_t length) {
    ssize_t sent = write(fd, buffer, length);
    if (!tracking || sent <= 0) return sent;
    for (int i = 0; i < flows; ++i) {
        if (destination[i] != fd) continue;
        if (!writes_seen[i]++) {
            first_bytes[i] = delivered;
            first_write[i] = (size_t)sent;
        }
        delivered += (size_t)sent;
        return sent;
    }
    abort();
}

#define FIXTURE_KEVENT poll_ready
#define write(...) record_write(__VA_ARGS__)
#define main unused_filter_fixture_main
#include "filter_work.c"
#undef main
#undef write
#undef FIXTURE_KEVENT

static void increase_capacity(int fd) {
    int size = 512 * 1024;
    check(setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0 &&
          setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) == 0, "socket capacity");
}

static void run_case(int background, int tails, size_t tagged_bytes, int grow) {
    flows = background + 2;
    int large_flows = background - tails;
    tagged = background;
    fresh = background + 1;
    int client[MAX_FLOWS][2], guest[MAX_FLOWS][2];
    struct pair *pairs[MAX_FLOWS];
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r && mp_tcp_relay_read_bytes(r) == 256 * 1024, "flat owner at stock read cap");
    mp_tcp_listener *l = new_listener(r, 8080, 0);
    check(l != NULL, "lease");
    for (int i = 0; i < flows; ++i) {
        pairs[i] = stage(l, client[i], guest[i]);
        for (size_t j = 0; j < sizeof(content[i]); ++j) content[i][j] = (unsigned char)(i * 31 + j + j / 251);
        for (int j = 0; j < 2; ++j) { increase_capacity(client[i][j]); increase_capacity(guest[i][j]); }
    }
    drain(r);
    for (int i = 0; i < fresh; ++i)
        check(write(guest[i][0], content[i], LARGE_READ) == LARGE_READ, "prime bulk direction");
    drain(r);
    for (int i = 0; i < flows; ++i) {
        if (i != fresh) expect_bytes(client[i][0], content[i], LARGE_READ);
        check(pairs[i]->guest.bulk_read == (i != fresh), "classification");
        destination[i] = client[i][1];
        sized[i] = i < large_flows ? LARGE_PIECE : SMALL_PIECE;
        if (i == tagged) sized[i] = tagged_bytes;
        if (i == fresh) sized[i] = 1;
        writes_seen[i] = 0;
        check(write(guest[i][0], content[i], sized[i]) == (ssize_t)sized[i], "queue complete payload");
    }
    tagged_endpoint = guest[tagged][1];
    tagged_source = guest[tagged][0];
    tagged_snapshot = delivered = polls = 0;
    grow_after_hint = grow;
    appended = 0;
    tracking = 1;
    mp_tcp_relay_drain(r, 2);
    tracking = 0;
    size_t expected = 0;
    for (int i = 0; i < flows; ++i) {
        expect_bytes(client[i][0], content[i], sized[i]);
        expected += sized[i];
        check(writes_seen[i] && pairs[i]->guest.bulk_read == (i != fresh), "all streams served in callback");
        check(shutdown(guest[i][0], SHUT_WR) == 0, "guest FIN");
    }
    check(delivered == expected && appended == grow && tagged_snapshot == tagged_bytes, "readiness and totals");
    drain(r);
    for (int i = 0; i < flows; ++i) {
        unsigned char marker;
        check(read(client[i][0], &marker, 1) == 0, "ordered EOF");
        check(write(client[i][0], content[i], 1) == 1 && shutdown(client[i][0], SHUT_WR) == 0,
              "reverse marker and FIN");
    }
    drain(r);
    for (int i = 0; i < flows; ++i) {
        unsigned char end;
        expect_bytes(guest[i][0], content[i], 1);
        check(read(guest[i][0], &end, 1) == 0, "reverse EOF");
        close(client[i][0]); close(guest[i][0]);
    }
    check(!l->active && !l->head, "retired all flows");
    mp_tcp_release(l, NULL);
    mp_tcp_relay_destroy(r);
    printf("{\"background\":%d,\"tails\":%d,\"hint_bytes\":%zu,\"late_bytes\":%d,"
           "\"verified_bytes\":%zu,\"nonempty_polls\":%zu,\"ahead_of_new_bytes\":%zu,"
           "\"ahead_of_tagged_bytes\":%zu,\"ahead_of_first_large_bytes\":%zu,"
           "\"tagged_first_write\":%zu,\"tagged_writes\":%zu}\n",
           background, tails, tagged_snapshot, appended ? LARGE_PIECE : 0, delivered, polls,
           first_bytes[fresh], first_bytes[tagged], first_bytes[0], first_write[tagged], writes_seen[tagged]);
}

int main(void) {
    alarm(15);
    run_case(16, 0, 17, 0);
    run_case(16, 8, 17, 0);
    run_case(16, 0, SMALL_PIECE, 0);
    run_case(16, 0, SMALL_PIECE + 1, 0);
    run_case(16, 0, 17, 1);
    run_case(32, 0, 17, 0);
    return 0;
}
