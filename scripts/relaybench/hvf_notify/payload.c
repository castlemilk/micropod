// Pass buffers produced in mapped guest RAM to a real Mac TCP loopback receiver.
#include "vm.h"
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

enum { FRAME = 65536, SLOTS = 64, FRAMES = 4097, BATCH = 8, RING = SLOTS * FRAME };
static unsigned char *patterns, *staging;
struct receiver {
    int fd;
    uint64_t bytes, cpu_ns;
    bool verified;
};

static void *receive_frames(void *arg) {
    struct receiver *r = arg;
    unsigned char frame[FRAME];
    uint64_t start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    for (uint64_t seq = 1; seq <= FRAMES; ++seq) {
        size_t filled = 0;
        while (filled < FRAME) {
            ssize_t n = recv(r->fd, frame + filled, FRAME - filled, 0);
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                goto finish;
            filled += (size_t)n;
            r->bytes += (size_t)n;
        }
        uint64_t header;
        memcpy(&header, frame, sizeof(header));
        if (header != seq || memcmp(frame + 8, patterns + (seq & 255) * FRAME + 8, FRAME - 8))
            goto finish;
    }
    ssize_t n;
    do {
        n = recv(r->fd, frame, 1, 0);
    } while (n < 0 && errno == EINTR);
    r->verified = n == 0;
finish:
    r->cpu_ns = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start;
    if (!r->verified)
        shutdown(r->fd, SHUT_RDWR);
    return NULL;
}

static bool tcp_pair(int *writer, int *reader) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0)
        return false;
    struct sockaddr_in address = {
        .sin_len = sizeof(address), .sin_family = AF_INET, .sin_addr = {.s_addr = htonl(INADDR_LOOPBACK)}};
    socklen_t size = sizeof(address);
    int one = 1, buffer = 1 << 20;
    struct timeval timeout = {.tv_sec = 5};
    bool ok = bind(listener, (struct sockaddr *)&address, size) == 0 && listen(listener, 1) == 0 &&
              getsockname(listener, (struct sockaddr *)&address, &size) == 0 &&
              (*writer = socket(AF_INET, SOCK_STREAM, 0)) >= 0 &&
              connect(*writer, (struct sockaddr *)&address, size) == 0 &&
              (*reader = accept(listener, NULL, NULL)) >= 0 &&
              setsockopt(*writer, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) == 0 &&
              setsockopt(*writer, SOL_SOCKET, SO_SNDBUF, &buffer, sizeof(buffer)) == 0 &&
              setsockopt(*reader, SOL_SOCKET, SO_RCVBUF, &buffer, sizeof(buffer)) == 0 &&
              setsockopt(*writer, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) == 0 &&
              setsockopt(*reader, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0;
    close(listener);
    return ok;
}

// Keep this copy in the measured control even under whole-function optimization.
__attribute__((noinline)) static const unsigned char *stage(unsigned char *dst, const unsigned char *src) {
    memcpy(dst, src, FRAME);
    return dst;
}

static bool window(struct probe_vm *vm, unsigned block, unsigned direct, unsigned batch) {
    if (batch != BATCH)
        return false;
    memset(vm->data, 0, MP_PAGE + RING);
    memset(staging, 0, RING);
    _Atomic uint64_t *header = vm->data;
    unsigned char *payload = (unsigned char *)vm->data + MP_PAGE;
    if (!hv_checked(mp_tx_boot(vm->cpu, vm->code_ipa, vm->data_ipa, vm->bell_ipa, FRAMES, batch),
                    "EL1 setup"))
        return false;
    int writer = -1, reader = -1;
    bool result = false;
    if (!tcp_pair(&writer, &reader)) {
        perror("TCP setup");
        goto close_sockets;
    }
    struct receiver delivery = {.fd = reader};
    pthread_t thread;
    if (pthread_create(&thread, NULL, receive_frames, &delivery) != 0)
        goto close_sockets;
    uint64_t consumed = 0, guest0 = 0, guest1 = 0;
    unsigned notifications = 0, sends = 0;
    bool ok = hv_checked(hv_vcpu_get_exec_time(vm->cpu, &guest0), "guest start time");
    uint64_t cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    uint64_t start = mach_absolute_time();
    while (ok) {
        if (!hv_checked(hv_vcpu_run(vm->cpu), "guest entry")) {
            ok = false;
            break;
        }
        int event = probe_notification(vm, false);
        if (event == 1)
            break;
        if (event != 0 || consumed >= FRAMES) {
            ok = false;
            break;
        }
        ++notifications;
        uint64_t limit = atomic_load_explicit(&header[0], memory_order_acquire);
        uint64_t expected = FRAMES - consumed < batch ? FRAMES : consumed + batch;
        if (limit != expected) {
            ok = false;
            break;
        }
        while (consumed < limit && ok) {
            size_t off = (consumed % SLOTS) * FRAME;
            const unsigned char *src = payload + off;
            if (!direct)
                src = stage(staging + off, src);
            size_t accepted = 0;
            while (accepted < FRAME) {
                ++sends;
                ssize_t n = send(writer, src + accepted, FRAME - accepted, 0);
                if (n < 0 && errno == EINTR)
                    continue;
                if (n <= 0) {
                    ok = false;
                    break;
                }
                accepted += (size_t)n;
            }
            if (ok)
                ++consumed;
        }
        if (ok)
            atomic_store_explicit(&header[1], consumed, memory_order_release);
    }
    shutdown(writer, ok ? SHUT_WR : SHUT_RDWR);
    if (!ok)
        shutdown(reader, SHUT_RDWR);
    if (pthread_join(thread, NULL) != 0)
        abort();
    uint64_t wall = probe_ns(mach_absolute_time() - start);
    uint64_t cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0;
    if (ok && hv_checked(hv_vcpu_get_exec_time(vm->cpu, &guest1), "guest end time") && guest1 >= guest0 &&
        consumed == FRAMES && notifications == (FRAMES + BATCH - 1) / BATCH && delivery.verified &&
        delivery.bytes == (uint64_t)FRAME * FRAMES) {
        printf("{\"block\":%u,\"path\":\"%s\",\"frames\":%u,\"bytes\":%llu,\"data_exits\":%u,"
               "\"completion_exits\":1,\"sends\":%u,\"wall_ns\":%llu,\"vcpu_ns\":%llu,"
               "\"sender_cpu_ns\":%llu,\"receiver_cpu_ns\":%llu,\"verified\":true}\n",
               block, direct ? "mapped" : "staged", FRAMES, (unsigned long long)delivery.bytes, notifications,
               sends, (unsigned long long)wall, (unsigned long long)probe_ns(guest1 - guest0),
               (unsigned long long)cpu, (unsigned long long)delivery.cpu_ns);
        fflush(stdout);
        result = true;
    } else {
        fprintf(stderr, "payload window failed, frames=%llu verified=%u\n", (unsigned long long)consumed,
                (unsigned)delivery.verified);
    }
close_sockets:
    if (reader >= 0)
        close(reader);
    if (writer >= 0)
        close(writer);
    return result;
}

int main(void) {
    if (posix_memalign((void **)&staging, MP_PAGE, RING) != 0)
        return 2;
    patterns = malloc(256 * FRAME);
    if (!patterns) {
        free(staging);
        return 2;
    }
    for (size_t value = 0; value < 256; ++value)
        memset(patterns + value * FRAME, (int)value, FRAME);
    int rc = probe_run(MP_PAGE + RING, window);
    free(patterns);
    free(staging);
    return rc;
}
