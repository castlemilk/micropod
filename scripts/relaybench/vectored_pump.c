// Only relay payload I/O changes between binaries. The test peers always use scalar I/O.
#include <pthread.h>
#include <pthread/qos.h>

#define RELAY_SOURCE "vectored_pump.h"
#define main qualify_filter_cases
#include "filter_work.c"
#undef main

static void fixed_work(size_t size, unsigned rounds) {
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r != NULL, "create data owner");
    mp_tcp_listener *l = new_listener(r, 8080, 0);
    check(l != NULL, "allocate lease");
    int client[2], guest[2];
    struct pair *p = stage(l, client, guest);
    int buffer_size = 2 * CHUNK;
    for (int i = 0; i < 2; ++i) {
        check(setsockopt(guest[i], SOL_SOCKET, SO_RCVBUF, &buffer_size, sizeof(buffer_size)) == 0 &&
              setsockopt(guest[i], SOL_SOCKET, SO_SNDBUF, &buffer_size, sizeof(buffer_size)) == 0 &&
              setsockopt(client[i], SOL_SOCKET, SO_RCVBUF, &buffer_size, sizeof(buffer_size)) == 0 &&
              setsockopt(client[i], SOL_SOCKET, SO_SNDBUF, &buffer_size, sizeof(buffer_size)) == 0,
              "make room for one complete chunk");
    }
    drain(r);
    check(l->head == p && !p->guest.connecting, "complete connection");
    static unsigned char bytes[CHUNK];
    for (size_t i = 0; i < size; ++i) bytes[i] = (unsigned char)(i * 193 + i / 257);
    payload_reads = payload_writes = 0;
    uint64_t cpu_ns = 0;
    for (unsigned i = 0; i < rounds; ++i) {
        memcpy(bytes, &i, sizeof(i));
        check(write(guest[0], bytes, size) == (ssize_t)size, "queue complete chunk");
        uint64_t start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
        pump(&p->guest, &p->client);
        cpu_ns += clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start;
        check(l->head == p && !p->client.pending, "forward full chunk in one turn");
        expect_bytes(client[0], bytes, size);
    }
    check(payload_reads == rounds && payload_writes == rounds, "one input and output syscall per chunk");
    printf("{\"chunk_bytes\":%zu,\"rounds\":%u,\"payload_reads\":%u,\"payload_writes\":%u,"
           "\"thread_cpu_ns\":%llu}\n", size, rounds, payload_reads, payload_writes, (unsigned long long)cpu_ns);
    mp_tcp_release(l, NULL);
    mp_tcp_relay_destroy(r);
    close(guest[0]);
    close(client[0]);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    qos_class_t qos;
    int relative;
    check(pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0) == 0 &&
          pthread_get_qos_class_np(pthread_self(), &qos, &relative) == 0 &&
          qos == QOS_CLASS_BACKGROUND, "background test thread");
    if (!strcmp(argv[1], "qualify")) {
        int status = qualify_filter_cases();
        check(short_inside_second > 0 && blocked_payload_writes > 0, "real partial and blocked writes");
        printf("{\"payload_reads\":%u,\"payload_writes\":%u,\"short_inside_second\":%u,"
               "\"blocked_payload_writes\":%u,\"max_chunk\":%u}\n", payload_reads, payload_writes,
               short_inside_second, blocked_payload_writes, CHUNK);
        return status;
    }
    if (strcmp(argv[1], "measure")) return 2;
    alarm(12);
    fixed_work(148, 2048);  // Mean archived fresh download bytes per accepted stream.
    fixed_work(CHUNK, 128);
    return 0;
}
