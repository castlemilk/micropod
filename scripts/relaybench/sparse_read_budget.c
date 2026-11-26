// Exercise alternating ready sets on one native relay owner with 16 connected streams.
#include <stdint.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <unistd.h>

static int marker_src, marker_dst, marker_read_fd;
static int tracking, insert_after, marker_sent, marker_seen;
static unsigned bulk_reads, above_256k, bulk_writes, partial_writes;
static uint64_t ahead;

#if COUNT_IO
static ssize_t trace_read(int fd, void *buf, size_t size) {
    ssize_t n = read(fd, buf, size);
    if (tracking && fd != marker_read_fd && n > 0) {
        ++bulk_reads;
        if (n > 256 * 1024) ++above_256k;
    }
    return n;
}

static ssize_t trace_write(int fd, const void *buf, size_t size) {
    ssize_t n = write(fd, buf, size);
    if (tracking && n > 0) {
        if (fd == marker_dst) {
            if (n != 1 || !marker_sent || marker_seen) _exit(3);
            marker_seen = 1;
        } else {
            if (marker_sent && !marker_seen) ahead += (size_t)n;
            if ((size_t)n < size) ++partial_writes;
            ++bulk_writes;
            if (insert_after > 0 && bulk_writes == (unsigned)insert_after) {
                if (write(marker_src, "!", 1) != 1) _exit(3);
                marker_sent = 1;
            }
        }
    }
    return n;
}
#define read(...) trace_read(__VA_ARGS__)
#define write(...) trace_write(__VA_ARGS__)
#endif
#define main original_filter_fixture_main
#include "filter_work.c"
#undef main
#undef read
#undef write

enum { FLOWS = 16, KIB = 1024, OFFER = 512 * KIB };
struct stream { int client[2], guest[2]; };
static struct stream flows[FLOWS + 1];
static unsigned char bytes[FLOWS][OFFER], out[OFFER];

