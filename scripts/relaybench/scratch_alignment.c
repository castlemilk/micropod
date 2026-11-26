// Compare scratch addresses on one unchanged set of relay descriptors.
#include <pthread.h>
#include <pthread/qos.h>
#include <stdint.h>
static char *trial_scratch;
#define main filter_fixture_main
#include "filter_work.c"
#undef main

enum { FLOWS = 8, MAX_CHUNK = 512 * 1024, WORK_MIB = 64 };
struct flow { int client[2], guest[2]; };
static unsigned char input[FLOWS][MAX_CHUNK], output[MAX_CHUNK];

static void socket_capacity(int fds[2], int capacity) {
    for (int i = 0; i < 2; ++i) {
        check(setsockopt(fds[i], SOL_SOCKET, SO_SNDBUF, &capacity, sizeof(capacity)) == 0 &&
              setsockopt(fds[i], SOL_SOCKET, SO_RCVBUF, &capacity, sizeof(capacity)) == 0, "socket capacity");
    }
}

static uint64_t wave(mp_tcp_relay *owner, struct flow flows[FLOWS], size_t length, uint64_t tag) {
    for (unsigned i = 0; i < FLOWS; ++i) {
        memcpy(input[i], &tag, sizeof(tag));
        check(write(flows[i].guest[0], input[i], length) == (ssize_t)length, "queue exact wave");
    }
    uint64_t start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    mp_tcp_relay_drain(owner, 2);
    uint64_t cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start;
    for (unsigned i = 0; i < FLOWS; ++i) {
        size_t pos = 0;
        while (pos < length) {
            ssize_t got = read(flows[i].client[0], output + pos, length - pos);
            check(got > 0, "complete wave");
            pos += (size_t)got;
        }
        check(memcmp(output, input[i], length) == 0, "stream and wave identity");
    }
    return cpu;
}

static void pressure(mp_tcp_relay *r, struct flow *f, size_t cap) {
    socket_capacity(f->client, 32 * 1024);
    check(write(f->guest[0], input[0], cap) == (ssize_t)cap, "stage pressure");
    mp_tcp_relay_drain(r, 2);
    size_t pos = 0;
    while (pos < cap) {
        ssize_t got = read(f->client[0], output + pos, cap - pos);
        check(got > 0 && (pos > 0 || (size_t)got < cap), "force an incomplete initial write");
        pos += (size_t)got;
        mp_tcp_relay_drain(r, 2);
    }
    check(memcmp(output, input[0], cap) == 0, "buffered tail after pressure");
    socket_capacity(f->client, 2 * MAX_CHUNK);
}

int main(int argc, char **argv) {
    if (argc != 7) return 2;
    bool measured = !strcmp(argv[1], "time");
    check(measured || !strcmp(argv[1], "qualify"), "time or qualify");
    size_t piece = (size_t)atoi(argv[2]) * 1024;
    check(piece == 4096 || piece == CHUNK, "fixed offer");
    check(pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0) == 0, "background QoS");
    alarm(30);
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r && mp_tcp_relay_read_bytes(r) == CHUNK && mp_tcp_data_callback_events(2) == 128,
          "flat owner with expected cap and budget");
    long page = sysconf(_SC_PAGESIZE);
    const size_t offset128 = 128;
    check(page > 128 && (size_t)page % offset128 == 0, "page size");
    size_t embedded_offset = (uintptr_t)r->scratch % (size_t)page;
    void *storage = NULL;
    check(posix_memalign(&storage, (size_t)page, CHUNK + (size_t)page) == 0, "page-aligned scratch arena");
    memset(storage, 0, CHUNK + (size_t)page);
    trial_scratch = r->scratch;
    mp_tcp_listener *lease = new_listener(r, 8080, 0);
    check(lease != NULL, "lease");
    struct flow flows[FLOWS];
    for (unsigned i = 0; i < FLOWS; ++i) {
        stage(lease, flows[i].client, flows[i].guest);
        socket_capacity(flows[i].client, 2 * MAX_CHUNK);
        socket_capacity(flows[i].guest, 2 * MAX_CHUNK);
        for (unsigned j = 0; j < MAX_CHUNK; ++j) input[i][j] = (unsigned char)(37 * i + 89 * j + j / 257);
    }
    mp_tcp_relay_drain(r, 2);
    wave(r, flows, LARGE_READ, 0);
    for (int arm = 3; arm < argc; ++arm) {
        const char *name = argv[arm];
        if (!strcmp(name, "embedded")) trial_scratch = r->scratch;
        else if (!strcmp(name, "matched")) trial_scratch = (char *)storage + embedded_offset;
        else if (!strcmp(name, "offset128")) trial_scratch = (char *)storage + offset128;
        else if (!strcmp(name, "page")) trial_scratch = storage;
        else return 2;
        memset(trial_scratch, 0xa5, CHUNK);
        wave(r, flows, piece, (unsigned)arm);
        uint64_t cpu = 0, elapsed = 0;
        unsigned waves = measured ? WORK_MIB * 1024 * 1024 / (FLOWS * piece) : 2;
        uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        for (unsigned i = 0; i < waves; ++i) cpu += wave(r, flows, piece, (uint64_t)arm << 32 | i);
        elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
        if (!measured) pressure(r, &flows[0], CHUNK);
        printf("{\"arm\":\"%s\",\"piece\":%zu,\"cap\":%d,\"page\":%ld,"
               "\"embedded_offset\":%zu,\"tested_offset\":%zu,\"verified_bytes\":%zu,"
               "\"wall_ns\":%llu,\"owner_ns\":%llu}\n", name, piece, CHUNK, page,
               embedded_offset, (size_t)((uintptr_t)trial_scratch % (size_t)page),
               FLOWS * piece * waves, (unsigned long long)elapsed, (unsigned long long)cpu);
    }
    for (unsigned i = 0; i < FLOWS; ++i) check(shutdown(flows[i].guest[0], SHUT_WR) == 0, "guest FIN");
    mp_tcp_relay_drain(r, 2);
    for (unsigned i = 0; i < FLOWS; ++i) {
        check(read(flows[i].client[0], output, 1) == 0, "forward EOF");
        check(write(flows[i].client[0], "r", 1) == 1 && shutdown(flows[i].client[0], SHUT_WR) == 0, "reverse FIN");
    }
    mp_tcp_relay_drain(r, 2);
    for (unsigned i = 0; i < FLOWS; ++i) {
        expect_bytes(flows[i].guest[0], (const unsigned char *)"r", 1);
        check(read(flows[i].guest[0], output, 1) == 0, "reverse EOF");
        close(flows[i].guest[0]); close(flows[i].client[0]);
    }
    check(!lease->head && !lease->active, "no surviving flows");
    mp_tcp_release(lease, NULL);
    mp_tcp_relay_destroy(r);
    free(storage);
    return 0;
}
