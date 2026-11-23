// Exercise the production Swift handoff and C adoption without opening TCP sockets.
#include <dispatch/dispatch.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int mailbox, peers[8];
static dispatch_semaphore_t accepts, resume_owner;
static atomic_bool hold_owner;
static atomic_uint clocks;

static uint64_t counted_clock(clockid_t clock_id) {
    if (clock_id == CLOCK_UPTIME_RAW) atomic_fetch_add(&clocks, 1);
    return clock_gettime_nsec_np(clock_id);
}

static int local_socket(int family, int type, int protocol) {
    if (family != AF_UNIX) abort();
    return socket(family, type, protocol);
}

static int next_descriptor(int mailbox_fd, struct sockaddr *unused_addr, socklen_t *unused_length) {
    (void)unused_addr;
    (void)unused_length;
    int descriptor;
    if (recv(mailbox_fd, &descriptor, sizeof(descriptor), MSG_DONTWAIT) < 0) return -1;
    dispatch_semaphore_signal(accepts);
    return descriptor;
}

static int setup_option(int fd, int level, int option, const void *value, socklen_t size) {
    // Record adoption first. Stall client setup on the real serial owner so later
    // adoptions accumulate behind it until the test has submitted every descriptor.
    if (level == IPPROTO_TCP && option == TCP_NODELAY && atomic_load(&hold_owner))
        dispatch_semaphore_wait(resume_owner, DISPATCH_TIME_FOREVER);
    return setsockopt(fd, level, option, value, size);
}

#define socket(...) local_socket(__VA_ARGS__)
#define accept(...) next_descriptor(__VA_ARGS__)
#define setsockopt(...) setup_option(__VA_ARGS__)
#define clock_gettime_nsec_np(...) counted_clock(__VA_ARGS__)
#define mp_tcp_listen unused_tcp_listener
#include "../../Sources/CPublishedTCP/PublishedTCP.c"
#undef mp_tcp_listen
#undef clock_gettime_nsec_np
#undef setsockopt
#undef accept
#undef socket

mp_tcp_listener *mp_tcp_listen(mp_tcp_relay *relay, uint16_t host, uint16_t guest, uint16_t *port, int profile) {
    mp_tcp_listener *listener = new_listener(relay, guest, profile);
    int fds[2];
    if (!listener || socketpair(AF_UNIX, SOCK_DGRAM, 0, fds) != 0) abort();
    mailbox = fds[0];
    listener->watch.fd = fds[1];
    if (watch_fd(relay, &listener->watch, EVFILT_READ, EV_ADD) < 0) abort();
    *port = host;
    return listener;
}

void fixture_submit(int workers) {
    atomic_store(&clocks, 0);
    accepts = dispatch_semaphore_create(0);
    resume_owner = dispatch_semaphore_create(0);
    atomic_store(&hold_owner, workers > 0);
    for (size_t i = 0; i < 8; ++i) {
        int fd[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, fd) != 0 ||
            send(mailbox, &fd[1], sizeof(fd[1]), 0) != sizeof(fd[1])) abort();
        peers[i] = fd[0];
    }
    for (int i = 0; i < 8; ++i)
        if (dispatch_semaphore_wait(accepts, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 2))) abort();
    if (workers > 0) {
        usleep(32000); // More than the histogram's 16.384 ms upper boundary.
        atomic_store(&hold_owner, false);
        for (int i = 0; i < workers; ++i) dispatch_semaphore_signal(resume_owner);
    }
}

unsigned fixture_finish(void) {
    // The normal release fence must have processed each descriptor before returning.
    for (size_t i = 0; i < 8; ++i) {
        char byte;
        if (recv(peers[i], &byte, 1, MSG_DONTWAIT) != 0) abort();
        close(peers[i]);
    }
    close(mailbox);
    dispatch_release(accepts);
    dispatch_release(resume_owner);
    return atomic_load(&clocks);
}
