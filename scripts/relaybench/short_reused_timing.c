// Time the same two callback workloads on both arms. Only the short marker's
// completion reads a clock inside the relay path; all other payloads are untimed there.
#include <pthread.h>
#include <pthread/qos.h>
#include <time.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
static int tagged_output = -1;
static uint64_t tag_written_ns;
static ssize_t time_tag(int fd, const void *bytes, size_t size) {
    ssize_t written = write(fd, bytes, size);
    if (fd == tagged_output && written > 0) tag_written_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    return written;
}
#define write(...) time_tag(__VA_ARGS__)
#define main unused_filter_work_main
#include "filter_work.c"
#undef main
#undef write

enum { STREAMS = 18, PIECE = 64 * 1024, WAVES = 64 };
static unsigned char body[STREAMS][PIECE], received[PIECE];

static void verify(int fd, const unsigned char *wanted, size_t bytes) {
    size_t done = 0;
    while (done < bytes) {
        ssize_t n = read(fd, received + done, bytes - done);
        check(n > 0, "missing forwarded payload");
        done += (size_t)n;
    }
    check(memcmp(wanted, received, bytes) == 0, "wrong stream, wave or bytes");
}

int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "mixed") && strcmp(argv[1], "bulk"))) return 2;
    bool mixed = !strcmp(argv[1], "mixed");
    alarm(15);
    check(pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0) == 0, "background thread");
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r && mp_tcp_relay_read_bytes(r) == 256 * 1024, "stock cap");
    mp_tcp_listener *l = new_listener(r, 8080, 0);
    check(l != NULL, "new lease");
    int client[STREAMS][2], guest[STREAMS][2], flows = mixed ? STREAMS : STREAMS - 2;
    struct pair *pairs[STREAMS];
    for (int i = 0; i < flows; ++i) {
        pairs[i] = stage(l, client[i], guest[i]);
        int space = 512 * 1024;
        for (int j = 0; j < 2; ++j) {
            check(setsockopt(guest[i][j], SOL_SOCKET, SO_SNDBUF, &space, sizeof(space)) == 0 &&
                  setsockopt(guest[i][j], SOL_SOCKET, SO_RCVBUF, &space, sizeof(space)) == 0 &&
                  setsockopt(client[i][j], SOL_SOCKET, SO_SNDBUF, &space, sizeof(space)) == 0 &&
                  setsockopt(client[i][j], SOL_SOCKET, SO_RCVBUF, &space, sizeof(space)) == 0, "socket capacity");
        }
        for (int j = 0; j < PIECE; ++j) body[i][j] = (unsigned char)(i * 37 + j * 91 + j / 251);
    }
    drain(r);
    for (int i = 0; i < flows; ++i)
        if (i != 17) check(write(guest[i][0], body[i], LARGE_READ) == LARGE_READ, "prime");
    drain(r);
    for (int i = 0; i < flows; ++i) {
        if (i != 17) verify(client[i][0], body[i], LARGE_READ);
        check(pairs[i]->guest.bulk_read == (i != 17), "classification");
    }
    if (mixed) tagged_output = client[16][1];
    uint64_t marker_ns[WAVES], cpu_ns = 0, start = 0, total_bytes = 0;
    for (int wave = -2; wave < WAVES; ++wave) {
        if (wave == 0) start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        for (int i = 0; i < flows; ++i) {
            size_t bytes = i == 17 ? 1 : i == 16 ? 17 : PIECE;
            body[i][0] = (unsigned char)(wave * 37 + i);
            check(write(guest[i][0], body[i], bytes) == (ssize_t)bytes, "offer complete");
        }
        tag_written_ns = 0;
        uint64_t cpu_start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
        uint64_t mark_start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        mp_tcp_relay_drain(r, 2);
        uint64_t cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu_start;
        check(!mixed || tag_written_ns >= mark_start, "timed tag");
        if (wave >= 0) {
            cpu_ns += cpu;
            if (mixed) marker_ns[wave] = tag_written_ns - mark_start;
        }
        for (int i = 0; i < flows; ++i) {
            size_t bytes = i == 17 ? 1 : i == 16 ? 17 : PIECE;
            verify(client[i][0], body[i], bytes);
            if (wave >= 0) total_bytes += bytes;
        }
    }
    uint64_t wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
    tagged_output = -1;
    for (int i = 0; i < flows; ++i) check(shutdown(guest[i][0], SHUT_WR) == 0, "guest FIN");
    drain(r);
    for (int i = 0; i < flows; ++i) {
        check(read(client[i][0], received, 1) == 0, "ordered EOF");
        check(write(client[i][0], body[i], 1) == 1 && shutdown(client[i][0], SHUT_WR) == 0, "reverse FIN");
    }
    drain(r);
    for (int i = 0; i < flows; ++i) {
        verify(guest[i][0], body[i], 1);
        check(read(guest[i][0], received, 1) == 0, "reverse EOF");
        close(client[i][0]); close(guest[i][0]);
    }
    check(!l->active && !l->head, "retired");
    mp_tcp_release(l, NULL);
    mp_tcp_relay_destroy(r);
    printf("{\"bytes\":%llu,\"waves\":%d,\"wall_ns\":%llu,\"owner_cpu_ns\":%llu,\"tag_ns\":[",
           (unsigned long long)total_bytes, WAVES, (unsigned long long)wall, (unsigned long long)cpu_ns);
    if (mixed) for (int i = 0; i < WAVES; ++i) printf("%s%llu", i ? "," : "", (unsigned long long)marker_ns[i]);
    puts("]}");
}
