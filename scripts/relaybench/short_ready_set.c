// Standalone, single-threaded Darwin experiment. Only anonymous UNIX socket pairs are used.
#include <sys/event.h>
#include <sys/time.h>
#include <stdbool.h>
#include <unistd.h>

static int empty_polls, polls, callbacks;
static size_t read_cap;
static bool yield_short, end_turn;

static int measured_kevent(int fd, const struct kevent *changes, int nchanges,
                           struct kevent *events, int maxevents, const struct timespec *timeout) {
    bool ready_poll = !changes && !nchanges && events && maxevents > 0;
    // Returning no events ends the current drain before its next kernel poll.
    // Registration and fixtures' outer readiness never pass through this branch.
    if (ready_poll && end_turn) return 0;
    int n = kevent(fd, changes, nchanges, events, maxevents, timeout);
    if (ready_poll) {
        ++polls;
        if (n == 0) ++empty_polls;
        end_turn = yield_short && n > 0 && n < maxevents;
    }
    return n;
}
static ssize_t capped_read(int fd, void *buf, size_t len) {
    return read(fd, buf, read_cap && len > read_cap ? read_cap : len);
}
#define kevent(...) measured_kevent(__VA_ARGS__)
#define read(...) capped_read(__VA_ARGS__)
#include "../../Sources/CPublishedTCP/PublishedTCP.c"
#undef read
#undef kevent

enum { WIDTH = 16, PAYLOAD = 4096, ROUNDS = 256 };
static unsigned char input[WIDTH][PAYLOAD], output[PAYLOAD];

static void check(bool ok, const char *message) {
    if (!ok) { fprintf(stderr, "%s (errno %d)\n", message, errno); exit(1); }
}

static void run(int width, size_t cap) {
    int guest[WIDTH][2], client[WIDTH][2];
    mp_tcp_relay *owner = mp_tcp_relay_create_data("127.0.0.1");
    check(owner != NULL, "create worker");
    mp_tcp_listener *listener = new_listener(owner, 8080, 0);
    check(listener != NULL, "create listener record");
    int outer = kqueue();
    struct kevent watch;
    EV_SET(&watch, owner->kq, EVFILT_READ, EV_ADD, 0, 0, NULL);
    check(outer >= 0 && kevent(outer, &watch, 1, NULL, 0, NULL) == 0, "watch owner descriptor");
    for (int i = 0; i < width; ++i) {
        check(socketpair(AF_UNIX, SOCK_STREAM, 0, guest[i]) == 0 &&
              socketpair(AF_UNIX, SOCK_STREAM, 0, client[i]) == 0, "create socket pairs");
        check(fcntl(guest[i][1], F_SETFL, O_NONBLOCK) == 0 &&
              fcntl(client[i][1], F_SETFL, O_NONBLOCK) == 0, "nonblocking relay endpoints");
        struct pair *p = calloc(1, sizeof(*p));
        check(p != NULL, "allocate pair");
        p->listener = listener;
        p->next = listener->head;
        if (p->next) p->next->prev = p;
        listener->head = p;
        ++listener->active;
        p->client = (struct endpoint){ .watch = {STREAM, client[i][1]}, .pair = p };
        p->guest = (struct endpoint){ .watch = {STREAM, guest[i][1]}, .pair = p };
        check(watch_fd(owner, &p->client.watch, EVFILT_READ, EV_ADD) == 0 &&
              watch_fd(owner, &p->guest.watch, EVFILT_READ, EV_ADD) == 0, "register pair");
        for (size_t j = 0; j < PAYLOAD; ++j) input[i][j] = (unsigned char)(i * 61 + j);
    }
    // The outer kqueue models level-triggered notification, excluding libdispatch scheduling.
    const struct timespec immediate = {0};
    read_cap = cap;
    int64_t cpu_ns = 0;
    int scored_polls = 0, scored_empty = 0, scored_callbacks = 0;
    for (int wave = 0; wave <= ROUNDS; ++wave) {
        bool fin = wave == ROUNDS; // Untimed EOF-with-data control after measurement.
        polls = empty_polls = callbacks = 0;
        for (int i = 0; i < width; ++i) {
            input[i][0] = (unsigned char)wave;
            check(write(guest[i][0], input[i], PAYLOAD) == PAYLOAD, "seed wave");
            if (fin) check(shutdown(guest[i][0], SHUT_WR) == 0, "guest FIN");
        }
        uint64_t start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
        for (;;) {
            struct kevent event;
            int ready = kevent(outer, NULL, 0, &event, 1, &immediate);
            check(ready >= 0, "outer readiness");
            if (!ready) break;
            check(++callbacks <= 128, "bounded callback progress");
            end_turn = false;
            mp_tcp_relay_drain(owner, 2);
        }
        uint64_t elapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start;
        if (!fin) {
            cpu_ns += elapsed;
            scored_polls += polls;
            scored_empty += empty_polls;
            scored_callbacks += callbacks;
        }
        for (int i = 0; i < width; ++i) {
            size_t offset = 0;
            while (offset < PAYLOAD) {
                ssize_t n = recv(client[i][0], output + offset, PAYLOAD - offset, MSG_DONTWAIT);
                check(n > 0, "forward entire payload");
                offset += (size_t)n;
            }
            check(memcmp(output, input[i], PAYLOAD) == 0, "same bytes and stream order");
            if (fin) check(recv(client[i][0], output, 1, MSG_DONTWAIT) == 0, "EOF after trailing bytes");
        }
    }
    printf("{\"streams\":%d,\"read_cap\":%zu,\"bytes\":%d,\"waves\":%d,\"inner_polls\":%d,"
           "\"empty_inner_polls\":%d,\"callback_deliveries\":%d,\"owner_cpu_ns\":%lld}\n",
           width, cap, width * PAYLOAD * ROUNDS, ROUNDS, scored_polls, scored_empty, scored_callbacks,
           (long long)cpu_ns);
    close(outer);
    mp_tcp_release(listener, NULL);
    mp_tcp_relay_destroy(owner);
    for (int i = 0; i < width; ++i) { close(guest[i][0]); close(client[i][0]); }
}

int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "stock") && strcmp(argv[1], "yield-short"))) return 2;
    yield_short = !strcmp(argv[1], "yield-short");
    alarm(10);
    run(1, 0);         // One fresh-size batch per notification.
    run(WIDTH, 0);     // Burst from the 16 streams per owner in the stock two-worker topology.
    run(WIDTH, 1024);  // Four reads required on each of 16 continuously ready streams.
    return 0;
}
