// Hold out real inline stock and candidate relay binaries using fixed-work helpers.
#include <unistd.h>
#include <stdint.h>
#include <stdbool.h>
#include <time.h>
#if TRACE_MARKER
static bool trace;
static int marker_fd, marker_peer;
static uint64_t queued, latency, bytes_ahead;
static unsigned bulk_before, marker_count;
static ssize_t trace_write(int fd, const void *buffer, size_t size) {
    ssize_t sent = write(fd, buffer, size);
    if (trace && sent > 0) {
        if (fd == marker_peer) {
            if (!queued || marker_count++ || sent != 1) _exit(3);
            latency = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - queued;
        } else if (bulk_before++ == 0) {
            queued = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            if (write(marker_fd, "!", 1) != 1) _exit(3);
        } else if (!marker_count) {
            bytes_ahead += (size_t)sent;
        }
    }
    return sent;
}
#endif
#include "wave_helpers.h"

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    unsigned kib = (unsigned)atoi(argv[1]), iterations = (unsigned)atoi(argv[2]);
    check((kib == 4 || kib == 256) && iterations > 0 && iterations <= 4096, "fixed wave schedule");
    check(pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0) == 0, "background QoS");
    size_t piece = kib * 1024;
    alarm(30);
    mp_tcp_relay *owner = mp_tcp_relay_create_data("127.0.0.1");
    check(owner && owner->bulk.fd < 0 && mp_tcp_relay_read_bytes(owner) == 256 * 1024 &&
          mp_tcp_data_callback_events(2) == 128, "ordinary relay cap and fixed callback");
    mp_tcp_listener *lease = new_listener(owner, 8080, 0);
    check(lease != NULL, "lease");
    struct flow flows[FLOWS];
    for (unsigned i = 0; i < FLOWS; ++i) {
        struct flow *f = &flows[i];
        f->pair = stage(lease, f->client, f->guest);
        increase_capacity(f->client);
        increase_capacity(f->guest);
        for (unsigned j = 0; j < piece; ++j) sent[i][j] = (unsigned char)(i * 37 + j * 89 + j / 257);
    }
#if TRACE_MARKER
    struct flow fresh;
    fresh.pair = stage(lease, fresh.client, fresh.guest);
    marker_fd = fresh.guest[0];
    marker_peer = fresh.client[1];
    uint64_t latencies[4096];
#endif
    mp_tcp_relay_drain(owner, 2);
    wave(owner, flows, LARGE_READ, 0);
    for (unsigned i = 0; i < FLOWS; ++i)
        check(flows[i].pair->guest.bulk_read && !flows[i].pair->guest.connecting, "established bulk");
    for (unsigned i = 0; i < 3; ++i) wave(owner, flows, piece, i + 1);
    uint64_t cpu = 0, start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (unsigned i = 0; i < iterations; ++i) {
#if TRACE_MARKER
        trace = true;
        queued = latency = bytes_ahead = 0;
        bulk_before = marker_count = 0;
#endif
        cpu += wave(owner, flows, piece, i + 4);
#if TRACE_MARKER
        trace = false;
        check(marker_count == 1 && bulk_before == FLOWS && bytes_ahead == (FLOWS - 1) * piece &&
              latency > 0, "fresh reply order or lost marker");
        verify(fresh.client[0], (const unsigned char *)"!", 1);
        latencies[i] = latency;
#endif
    }
    uint64_t wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
    printf("{\"verified_bytes\":%zu,\"wall_ns\":%llu,\"owner_ns\":%llu,\"piece\":%zu,"
           "\"offset\":%zu,\"allocation_bytes\":%zu,\"page_bytes\":%ld",
           iterations * FLOWS * piece, (unsigned long long)wall, (unsigned long long)cpu, piece,
           (size_t)((uintptr_t)owner->scratch % (size_t)sysconf(_SC_PAGESIZE)), sizeof(*owner), sysconf(_SC_PAGESIZE));
#if TRACE_MARKER
    printf(",\"bytes_ahead_per_reply\":%zu,\"fresh_ns\":[", piece * (FLOWS - 1));
    for (unsigned i = 0; i < iterations; ++i) printf("%s%llu", i ? "," : "", (unsigned long long)latencies[i]);
    printf("]");
    check(shutdown(fresh.guest[0], SHUT_WR) == 0 && shutdown(fresh.client[0], SHUT_WR) == 0, "fresh FINs");
#endif
    for (unsigned i = 0; i < FLOWS; ++i) check(shutdown(flows[i].guest[0], SHUT_WR) == 0, "guest FIN");
    mp_tcp_relay_drain(owner, 2);
    for (unsigned i = 0; i < FLOWS; ++i) {
        check(read(flows[i].client[0], received, 1) == 0, "download EOF");
        check(write(flows[i].client[0], "r", 1) == 1 && shutdown(flows[i].client[0], SHUT_WR) == 0, "reverse FIN");
    }
    mp_tcp_relay_drain(owner, 2);
    for (unsigned i = 0; i < FLOWS; ++i) {
        verify(flows[i].guest[0], (const unsigned char *)"r", 1);
        check(read(flows[i].guest[0], received, 1) == 0, "reverse EOF");
        close(flows[i].client[0]); close(flows[i].guest[0]);
    }
#if TRACE_MARKER
    check(read(fresh.client[0], received, 1) == 0 && read(fresh.guest[0], received, 1) == 0, "fresh EOF");
    close(fresh.client[0]); close(fresh.guest[0]);
#endif
    check(lease->active == 0 && !lease->head, "retired");
    mp_tcp_release(lease, NULL);
    mp_tcp_relay_destroy(owner);
    puts("}");
    return 0;
}
