// Single-threaded Darwin fixture. The driver supplies pinned production C and local test helpers.
#include <errno.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint64_t copy_ops, copy_bytes, allocations, allocated_bytes, zero_writes, partial_writes, writes;
static bool fail_one_chunk;
static void *count_malloc(size_t bytes) {
    if (fail_one_chunk && bytes == 262144) { fail_one_chunk = false; return NULL; }
    void *result = malloc(bytes);
    if (result) { ++allocations; allocated_bytes += bytes; }
    return result;
}
static void *count_copy(void *dst, const void *src, size_t bytes) {
    ++copy_ops; copy_bytes += bytes;
    return memcpy(dst, src, bytes);
}
static ssize_t count_write(int fd, const void *data, size_t bytes) {
    ++writes;
    ssize_t n = write(fd, data, bytes);
    if ((n < 0 && errno == EAGAIN) || n == 0) ++zero_writes;
    else if (n > 0 && (size_t)n < bytes) ++partial_writes;
    return n;
}
#define malloc(...) count_malloc(__VA_ARGS__)
#pragma push_macro("memcpy")
#undef memcpy
#define memcpy(...) count_copy(__VA_ARGS__)
#define write(...) count_write(__VA_ARGS__)
#define main unused_filter_test_main
#include BENCH_HELPERS
#undef main
#undef malloc
#pragma pop_macro("memcpy")
#undef write

