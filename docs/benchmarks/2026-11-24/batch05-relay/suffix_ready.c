// Established directions have an unwritten suffix from a real blocked relay write.
// Release its destination within a burst of ready downloads and record actual service order.
#include <unistd.h>
#include <stdint.h>
#include <stdbool.h>
enum { MAX_BULK = 32, BLOCK = 64 * 1024, MAX_STREAMS = MAX_BULK + 2 };
static bool score;
static int flow_count, dest[MAX_STREAMS];
static size_t total, ahead[MAX_STREAMS], write_count[MAX_STREAMS];
static ssize_t observe_write(int fd, const void *buf, size_t len) {
    ssize_t n = write(fd, buf, len);
    if (n > 0 && score) {
        int i = 0;
        while (i < flow_count && dest[i] != fd) ++i;
        if (i == flow_count) _exit(2);
        if (!write_count[i]++) ahead[i] = total;
        total += (size_t)n;
    }
    return n;
}
#define write(...) observe_write(__VA_ARGS__)
#define main unused_filter_fixture_main
#include "filter_work.c"
#undef main
#undef write

static unsigned char data[MAX_STREAMS][BLOCK];
static void reserve(int fd) {
    int size = 512 * 1024;
    check(setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size)) == 0 &&
          setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size)) == 0, "socket room");
}
static void run(int bulk, int unblock_after, size_t length) {
    mp_tcp_relay *r = mp_tcp_relay_create_data("127.0.0.1");
    check(r != NULL && mp_tcp_relay_read_bytes(r) == 256 * 1024, "stock flat owner");
    mp_tcp_listener *l = new_listener(r, 8080, 0);
    check(l != NULL, "lease");
    int client[MAX_STREAMS][2], guest[MAX_STREAMS][2];
    struct pair *pairs[MAX_STREAMS];
    int tagged = bulk, fresh = bulk + 1;
    flow_count = bulk + 2;
    for (int i = 0; i < flow_count; ++i) {
        pairs[i] = stage(l, client[i], guest[i]);
        dest[i] = client[i][1];
        // Keep the tagged destination small to guarantee actual backpressure.
        if (i != tagged) for (int j = 0; j < 2; ++j) {
            reserve(client[i][j]); reserve(guest[i][j]);
        }
    }
    drain(r);
    for (int i = 0; i <= tagged; ++i)
        check(write(guest[i][0], data[i], LARGE_READ) == LARGE_READ, "classify established directions");
    drain(r);
    for (int i = 0; i <= tagged; ++i) {
        expect_bytes(client[i][0], data[i], LARGE_READ);
        check(pairs[i]->guest.bulk_read, "direction classified as bulk");
    }
    size_t padding = fill(client[tagged][1]);
    check(write(guest[tagged][0], data[tagged], length) == (ssize_t)length &&
          shutdown(guest[tagged][0], SHUT_WR) == 0, "tagged payload and FIN");
    drain(r);
    check(pairs[tagged]->client.pending && pairs[tagged]->client.length == length, "pending suffix");
    for (int i = 0; i <= bulk; ++i) {
        if (i == unblock_after) consume_padding(client[tagged][0], padding);
        if (i < bulk) check(write(guest[i][0], data[i], BLOCK) == BLOCK, "queue bulk block");
    }
    check(write(guest[fresh][0], data[fresh], 1) == 1, "actual fresh reply ready");
    memset(ahead, 0, sizeof(ahead)); memset(write_count, 0, sizeof(write_count));
    total = 0; score = true;
    drain(r);
    score = false;
    check(total == (size_t)bulk * BLOCK + length + 1, "all bytes written");
    for (int i = 0; i < flow_count; ++i) {
        size_t expected = i < bulk ? BLOCK : (i == tagged ? length : 1);
        check(write_count[i] == 1, "one scored write per ready direction");
        expect_bytes(client[i][0], data[i], expected);
        if (i != tagged) check(shutdown(guest[i][0], SHUT_WR) == 0, "guest FIN");
    }
    drain(r);
    for (int i = 0; i < flow_count; ++i) {
        unsigned char c;
        check(read(client[i][0], &c, 1) == 0 && write(client[i][0], data[i], 1) == 1 &&
              shutdown(client[i][0], SHUT_WR) == 0, "forward FIN and reverse marker");
    }
    drain(r);
    for (int i = 0; i < flow_count; ++i) {
        unsigned char c;
        expect_bytes(guest[i][0], data[i], 1);
        check(read(guest[i][0], &c, 1) == 0, "reverse FIN");
        close(client[i][0]); close(guest[i][0]);
    }
    check(!l->active && !l->head, "all flows retired");
    printf("{\"bulk_streams\":%d,\"unblocked_after\":%d,\"pending_bytes\":%zu,\"verified_bytes\":%zu,"
           "\"ahead_of_suffix_bytes\":%zu,\"ahead_of_fresh_bytes\":%zu,\"ahead_of_first_bulk_bytes\":%zu}\n",
           bulk, unblock_after, length, total, ahead[tagged], ahead[fresh], ahead[0]);
    mp_tcp_release(l, NULL); mp_tcp_relay_destroy(r);
}
int main(void) {
    alarm(15);
    for (int i = 0; i < MAX_STREAMS; ++i)
        for (int j = 0; j < BLOCK; ++j) data[i][j] = (unsigned char)(i * 43 + j + j / 253);
    run(16, 0, 17); run(16, 8, 17); run(16, 16, 17);
    run(16, 16, 4096); run(16, 16, 4097); run(32, 32, 17);
    return 0;
}
