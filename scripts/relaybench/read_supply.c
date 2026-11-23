// Pinned production pump, one dedicated owner, 16 anonymous stream pairs.
#include <errno.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

static uint64_t reads, writes, partial, blocked;
static int marker_destination, first_write_expected;
#if COUNT_IO
static ssize_t traced_read(int fd, void *buf, size_t n) {
    ++reads;
    return read(fd, buf, n);
}
static ssize_t traced_write(int fd, const void *buf, size_t n) {
    ++writes;
    ssize_t rc = write(fd, buf, n);
    if (rc > 0 && (size_t)rc < n) ++partial;
    if (rc == 0 || (rc < 0 && errno == EAGAIN)) ++blocked;
    if (first_write_expected && (rc != 1 || fd != marker_destination)) _exit(2);
    first_write_expected = 0;
    return rc;
}
#define read(...) traced_read(__VA_ARGS__)
#define write(...) traced_write(__VA_ARGS__)
#endif
#define main unused_filter_fixture_main
#include "filter_work.c"
#undef main
#undef read
#undef write

enum { FLOW_COUNT = 16, PIECE = 128 * 1024, PIECES = 4, WAVES = 8, ROOMY = 1024 * 1024 };
struct stream { int client[2], guest[2]; };
static unsigned char content[FLOW_COUNT][PIECES][PIECE], result_buffer[PIECE];

static void resize(int fds[2], int size) {
    for (int i = 0; i < 2; ++i) {
        check(setsockopt(fds[i], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) == 0 &&
              setsockopt(fds[i], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0, "socket capacity");
    }
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    bool fragmented = strcmp(argv[1], "fragmented") == 0;
    bool pressured = strcmp(argv[1], "pressured") == 0;
    check(fragmented || pressured || strcmp(argv[1], "queued") == 0, "unknown supply profile");
    bool marker = strcmp(argv[2], "marker") == 0;
    check(marker || strcmp(argv[2], "alone") == 0, "unknown small-flow policy");
    check(pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0) == 0, "background thread");
    alarm(15);
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r != NULL, "create owner");
    mp_tcp_listener *lease = new_listener(r, 8080, 0);
    check(lease != NULL, "create lease");
    struct stream streams[FLOW_COUNT + 1];
    for (int i = 0; i <= FLOW_COUNT; ++i) {
        stage(lease, streams[i].client, streams[i].guest);
        resize(streams[i].client, pressured ? PIECE : ROOMY);
        resize(streams[i].guest, ROOMY);
    }
    mp_tcp_relay_drain(r, 2);
    for (int i = 0; i < FLOW_COUNT; ++i) {
        for (int j = 0; j < PIECES; ++j) {
            for (size_t k = 0; k < PIECE; ++k)
                content[i][j][k] = (unsigned char)(i * 91 + j * 47 + k * 13 + k / 257);
        }
        check(write(streams[i].guest[0], content[i][0], LARGE_READ) == LARGE_READ, "prime bulk classification");
    }
    mp_tcp_relay_drain(r, 2);
    for (int i = 0; i < FLOW_COUNT; ++i) expect_bytes(streams[i].client[0], content[i][0], LARGE_READ);

    int turns = fragmented || pressured ? PIECES : 1;
    marker_destination = streams[FLOW_COUNT].client[1];
    reads = writes = partial = blocked = 0;
    uint64_t owner_ns = 0, start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (unsigned char wave = 0; wave < WAVES; ++wave) {
        for (int turn = 0; turn < turns; ++turn) {
            int write_begin = fragmented ? turn : 0;
            int write_end = fragmented ? turn + 1 : (turn == 0 ? PIECES : 0);
            for (int part = write_begin; part < write_end; ++part) {
                for (int i = 0; i < FLOW_COUNT; ++i) {
                    content[i][part][0] = wave;
                    check(write(streams[i].guest[0], content[i][part], PIECE) == PIECE, "fixed producer write");
                }
            }
            if (marker && turn == 0) {
                check(write(streams[FLOW_COUNT].guest[0], &wave, 1) == 1, "co-ready marker");
                first_write_expected = 1;
            }
            uint64_t cpu_start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
            mp_tcp_relay_drain(r, 2);
            owner_ns += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu_start;
            if (marker && turn == 0) {
                unsigned char received;
                check(recv(streams[FLOW_COUNT].client[0], &received, 1, MSG_DONTWAIT) == 1 &&
                      received == wave, "co-ready marker identity");
            }
            int read_begin = turns == 1 ? 0 : turn;
            int read_end = turns == 1 ? PIECES : turn + 1;
            for (int part = read_begin; part < read_end; ++part) {
                for (int i = 0; i < FLOW_COUNT; ++i) {
                    check(recv(streams[i].client[0], result_buffer, PIECE, MSG_DONTWAIT) == PIECE &&
                          memcmp(result_buffer, content[i][part], PIECE) == 0, "fixed consumer read and byte identity");
                }
            }
        }
    }
    uint64_t wall_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
    printf("{\"cap\":%u,\"bytes\":%u,\"owner_ns\":%llu,\"wall_ns\":%llu,\"owner_turns\":%d,"
           "\"marker_count\":%d,\"reads\":%llu,\"writes\":%llu,\"partial\":%llu,\"blocked\":%llu}\n",
           mp_tcp_relay_read_bytes(r), FLOW_COUNT * PIECE * PIECES * WAVES,
           (unsigned long long)owner_ns, (unsigned long long)wall_ns, turns * WAVES, marker ? WAVES : 0,
           (unsigned long long)reads, (unsigned long long)writes, (unsigned long long)partial, (unsigned long long)blocked);
    for (int i = 0; i <= FLOW_COUNT; ++i) check(shutdown(streams[i].guest[0], SHUT_WR) == 0, "guest half-close");
    mp_tcp_relay_drain(r, 2);
    for (int i = 0; i <= FLOW_COUNT; ++i) {
        check(recv(streams[i].client[0], result_buffer, 1, MSG_DONTWAIT) == 0, "EOF after all bytes");
        check(write(streams[i].client[0], "!", 1) == 1 && shutdown(streams[i].client[0], SHUT_WR) == 0, "reverse data/FIN");
    }
    mp_tcp_relay_drain(r, 2);
    for (int i = 0; i <= FLOW_COUNT; ++i) {
        expect_bytes(streams[i].guest[0], (const unsigned char *)"!", 1);
        check(recv(streams[i].guest[0], result_buffer, 1, MSG_DONTWAIT) == 0, "reverse FIN");
        close(streams[i].client[0]); close(streams[i].guest[0]);
    }
    mp_tcp_release(lease, NULL); mp_tcp_relay_destroy(r);
    return 0;
}
