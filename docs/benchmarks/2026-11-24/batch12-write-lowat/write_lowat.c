// Exercise the production pending-write path with the receiver releasing 4 KiB per turn.
#define main filter_work_main
#include "../../../../scripts/relaybench/filter_work.c"
#undef main

static size_t fill_destination(int fd) {
    size_t filled = 0;
    ssize_t n;
    while ((n = write(fd, padding, sizeof(padding))) > 0) {
        filled += (size_t)n;
        check(filled <= 1 << 20, "bounded prefill");
    }
    check(filled > 0 && n < 0 && errno == EAGAIN, "backpressured receiver");
    return filled;
}

static int lowat(int fd) {
    int value = 0;
    socklen_t size = sizeof(value);
    check(getsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &value, &size) == 0 && value > 0,
          "effective send threshold");
    return value;
}

static void transfer(int threshold, size_t bytes, bool pressured, int send_capacity, size_t initial_room) {
    mp_tcp_relay *owner = mp_tcp_relay_create_data("127.0.0.1");
    check(owner != NULL, "create data owner");
    mp_tcp_listener *l = new_listener(owner, 8080, 1);
    check(l != NULL, "create lease");
    int client[2], guest[2];
    struct pair *pair = stage(l, client, guest);
    drain(owner);
    check(l->head == pair && !pair->guest.connecting, "admit stream");

    if (send_capacity != SOCKET_BUFFER)
        check(setsockopt(client[1], SOL_SOCKET, SO_SNDBUF, &send_capacity, sizeof(send_capacity)) == 0,
              "small send buffer control");
    int effective_capacity = 0;
    socklen_t size = sizeof(effective_capacity);
    check(getsockopt(client[1], SOL_SOCKET, SO_SNDBUF, &effective_capacity, &size) == 0 &&
          effective_capacity == send_capacity, "verify send capacity");
    if (threshold)
        check(setsockopt(client[1], SOL_SOCKET, SO_SNDLOWAT, &threshold, sizeof(threshold)) == 0,
              "set low water mark");
    int effective = lowat(client[1]);
    check(!threshold || effective == threshold, "verify requested threshold");
    size_t filled = pressured ? fill_destination(client[1]) : 0;
    check(initial_room <= filled && initial_room < bytes, "initial write space");
    consume_padding(client[0], initial_room);
    filled -= initial_room;
    check(write(guest[0], payload, bytes) == (ssize_t)bytes, "offer payload");
    check(shutdown(guest[0], SHUT_WR) == 0, "queue FIN behind payload");
    drain(owner);
    size_t initial_pending = pressured ? bytes - initial_room : 0;
    check(l->head == pair && pair->client.length == initial_pending,
          "check initial forward progress");
    int while_pending = lowat(client[1]);
    unsigned char marker = 117, eof;
    check(write(client[0], &marker, 1) == 1, "offer reverse request");
    drain(owner);
    expect_bytes(guest[0], &marker, 1);
    uint64_t initial_writes = l->stats.writes;
    size_t first_progress = 0, fully_queued = 0;
    size_t freed = 0, consumed_payload = 0;
    while (freed < filled || pair->client.pending) {
        size_t step = sizeof(padding);
        if (freed < filled) {
            if (step > filled - freed) step = filled - freed;
            consume_padding(client[0], step);
        } else {
            int available = 0;
            check(ioctl(client[0], FIONREAD, &available) == 0 && available > 0, "can continue draining");
            if (step > (size_t)available) step = (size_t)available;
            check(step <= bytes - consumed_payload, "payload bound");
            expect_bytes(client[0], payload + consumed_payload, step);
            consumed_payload += step;
        }
        freed += step;
        drain(owner);
        check(l->head == pair, "lease still active");
        if (!first_progress && pair->client.length < initial_pending) first_progress = freed;
        if (!fully_queued && !pair->client.pending) fully_queued = freed;
    }
    check(!pair->client.pending, "retained suffix cleared");
    check(lowat(client[1]) == effective, "restore original socket option");
    expect_bytes(client[0], payload + consumed_payload, bytes - consumed_payload);
    uint64_t retries = l->stats.writes - initial_writes;
    check(l->stats.download_bytes == bytes && l->stats.upload_bytes == 1,
          "relay bytes match independently read payload");
    drain(owner);
    check(read(client[0], &eof, 1) == 0 && shutdown(client[0], SHUT_WR) == 0, "client FIN");
    drain(owner);
    check(read(guest[0], &eof, 1) == 0 && !l->head, "guest FIN and retire");
    printf("{\"requested\":%d,\"effective\":%d,\"while_pending\":%d,\"send_capacity\":%d,\"initial_room\":%zu,\"initial_pending\":%zu,\"payload\":%zu,\"prefill\":%zu,"
           "\"receiver_drain_at_first_progress\":%zu,\"receiver_drain_at_final_write\":%zu,"
           "\"relay_retry_writes\":%llu,\"verified_marker\":1,\"verified_eofs\":2}\n",
           threshold, effective, while_pending, send_capacity, initial_room, initial_pending, bytes, filled, first_progress, fully_queued, retries);
    mp_tcp_release(l, NULL);
    mp_tcp_relay_destroy(owner);
    close(client[0]);
    close(guest[0]);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    alarm(10);
    for (size_t i = 0; i < sizeof(payload); ++i) payload[i] = (unsigned char)(i * 93 + i / 257);
    for (int pressured = 0; pressured <= 1; ++pressured) {
        const size_t sizes[] = {PAYLOAD, 1024, 20 * 1024};
        for (int n = 0; n < 3; ++n) {
            size_t bytes = sizes[n];
            for (int i = 0; i < 2; ++i)
                transfer((i ^ (n & 1) ^ pressured) * 16384, bytes, pressured, SOCKET_BUFFER, 0);
        }
    }
    transfer(8192, 20 * 1024, true, SOCKET_BUFFER, 0);
    transfer(0, PAYLOAD, true, 8192, 0);
    transfer(0, PAYLOAD, true, SOCKET_BUFFER, 12 * 1024);
}
