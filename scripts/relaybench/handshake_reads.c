// Adopt real anonymous stream pairs using the production setup, drain and half-close logic.
// Only guest socket creation, TCP-only options and the connect result are substituted.
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdbool.h>
#include <stdlib.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <unistd.h>

static int guest_fd = -1, connect_result, reject_read_fd = -1;
static unsigned change_calls, submitted_filters;

static int guest_socket(int domain, int type, int protocol) {
    if (domain != AF_INET || type != SOCK_STREAM || protocol != 0 || guest_fd < 0) abort();
    int ready = guest_fd;
    guest_fd = -1;
    return ready;
}
static int connect_result_for(int fd, const struct sockaddr *target, socklen_t length) {
    if (fd < 0 || !target || length != sizeof(struct sockaddr_in)) abort();
    if (!connect_result) return 0;
    errno = connect_result;
    return -1;
}
static int socket_option(int fd, int level, int option, const void *value, socklen_t size) {
    if (level == IPPROTO_TCP && (option == TCP_NODELAY || option == TCP_CONNECTIONTIMEOUT)) return 0;
    return setsockopt(fd, level, option, value, size);
}
static int filter_call(int q, const struct kevent *changes, int n, struct kevent *events,
                       int count, const struct timespec *timeout) {
    if (n) {
        ++change_calls;
        submitted_filters += n;
        for (int i = 0; reject_read_fd >= 0 && i < n; ++i) {
            if (changes[i].ident == (uintptr_t)reject_read_fd && changes[i].filter == EVFILT_READ &&
                (changes[i].flags & EV_ENABLE)) {
                if (i && kevent(q, changes, i, NULL, 0, NULL) != 0) abort();
                errno = ENOMEM;
                return -1;
            }
        }
    }
    return kevent(q, changes, n, events, count, timeout);
}
#define socket(...) guest_socket(__VA_ARGS__)
#define connect(...) connect_result_for(__VA_ARGS__)
#define setsockopt(...) socket_option(__VA_ARGS__)
#define kevent(...) filter_call(__VA_ARGS__)
#ifndef RELAY_SOURCE
#define RELAY_SOURCE "../../Sources/CPublishedTCP/PublishedTCP.c"
#endif
#include RELAY_SOURCE
#undef kevent
#undef setsockopt
#undef connect
#undef socket

enum { REQUEST = 98, RESPONSE = 148, ROUNDS = 512 };
static uint64_t setup_cpu_ns, relay_cpu_ns, setup_changes, setup_filters;

static void check(bool ok, const char *message) {
    if (!ok) { fprintf(stderr, "%s (errno %d)\n", message, errno); exit(1); }
}
static void sockets(int pair[2]) {
    check(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, "create anonymous stream");
}
static void expect_bytes(int fd, const unsigned char *bytes, size_t size) {
    unsigned char buf[RESPONSE];
    while (size) {
        ssize_t n = recv(fd, buf, size < sizeof(buf) ? size : sizeof(buf), MSG_DONTWAIT);
        check(n > 0 && memcmp(buf, bytes, (size_t)n) == 0, "complete ordered response");
        size -= (size_t)n;
        bytes += n;
    }
}
static void expect_eof(int fd) {
    char byte;
    check(recv(fd, &byte, 1, MSG_DONTWAIT) == 0, "remaining peer must observe EOF");
}
static void expect_empty(int fd) {
    char byte;
    check(recv(fd, &byte, 1, MSG_DONTWAIT) < 0 && errno == EAGAIN, "data escaped before connect completion");
}
static void settle(mp_tcp_relay *r) {
    // The split owner may yield between data and FIN. Timed work uses a dedicated owner.
    int turns = r->bulk.fd < 0 ? 1 : 4;
    for (int i = 0; i < turns; ++i) mp_tcp_relay_drain(r, 2);
}
static uint64_t cpu(void) { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }

static void fresh(mp_tcp_listener *l, int outcome, unsigned sequence, bool qualify) {
    int client[2], guest[2];
    sockets(client); sockets(guest);
    unsigned char request[REQUEST], response[RESPONSE];
    for (unsigned i = 0; i < REQUEST; ++i) request[i] = (unsigned char)(sequence + 3 * i);
    for (unsigned i = 0; i < RESPONSE; ++i) response[i] = (unsigned char)(sequence + 11 * i);
    check(write(client[0], request, REQUEST) == REQUEST, "queue initial request");
    guest_fd = guest[1];
    connect_result = outcome;
    change_calls = submitted_filters = 0;
    uint64_t start = cpu();
    mp_tcp_adopt(l, client[1], clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    if (qualify) expect_empty(guest[0]);
    settle(l->relay);
    uint64_t setup = cpu() - start;
    setup_cpu_ns += setup;
    setup_changes += change_calls;
    setup_filters += submitted_filters;
    check(l->active == 1 && !l->head->guest.connecting && guest_fd == -1, "establish one flow");
    expect_bytes(guest[0], request, REQUEST);
    check(write(guest[0], response, RESPONSE) == RESPONSE && shutdown(guest[0], SHUT_WR) == 0,
          "queue response and FIN");
    start = cpu();
    settle(l->relay);
    uint64_t reply = cpu() - start;
    expect_bytes(client[0], response, RESPONSE);
    expect_eof(client[0]);
    check(shutdown(client[0], SHUT_WR) == 0, "close client write half");
    start = cpu();
    settle(l->relay);
    relay_cpu_ns += setup + reply + cpu() - start;
    expect_eof(guest[0]);
    check(!l->head && !l->relay->retired && !l->active, "connection reaped");
    close(client[0]); close(guest[0]);
}

static void interrupted(mp_tcp_relay *r, bool revoke) {
    mp_tcp_listener *l = new_listener(r, 8080, 0);
    check(l != NULL, "new test lease");
    int client[2], guest[2];
    sockets(client); sockets(guest);
    guest_fd = guest[1]; connect_result = EINPROGRESS;
    check(write(client[0], "x", 1) == 1 && shutdown(client[0], SHUT_WR) == 0, "queued data and FIN");
    mp_tcp_adopt(l, client[1], clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    expect_empty(guest[0]);
    if (!revoke) {
        reject_read_fd = client[1];
        settle(r);
        reject_read_fd = -1;
        check(!l->active && !l->head, "failed registration closed both endpoints");
    }
    mp_tcp_release(l, NULL);
    expect_eof(guest[0]);
    char byte;
    ssize_t n = recv(client[0], &byte, 1, MSG_DONTWAIT);
    check(n == 0 || (n < 0 && errno == ECONNRESET), "no response on failed or revoked connect");
    close(guest[0]); close(client[0]);
}

static void pressured_first_payload(mp_tcp_listener *l, bool upload) {
    int guest[2], client[2];
    sockets(guest); sockets(client);
    guest_fd = guest[1]; connect_result = EINPROGRESS;
    mp_tcp_adopt(l, client[1], clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    // For an upload, consume the handshake event before filling that same
    // guest socket. The stream must register a new writable watch to resume.
    if (upload) {
        settle(l->relay);
        struct kevent event;
        struct timespec now = {0};
        check(kevent(l->relay->kq, NULL, 0, &event, 1, &now) == 0, "no idle handshake wakeup");
    }
    int *src = upload ? client : guest, *dst = upload ? guest : client;
    unsigned char pad[4096] = {0};
    size_t filled = 0;
    ssize_t n;
    while ((n = send(dst[1], pad, sizeof(pad), MSG_DONTWAIT)) > 0) {
        filled += (size_t)n;
        check(filled < (1U << 22), "bounded pressured socket capacity");
    }
    check(filled > 0 && n < 0 && errno == EAGAIN, "full outgoing buffer");
    static const unsigned char marker[] = "first-payload-after-connect";
    check(write(src[0], marker, sizeof(marker)) == sizeof(marker) && shutdown(src[0], SHUT_WR) == 0,
          "pressured payload and FIN");
    settle(l->relay);
    check(l->head != NULL, "pressured flow retained");
    struct endpoint *to = upload ? &l->head->guest : &l->head->client;
    check(to->pending && to->length == sizeof(marker), "pause pressured read");
    while (filled) {
        size_t step = filled < sizeof(pad) ? filled : sizeof(pad);
        expect_bytes(dst[0], pad, step);
        filled -= step;
    }
    settle(l->relay);
    expect_bytes(dst[0], marker, sizeof(marker));
    expect_eof(dst[0]);
    check(write(dst[0], marker, 1) == 1 && shutdown(dst[0], SHUT_WR) == 0, "reply after pressured half close");
    settle(l->relay);
    expect_bytes(src[0], marker, 1);
    expect_eof(src[0]);
    check(!l->active && !l->head, "pressured flow retired");
    close(guest[0]); close(client[0]);
}

static void retry(mp_tcp_listener *l) {
    int client[2], old[2], next[2];
    sockets(client); sockets(old); sockets(next);
    guest_fd = old[1]; connect_result = EHOSTUNREACH;
    unsigned char req[] = {0x17, 0x93, 0x25};
    check(write(client[0], req, sizeof(req)) == sizeof(req) && shutdown(client[0], SHUT_WR) == 0, "queue once before retry");
    mp_tcp_adopt(l, client[1], clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    check(l->head && l->head->retry_pending && l->stats.connect_retries == 1, "retry scheduled");
    expect_eof(old[0]);
    guest_fd = next[1]; connect_result = EINPROGRESS;
    struct pollfd poller = { .fd = l->relay->kq, .events = POLLIN };
    check(poll(&poller, 1, 2000) == 1, "real retry timer");
    settle(l->relay);
    check(l->head && !l->head->guest.connecting && l->stats.recovered == 1, "retry connected");
    expect_bytes(next[0], req, sizeof(req));
    expect_eof(next[0]);
    check(write(next[0], req, sizeof(req)) == sizeof(req) && shutdown(next[0], SHUT_WR) == 0, "reverse reply after client FIN");
    settle(l->relay);
    expect_bytes(client[0], req, sizeof(req));
    expect_eof(client[0]);
    check(!l->head && !l->active, "retry flow retired");
    close(client[0]); close(old[0]); close(next[0]);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    bool split = !strcmp(argv[1], "qualify-split");
    bool qualify = split || !strcmp(argv[1], "qualify");
    if (!qualify && strcmp(argv[1], "measure")) return 2;
    check(pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0) == 0, "background thread");
    alarm(8);
    mp_tcp_relay *r = split ? mp_tcp_relay_create("127.0.0.1") : mp_tcp_relay_create_data("127.0.0.1");
    check(r != NULL, "data owner");
    mp_tcp_listener *l = new_listener(r, 8080, 0);
    check(l != NULL, "lease");
    if (qualify) {
        interrupted(r, true);
        interrupted(r, false);
        retry(l);
        pressured_first_payload(l, false);
        pressured_first_payload(l, true);
    }
    unsigned rounds = qualify ? 1 : ROUNDS;
    for (unsigned mode = 0; mode < 2; ++mode) {
        setup_cpu_ns = relay_cpu_ns = setup_changes = setup_filters = 0;
        for (unsigned i = 0; i < rounds; ++i) fresh(l, mode ? EINPROGRESS : 0, i, qualify);
        printf("{\"async\":%s,\"flows\":%u,\"setup_change_syscalls\":%llu,\"setup_filters\":%llu,"
               "\"setup_cpu_ns\":%llu,\"relay_cpu_ns\":%llu}\n", mode ? "true" : "false", rounds,
               (unsigned long long)setup_changes, (unsigned long long)setup_filters,
               (unsigned long long)setup_cpu_ns, (unsigned long long)relay_cpu_ns);
    }
    mp_tcp_release(l, NULL);
    mp_tcp_relay_destroy(r);
    return 0;
}