enum { FLOWS = 4, WAVES = 48 };
struct flow { int client[2], guest[2]; struct pair *p; };
static unsigned char content[FLOWS][2][CHUNK], received[CHUNK];
static uint64_t owner_ns;
static uint64_t now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static void owner_turn(mp_tcp_relay *r) {
    uint64_t start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    mp_tcp_relay_drain(r, 2);
    owner_ns += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start;
}
static void size_sockets(int fds[2], int size) {
    for (int i = 0; i < 2; ++i) {
        check(setsockopt(fds[i], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0 &&
              setsockopt(fds[i], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) == 0, "socket capacity");
    }
}
static void open_flow(mp_tcp_listener *l, struct flow *f, int capacity) {
    f->p = stage(l, f->client, f->guest);
    size_sockets(f->client, capacity);
    size_sockets(f->guest, 4 * CHUNK);
    owner_turn(l->relay);
    check(!f->p->guest.connecting, "established stream");
}
static void close_peers(struct flow *f) { close(f->guest[0]); close(f->client[0]); }
static void expect_fin(int fd) {
    unsigned char byte;
    check(recv(fd, &byte, 1, MSG_DONTWAIT) == 0, "expected EOF after all data");
}
static void write_all(int fd, const void *bytes, size_t length) {
    check(write(fd, bytes, length) == (ssize_t)length, "seed complete chunk");
}
static int compare_ns(const void *left, const void *right) {
    uint64_t a = *(const uint64_t *)left, b = *(const uint64_t *)right;
    return (a > b) - (a < b);
}

static uint64_t fresh(mp_tcp_listener *l, unsigned wave) {
    int client[2], guest[2];
    uint64_t start = now();
    stage(l, client, guest);
    write_all(client[0], &wave, sizeof(wave));
    owner_turn(l->relay);
    expect_bytes(guest[0], (const unsigned char *)&wave, sizeof(wave));
    unsigned response = ~wave;
    write_all(guest[0], &response, sizeof(response));
    check(shutdown(guest[0], SHUT_WR) == 0, "fresh guest FIN");
    owner_turn(l->relay);
    expect_bytes(client[0], (const unsigned char *)&response, sizeof(response));
    uint64_t elapsed = now() - start;
    expect_fin(client[0]);
    check(shutdown(client[0], SHUT_WR) == 0, "fresh client FIN");
    owner_turn(l->relay);
    expect_fin(guest[0]);
    close(client[0]); close(guest[0]);
    return elapsed;
}

static void consume_wave(struct flow flows[], mp_tcp_relay *r) {
    size_t offsets[FLOWS] = {0};
    for (int turn = 0; turn < 128; ++turn) {
        unsigned complete = 0;
        for (int i = 0; i < FLOWS; ++i) {
            while (offsets[i] < 2 * CHUNK) {
                size_t segment = offsets[i] / CHUNK, offset = offsets[i] % CHUNK;
                ssize_t n = recv(flows[i].client[0], received, CHUNK - offset, MSG_DONTWAIT);
                if (n < 0 && errno == EAGAIN) break;
                check(n > 0 && memcmp(received, content[i][segment] + offset, (size_t)n) == 0,
                      "bulk bytes, stream identity and order");
                offsets[i] += (size_t)n;
            }
            if (offsets[i] == 2 * CHUNK) ++complete;
        }
        if (complete == FLOWS) return;
        owner_turn(r);
    }
    check(false, "bounded wave progress");
}

static void measure(int capacity) {
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r != NULL, "create owner");
    mp_tcp_listener *l = new_listener(r, 8080, 0);
    check(l != NULL, "create lease");
    struct flow flows[FLOWS];
    for (int i = 0; i < FLOWS; ++i) open_flow(l, &flows[i], capacity);
    owner_ns = copy_ops = copy_bytes = allocations = allocated_bytes = zero_writes = partial_writes = writes = 0;
    uint64_t fresh_ns[WAVES];
    uint64_t start = now();
    for (unsigned wave = 0; wave < WAVES; ++wave) {
        for (unsigned s = 0; s < 2; ++s) {
            for (unsigned i = 0; i < FLOWS; ++i) {
                memcpy(content[i][s], &wave, sizeof(wave));
                write_all(flows[i].guest[0], content[i][s], CHUNK);
            }
            if (!s) owner_turn(r);
        }
        fresh_ns[wave] = fresh(l, wave);
        consume_wave(flows, r);
        check(l->active == FLOWS, "every original stream remains active");
    }
    uint64_t elapsed_ns = now() - start;
    uint64_t measured_cpu = owner_ns;
    uint64_t sorted[WAVES]; memcpy(sorted, fresh_ns, sizeof(sorted));
    qsort(sorted, WAVES, sizeof(*sorted), compare_ns);
    printf("{\"client_capacity\":%d,\"flows\":%d,\"waves\":%d,\"bulk_bytes\":%u,\"elapsed_ns\":%llu,"
           "\"owner_ns\":%llu,\"writes\":%llu,\"partial_writes\":%llu,\"zero_writes\":%llu,\"copy_ops\":%llu,"
           "\"copy_bytes\":%llu,\"malloc_calls\":%llu,\"malloc_bytes\":%llu,\"fresh_p95_ns\":%llu,\"fresh_ns\":[",
           capacity, FLOWS, WAVES, FLOWS * WAVES * 2 * CHUNK, (unsigned long long)elapsed_ns,
           (unsigned long long)measured_cpu, (unsigned long long)writes, (unsigned long long)partial_writes,
           (unsigned long long)zero_writes, (unsigned long long)copy_ops, (unsigned long long)copy_bytes,
           (unsigned long long)allocations, (unsigned long long)allocated_bytes, (unsigned long long)sorted[(95*WAVES+99)/100-1]);
    for (unsigned i = 0; i < WAVES; ++i) printf("%s%llu", i ? "," : "", (unsigned long long)fresh_ns[i]);
    puts("]}");
    // Verify tail before EOF plus a response on the still-open direction of every bulk stream.
    for (unsigned i = 0; i < FLOWS; ++i) {
        write_all(flows[i].guest[0], content[i][1], 97);
        check(shutdown(flows[i].guest[0], SHUT_WR) == 0, "bulk FIN");
    }
    owner_turn(r);
    for (unsigned i = 0; i < FLOWS; ++i) {
        expect_bytes(flows[i].client[0], content[i][1], 97);
        expect_fin(flows[i].client[0]);
        write_all(flows[i].client[0], content[i][0], 17);
        check(shutdown(flows[i].client[0], SHUT_WR) == 0, "reverse FIN");
    }
    owner_turn(r);
    for (unsigned i = 0; i < FLOWS; ++i) {
        expect_bytes(flows[i].guest[0], content[i][0], 17);
        expect_fin(flows[i].guest[0]);
        close_peers(&flows[i]);
    }
    check(l->active == 0 && !r->retired, "all streams reaped");
    mp_tcp_release(l, NULL); mp_tcp_relay_destroy(r);
}

static void qualify(void) {
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r != NULL, "test data owner");
    mp_tcp_listener *l[3]; struct flow f[3]; size_t pad[3];
    for (int i = 0; i < 2; ++i) {
        l[i] = new_listener(r, (uint16_t)(8080 + i), 0);
        check(l[i] != NULL, "test lease");
        open_flow(l[i], &f[i], 32 * 1024);
    }
    copy_bytes = 0;
    // First writes return EAGAIN, forcing two simultaneous full-size suffixes.
    for (int i = 0; i < 2; ++i) {
        pad[i] = fill(f[i].client[1]);
        write_all(f[i].guest[0], content[i][0], CHUNK);
        owner_turn(r);
        check(f[i].p->client.length == CHUNK, "both full-size suffixes retained");
    }
