// Record real relay malloc/free calls independently of the relay's profiling counters.
#include <stdlib.h>
#include <stdio.h>
#include <stdbool.h>
#include <errno.h>
#include <unistd.h>

struct allocation { void *ptr; size_t bytes; };
static struct allocation held[16];
static unsigned allocations, injected;
static size_t live_bytes, peak_bytes;
static bool fail_once;

static void *track_malloc(size_t bytes) {
    if (fail_once) {
        fail_once = false;
        ++injected;
        errno = ENOMEM;
        return NULL;
    }
    void *ptr = malloc(bytes);
    if (!ptr) return NULL;
    for (size_t i = 0; i < sizeof(held)/sizeof(held[0]); ++i) {
        if (!held[i].ptr) {
            held[i] = (struct allocation){ptr, bytes};
            ++allocations;
            live_bytes += bytes;
            if (peak_bytes < live_bytes) peak_bytes = live_bytes;
            return ptr;
        }
    }
    abort();
}

static void track_free(void *ptr) {
    if (ptr) {
        for (size_t i = 0; i < sizeof(held)/sizeof(held[0]); ++i) {
            if (held[i].ptr == ptr) {
                live_bytes -= held[i].bytes;
                held[i] = (struct allocation){0};
                break;
            }
        }
    }
    free(ptr);
}

#define malloc(bytes) track_malloc(bytes)
#define free(ptr) track_free(ptr)
#define main filter_work_main
#include "filter_work.c"
#undef main
#undef malloc
#undef free

enum { MAX_OFFER = 96 * 1024 };
struct flow {
    int client[2], guest[2];
    struct pair *p;
    unsigned char offer[MAX_OFFER];
    size_t count, padding_bytes, prefix;
    int *from, *to;
    struct endpoint *src, *dst;
};

static void new_flow(mp_tcp_listener *l, struct flow *f) {
    f->p = stage(l, f->client, f->guest);
    int size = MAX_OFFER * 2;
    for (unsigned i = 0; i < 2; ++i) {
        check(setsockopt(f->guest[i], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0 &&
              setsockopt(f->guest[i], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) == 0, "room for large offer");
    }
    drain(l->relay);
    f->p->connected_at = 0;
}

static void send_offer(struct flow *f, size_t bytes, unsigned token, bool reverse, bool pressure, size_t room) {
    f->count = bytes;
    f->from = reverse ? f->client : f->guest;
    f->to = reverse ? f->guest : f->client;
    f->src = reverse ? &f->p->client : &f->p->guest;
    f->dst = opposite(f->src);
    for (size_t i = 0; i < bytes; ++i) f->offer[i] = (unsigned char)(token + i * 37 + i / 257);
    size_t filled = pressure ? fill(f->to[1]) : 0;
    consume_padding(f->to[0], room);
    f->padding_bytes = filled - room;
    check(write(f->from[0], f->offer, bytes) == (ssize_t)bytes, "one complete input");
    pump(f->src, f->dst);
    f->prefix = bytes - f->dst->length;
    check((f->dst->pending != NULL) == pressure, "expected suffix state");
    if (room) check(f->prefix > 0 && f->prefix < bytes, "short first write");
}

static void deliver(struct flow *f) {
    consume_padding(f->to[0], f->padding_bytes);
    expect_bytes(f->to[0], f->offer, f->prefix);
    size_t offset = f->prefix;
    while (f->dst->pending) {
        size_t remaining = f->dst->length;
        pump(f->src, f->dst);
        size_t sent = remaining - f->dst->length;
        check(sent > 0, "bounded pending flush must progress");
        expect_bytes(f->to[0], f->offer + offset, sent);
        offset += sent;
    }
    check(offset == f->count, "exact delivery");
}

static void close_flow(mp_tcp_relay *r, struct flow *f) {
    unsigned char byte = 0, marker = 199;
    check(shutdown(f->guest[0], SHUT_WR) == 0, "guest FIN");
    drain(r);
    check(read(f->client[0], &byte, 1) == 0 && write(f->client[0], &marker, 1) == 1 &&
          shutdown(f->client[0], SHUT_WR) == 0, "reply after FIN");
    drain(r);
    expect_bytes(f->guest[0], &marker, 1);
    check(read(f->guest[0], &byte, 1) == 0, "client FIN");
    close(f->client[0]); close(f->guest[0]);
}

enum workload { UNPRESSURED, UNIFORM, VARYING, SIMULTANEOUS, PARTIAL, CEILING, OVERSIZE };

static void scenario(enum workload kind, const char *name) {
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r != NULL, "data owner");
    mp_tcp_listener *l = new_listener(r, 8080, 1);
    check(l != NULL, "lease");
    allocations = injected = 0;
    live_bytes = peak_bytes = 0;
    unsigned concurrency = kind == SIMULTANEOUS ? 2 : 1;
    struct flow f[2];
    for (unsigned n = 0; n < concurrency; ++n) new_flow(l, f+n);
    size_t delivered = 0, copied = 0;
    for (unsigned i = 0; i < 8; i += concurrency) {
        for (unsigned n = 0; n < concurrency; ++n) {
            size_t bytes = PAYLOAD;
            if (kind == VARYING && i % 2 == 0) bytes = 4096;
            if (kind == CEILING) bytes = 64 * 1024;
            if (kind == OVERSIZE) bytes = MAX_OFFER;
            bool reverse = bytes <= PAYLOAD && (i+n)%2;
            send_offer(f+n, bytes, 1+i+n, reverse, kind != UNPRESSURED, kind == PARTIAL ? PAYLOAD/2 : 0);
            delivered += bytes;
            copied += f[n].dst->length;
        }
        for (unsigned n = 0; n < concurrency; ++n) deliver(f+n);
    }
    for (unsigned n = 0; n < concurrency; ++n) close_flow(r, f+n);
    check(!l->active && !l->head, "flow retirement");
    mp_tcp_stats stats;
    mp_tcp_release(l, &stats);
    check(stats.pending_allocations == allocations && stats.pending_copy_bytes == copied, "counters match observed calls");
    size_t idle = live_bytes;
    mp_tcp_relay_destroy(r);
    check(!live_bytes, "owner freed all tracked allocations");
    printf("{\"case\":\"%s\",\"offers\":8,\"concurrency\":%u,\"delivered_bytes\":%zu,"
           "\"copied_bytes\":%zu,\"allocations\":%u,\"peak_allocated_bytes\":%zu,"
           "\"retained_idle_bytes\":%zu,\"retained_after_destroy\":%zu}\n",
           name, concurrency, delivered, copied, allocations, peak_bytes, idle, live_bytes);
}

