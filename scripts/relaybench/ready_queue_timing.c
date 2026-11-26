// Time one real owner on established AF_UNIX flows after bulk classification.
#include <pthread.h>
#include <pthread/qos.h>
#define main filter_fixture_main
#include "filter_work.c"
#undef main

enum { FLOWS = 16, CAP = 512 * 1024, WORK_MIB = 32 };
struct flow { int client[2], guest[2]; struct pair *pair; };
static unsigned char sent[FLOWS][CAP], received[CAP];

static void increase_capacity(int fds[2]) {
    int size = 2 * CAP;
    for (int i = 0; i < 2; ++i) {
        check(setsockopt(fds[i], SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0 &&
              setsockopt(fds[i], SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) == 0, "socket capacity");
    }
}

static void verify(int fd, const unsigned char *expected, size_t length) {
    size_t done = 0;
    while (done < length) {
        ssize_t n = read(fd, received + done, length - done);
        check(n > 0, "missing forwarded data");
        done += (size_t)n;
    }
    check(memcmp(received, expected, length) == 0, "wrong flow, wave, order, or contents");
}

static uint64_t wave(mp_tcp_relay *owner, struct flow flows[FLOWS], size_t piece, unsigned tag) {
    for (unsigned i = 0; i < FLOWS; ++i) {
        memcpy(sent[i], &tag, sizeof(tag));
        check(write(flows[i].guest[0], sent[i], piece) == (ssize_t)piece, "incomplete producer write");
    }
    uint64_t start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    mp_tcp_relay_drain(owner, 2);
    uint64_t cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start;
    for (int i = 0; i < FLOWS; ++i) verify(flows[i].client[0], sent[i], piece);
    return cpu;
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    bool nested = strcmp(argv[1], "nested") == 0;
    size_t piece = strcmp(argv[2], "4") == 0 ? 4096 : CAP;
    check((nested || strcmp(argv[1], "flat") == 0) && (piece != CAP || strcmp(argv[2], "512") == 0), "arms");
    check(pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0) == 0, "background thread");
    alarm(15);
    mp_tcp_relay *owner = nested ? mp_tcp_relay_create("127.0.0.1") : mp_tcp_relay_create_data("127.0.0.1");
    check(owner && (owner->bulk.fd >= 0) == nested && mp_tcp_relay_read_bytes(owner) == CAP &&
          mp_tcp_data_callback_events(2) == EVENTS_PER_TURN, "queue policy and cap");
    mp_tcp_listener *lease = new_listener(owner, 8080, 0);
    check(lease != NULL, "create lease");
    struct flow flows[FLOWS];
    for (unsigned i = 0; i < FLOWS; ++i) {
        struct flow *f = &flows[i];
        f->pair = stage(lease, f->client, f->guest);
        increase_capacity(f->client);
        increase_capacity(f->guest);
        for (unsigned j = 0; j < CAP; ++j) sent[i][j] = (unsigned char)(i * 37 + j * 89 + j / 257);
    }
    mp_tcp_relay_drain(owner, 2);
    wave(owner, flows, LARGE_READ, 0);
    for (int i = 0; i < FLOWS; ++i) {
        check(!flows[i].pair->guest.connecting && flows[i].pair->guest.bulk_read, "unclassified stream");
    }
    wave(owner, flows, piece, 1);
    unsigned waves = WORK_MIB * 1024 * 1024 / (FLOWS * piece);
    uint64_t cpu = 0, start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    for (unsigned i = 0; i < waves; ++i) cpu += wave(owner, flows, piece, i + 2);
    uint64_t wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
    check(lease->active == FLOWS && calls > 0, "live flow and filter state");
    for (int i = 0; i < FLOWS; ++i) check(shutdown(flows[i].guest[0], SHUT_WR) == 0, "guest FIN");
    for (int turn = 0; turn < 4; ++turn) mp_tcp_relay_drain(owner, 2);
    for (int i = 0; i < FLOWS; ++i) {
        check(read(flows[i].client[0], received, 1) == 0, "guest EOF after last byte");
        check(shutdown(flows[i].client[0], SHUT_WR) == 0, "client FIN");
    }
    for (int turn = 0; turn < 4; ++turn) mp_tcp_relay_drain(owner, 2);
    for (int i = 0; i < FLOWS; ++i) {
        check(read(flows[i].guest[0], received, 1) == 0, "client EOF");
        close(flows[i].client[0]);
        close(flows[i].guest[0]);
    }
    check(lease->active == 0 && !lease->head, "all streams retired");
    mp_tcp_release(lease, NULL);
    mp_tcp_relay_destroy(owner);
    printf("{\"arm\":\"%s\",\"piece_bytes\":%zu,\"waves\":%u,\"verified_bytes\":%zu,"
           "\"owner_ns\":%llu,\"wall_ns\":%llu}\n",
           argv[1], piece, waves, waves * FLOWS * piece, (unsigned long long)cpu, (unsigned long long)wall);
    return 0;
}