static void capacity(int pair[2], int size) {
    for (int i = 0; i < 2; ++i)
        check(setsockopt(pair[i], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0 &&
              setsockopt(pair[i], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) == 0, "socket capacity");
}

static void verify(int fd, const unsigned char *expected, size_t size) {
    size_t done = 0;
    while (done < size) {
        ssize_t n = read(fd, out + done, size - done);
        check(n > 0, "missing bytes");
        done += (size_t)n;
    }
    check(memcmp(out, expected, size) == 0, "wrong stream, wave or contents");
}

static uint64_t wave(mp_tcp_relay *owner, int ready, int offer, int offset, unsigned tag,
                     int marker_position, int first_budget, bool pressured) {
    marker_sent = marker_seen = 0;
    insert_after = marker_position;
    for (int j = 0; j < ready; ++j) {
        int i = (offset + j) % FLOWS;
        memcpy(bytes[i], &tag, sizeof(tag));
        check(write(flows[i].guest[0], bytes[i], offer) == offer, "producer write");
    }
    if (marker_position == 0) {
        check(write(marker_src, "!", 1) == 1, "co-ready marker");
        marker_sent = 1;
    }
    uint64_t start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    if (first_budget) {
        drain_data(owner, first_budget);
        check(above_256k == 0 || !owner->sparse_reads, "truncated poll selected larger reads");
    }
    mp_tcp_relay_drain(owner, 2);
    uint64_t cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start;
    if (pressured) {
        check(ready == 1, "one slow consumer");
        struct stream *f = &flows[offset];
        for (int done = 0; done < offer;) {
            ssize_t n = read(f->client[0], out, offer - done);
            check(n > 0 && !memcmp(out, bytes[offset] + done, (size_t)n), "pressured data or ordering");
            done += (int)n;
            mp_tcp_relay_drain(owner, 2);
        }
    } else {
        for (int j = 0; j < ready; ++j) {
            int i = (offset + j) % FLOWS;
            verify(flows[i].client[0], bytes[i], offer);
        }
    }
    if (marker_position >= 0) {
        check(marker_sent && marker_seen, "marker delivery");
        verify(flows[FLOWS].client[0], (const unsigned char *)"!", 1);
    }
    return cpu;
}

int main(int argc, char **argv) {
    if (argc != 3 && argc != 7) return 2;
    bool timed = !strcmp(argv[1], "timed");
    check((timed && argc == 3 && !COUNT_IO) || (!strcmp(argv[1], "check") && argc == 7 && COUNT_IO),
          "timed/check build mismatch");
    bool sparse_only = timed && !strcmp(argv[2], "two-ready");
    bool dense_only = timed && !strcmp(argv[2], "sixteen-ready");
    check(!timed || sparse_only || dense_only || !strcmp(argv[2], "alternating"), "timing schedule");
    int ready = timed ? 0 : atoi(argv[2]), offer = timed ? 0 : atoi(argv[3]) * KIB;
    int marker = timed ? -1 : atoi(argv[4]), budget = timed ? 0 : atoi(argv[5]);
    bool pressure = !timed && atoi(argv[6]);
    check(timed || (ready >= 1 && ready <= FLOWS && offer >= 4 && offer <= OFFER &&
          marker >= -1 && marker <= ready && budget >= 0 && budget <= 2), "unsupported cell");
    check(pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0) == 0, "background thread");
    alarm(15);
    mp_tcp_relay *owner = mp_tcp_relay_create_data("127.0.0.1");
    check(owner && owner->bulk.fd < 0 && mp_tcp_data_callback_events(2) == 128, "flat two-worker owner");
    mp_tcp_listener *lease = new_listener(owner, 8080, 0);
    check(lease != NULL, "lease");
    for (int i = 0; i <= FLOWS; ++i) {
        stage(lease, flows[i].client, flows[i].guest);
        capacity(flows[i].client, pressure && i == 0 ? 128 * KIB : 2 * OFFER);
        capacity(flows[i].guest, 2 * OFFER);
        if (i < FLOWS)
            for (size_t k = 0; k < OFFER; ++k) bytes[i][k] = (unsigned char)(i * 37 + k * 89 + k / 257);
    }
    mp_tcp_relay_drain(owner, 2);
    for (int i = 0; i < FLOWS; ++i)
        check(write(flows[i].guest[0], bytes[i], LARGE_READ) == LARGE_READ, "bulk classification");
    mp_tcp_relay_drain(owner, 2);
    for (int i = 0; i < FLOWS; ++i) verify(flows[i].client[0], bytes[i], LARGE_READ);
    marker_src = flows[FLOWS].guest[0];
    marker_read_fd = flows[FLOWS].guest[1];
    marker_dst = flows[FLOWS].client[1];
    uint64_t cpu = 0, total = 0;
    if (timed) wave(owner, FLOWS, OFFER, 0, 0, -1, 0, false);
    tracking = !timed;
    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (timed) {
        const int widths[] = {1, 2, 3, 16, 2, 1, 16, 3};
        // Give all three schedules the same verified payload (88 MiB).
        unsigned waves = sparse_only ? 88 : dense_only ? 11 : 32;
        for (unsigned wave_id = 0; wave_id < waves; ++wave_id) {
            int width = widths[wave_id % 8];
            if (sparse_only) width = 2;
            if (dense_only) width = FLOWS;
            cpu += wave(owner, width, OFFER, (wave_id * 5) % FLOWS, wave_id + 1, -1, 0, false);
            total += width * OFFER;
        }
    } else {
        cpu = wave(owner, ready, offer, 0, 1, marker, budget, pressure);
        total = ready * offer;
    }
    uint64_t wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
    tracking = 0;
    for (int i = 0; i <= FLOWS; ++i) check(shutdown(flows[i].guest[0], SHUT_WR) == 0, "guest FIN");
    mp_tcp_relay_drain(owner, 2);
    for (int i = 0; i <= FLOWS; ++i) {
        check(read(flows[i].client[0], out, 1) == 0, "forward EOF");
        check(write(flows[i].client[0], "r", 1) == 1 && shutdown(flows[i].client[0], SHUT_WR) == 0, "reverse FIN");
    }
    mp_tcp_relay_drain(owner, 2);
    for (int i = 0; i <= FLOWS; ++i) {
        verify(flows[i].guest[0], (const unsigned char *)"r", 1);
        check(read(flows[i].guest[0], out, 1) == 0, "reverse EOF");
        close(flows[i].client[0]);
        close(flows[i].guest[0]);
    }
    check(lease->active == 0, "streams retired");
    mp_tcp_release(lease, NULL);
    mp_tcp_relay_destroy(owner);
    printf("{\"bytes\":%llu,\"reads\":%u,\"large_reads\":%u,\"writes\":%u,\"partial_writes\":%u,"
           "\"bulk_bytes_ahead_of_marker\":%llu,\"owner_ns\":%llu,\"wall_ns\":%llu}\n",
           (unsigned long long)total, bulk_reads, above_256k, bulk_writes, partial_writes,
           (unsigned long long)ahead, (unsigned long long)cpu, (unsigned long long)wall);
    return 0;
}