static void failed_allocation_and_revocation(void) {
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r != NULL, "failure owner");
    struct flow f;
    mp_tcp_listener *l = new_listener(r, 8080, 0);
    check(l != NULL, "failure lease");
    new_flow(l, &f);
    // Prime the spare for the candidate. Force failure on a different size.
    send_offer(&f, 4096, 17, false, true, 0);
    deliver(&f);
    size_t filled = fill(f.client[1]);
    check(write(f.guest[0], payload, PAYLOAD) == PAYLOAD, "offer before injected failure");
    fail_once = true;
    pump(&f.p->guest, &f.p->client);
    check(!fail_once && !l->active && !l->head, "missing allocation closes pair");
    reap(r);
    consume_padding(f.client[0], filled);
    unsigned char byte;
    check(read(f.client[0], &byte, 1) == 0 && read(f.guest[0], &byte, 1) == 0, "no partial or stale delivery");
    close(f.client[0]); close(f.guest[0]);
    new_flow(l, &f);
    send_offer(&f, 4096, 22, false, true, 0);
    mp_tcp_release(l, NULL);
    consume_padding(f.client[0], f.padding_bytes);
    check(read(f.client[0], &byte, 1) == 0 && read(f.guest[0], &byte, 1) == 0, "revoked pending data discarded");
    close(f.client[0]); close(f.guest[0]);
    mp_tcp_relay_destroy(r);
    check(injected == 1 && !live_bytes, "recoverable allocation failure and full release");
}

int main(void) {
    alarm(5);
    signal(SIGPIPE, SIG_IGN);
    scenario(UNPRESSURED, "freely_draining");
    scenario(UNIFORM, "serial_32k");
    scenario(VARYING, "alternating_4k_32k");
    scenario(SIMULTANEOUS, "two_simultaneously_pending");
    scenario(PARTIAL, "partial_writes");
    scenario(CEILING, "serial_64k");
    scenario(OVERSIZE, "serial_96k");
    failed_allocation_and_revocation();
    return 0;
}