#if LOAN
    check(r->loaned && f[0].p->client.pending == r->loaned && f[1].p->client.pending != r->loaned &&
          copy_bytes == CHUNK, "one loan plus one copied suffix");
#else
    check(copy_bytes == 2 * CHUNK, "two stock suffix copies");
#endif
    // Revoke the outstanding loan while a different lease remains blocked; reuse this port.
    mp_tcp_release(l[0], NULL);
    consume_padding(f[0].client[0], pad[0]); expect_fin(f[0].client[0]); expect_fin(f[0].guest[0]); close_peers(&f[0]);
    l[2] = new_listener(r, 8080, 0); check(l[2] != NULL, "replacement lease");
    open_flow(l[2], &f[2], 32 * 1024);
    pad[2] = fill(f[2].client[1]);
    write_all(f[2].guest[0], content[2][0], CHUNK);
    owner_turn(r);
#if LOAN
    check(f[2].p->client.pending == r->loaned && copy_bytes == CHUNK, "revoked buffer reused safely");
#endif
    for (int i = 1; i <= 2; ++i) {
        check(shutdown(f[i].guest[0], SHUT_WR) == 0, "FIN behind pending bytes");
        consume_padding(f[i].client[0], pad[i]);
        size_t offset = 0;
        for (int turn = 0; turn < 128 && offset < CHUNK; ++turn) {
            owner_turn(r);
            ssize_t n = recv(f[i].client[0], received, CHUNK - offset, MSG_DONTWAIT);
            check(n > 0 && !memcmp(received, content[i][0] + offset, (size_t)n), "retained sibling bytes");
            offset += (size_t)n;
        }
        check(offset == CHUNK, "all bytes before FIN"); owner_turn(r); expect_fin(f[i].client[0]);
        write_all(f[i].client[0], content[i][0], 1); check(shutdown(f[i].client[0], SHUT_WR) == 0, "reply half close");
        owner_turn(r); expect_bytes(f[i].guest[0], content[i][0], 1); expect_fin(f[i].guest[0]);
        mp_tcp_release(l[i], NULL); close_peers(&f[i]);
    }
    // A small suffix still uses its actual size, including after earlier large loans.
    l[0] = new_listener(r, 8080, 0); check(l[0] != NULL, "tiny suffix lease");
    open_flow(l[0], &f[0], 32 * 1024);
    pad[0] = fill(f[0].client[1]);
    uint64_t before_copy = copy_bytes;
    write_all(f[0].guest[0], content[0][0], 97); owner_turn(r);
    check(copy_bytes - before_copy == 97 && f[0].p->client.length == 97, "exact-sized small fallback");
    consume_padding(f[0].client[0], pad[0]); owner_turn(r);
    expect_bytes(f[0].client[0], content[0][0], 97);
    mp_tcp_release(l[0], NULL); close_peers(&f[0]);
    mp_tcp_relay_destroy(r);
#if LOAN
    // The one optional buffer can fail to allocate. The ordinary suffix path must still deliver.
    r = mp_tcp_relay_create_data("127.0.0.1"); check(r != NULL, "allocation-failure owner");
    l[0] = new_listener(r, 8080, 0); check(l[0] != NULL, "allocation-failure lease");
    open_flow(l[0], &f[0], 32 * 1024);
    fail_one_chunk = true;
    write_all(f[0].guest[0], content[0][0], CHUNK); owner_turn(r);
    size_t left = f[0].p->client.length;
    check(left > CHUNK / 4 && left < CHUNK && !r->loaned && !fail_one_chunk, "short write falls back after allocation failure");
    size_t offset = 0;
    while (offset < CHUNK) {
        ssize_t n = recv(f[0].client[0], received, CHUNK - offset, MSG_DONTWAIT);
        check(n > 0 && !memcmp(received, content[0][0] + offset, (size_t)n), "uncopied prefix plus retained fallback");
        offset += (size_t)n; owner_turn(r);
    }
    mp_tcp_release(l[0], NULL); close_peers(&f[0]); mp_tcp_relay_destroy(r);
#endif
    puts("{\"qualified\":true}");
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    check(pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0) == 0, "background fixture thread");
    alarm(15);
    for (unsigned f = 0; f < FLOWS; ++f) for (unsigned s = 0; s < 2; ++s) {
        uint32_t rand = 41U * f + s + 1U;
        for (size_t i = 0; i < CHUNK; ++i) {
            rand = 1664525U * rand + 1013904223U; content[f][s][i] = (unsigned char)(rand >> 24);
        }
    }
    if (!strcmp(argv[1], "qualify")) qualify();
    else if (!strcmp(argv[1], "measure")) { measure(4 * CHUNK); measure(32 * 1024); }
    else return 2;
    return 0;
}
