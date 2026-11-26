// Private UNIX listeners feed the stock accept loop and handoff callback.
#include <sys/un.h>
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

static mp_tcp_listener *listener(mp_tcp_relay *relay, const char *path, struct accept_role *role) {
    mp_tcp_listener *lease = new_listener(relay, 8080, 0);
    check(lease != NULL, "allocate listener");
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    check(strlcpy(addr.sun_path, path, sizeof(addr.sun_path)) < sizeof(addr.sun_path), "socket path");
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    check(fd >= 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0, "private listener fd");
    check(bind(fd, (struct sockaddr *)&addr, SUN_LEN(&addr)) == 0 && listen(fd, 64) == 0, "private UNIX listener");
    lease->watch.fd = fd;
    check(watch_fd(relay, &lease->watch, EVFILT_READ, EV_ADD) == 0, "lease registration");
    mp_tcp_set_handoff(lease, handoff, role);
    return lease;
}

static struct client_slot offer(const char *path, unsigned char id) {
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    strlcpy(addr.sun_path, path, sizeof(addr.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    check(fd >= 0 && connect(fd, (struct sockaddr *)&addr, SUN_LEN(&addr)) == 0 &&
          write(fd, &id, 1) == 1 && shutdown(fd, SHUT_WR) == 0, "queue request and FIN");
    return (struct client_slot){fd, id};
}

static void run(const char *directory, int sparse_at, int busy_count) {
    char busypath[104], sparsepath[104];
    snprintf(busypath, sizeof(busypath), "%s/busy", directory);
    snprintf(sparsepath, sizeof(sparsepath), "%s/sparse", directory);
    mp_tcp_relay *relay = mp_tcp_relay_create("127.0.0.1");
    check(relay != NULL, "create owner");
    struct accept_role busy = {false}, sparse = {true};
    mp_tcp_listener *hot = listener(relay, busypath, &busy);
    mp_tcp_listener *cold = listener(relay, sparsepath, &sparse);
    struct client_slot clients[BURST + 1];
    int total = 0;
    for (int i = 0; i <= busy_count; ++i) {
        if (i == sparse_at) clients[total++] = offer(sparsepath, 250);
        if (i < busy_count) clients[total++] = offer(busypath, i + 1);
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
    check(unlink(busypath) == 0 && unlink(sparsepath) == 0, "remove private sockets");
}

int main(int argc, char **argv) {
    alarm(15);
    check(argc == 2, "private fixture directory");
    run(argv[1], -1, BURST);
    run(argv[1], 0, BURST);
    run(argv[1], 1, BURST);
    run(argv[1], BURST / 2, BURST);
    run(argv[1], BURST, BURST);
    run(argv[1], 1, 1);
    return 0;
}
