/* One private native TCP stream. The receiver holds reads for two producer turns. */
#include <err.h>
#include <poll.h>
#include "PublishedTCP.c"

enum { BUDGET = 65536, TOTAL = 2 * CHUNK };
static unsigned char bulk[TOTAL];
static const unsigned char marker[17] = {[0 ... 16] = 255};
static int run_id;
static bool budgeted;

static void require(bool ok, const char *description) {
    if (!ok) errx(1, "%s (errno %d)", description, errno);
}

static int option(int fd, int level, int key) {
    int value = -1;
    socklen_t len = sizeof(value);
    require(getsockopt(fd, level, key, &value, &len) == 0 && len == sizeof(value), "get option");
    return value;
}

static void request_size(int fd, int key, int value) {
    require(setsockopt(fd, SOL_SOCKET, key, &value, sizeof(value)) == 0, "set fixture buffer");
}

static struct tcp_connection_info counters(int fd) {
    struct tcp_connection_info value = {0};
    socklen_t len = sizeof(value);
    require(getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &value, &len) == 0 &&
            len == sizeof(value), "Darwin TCP counters");
    return value;
}

static size_t offer(int fd, const char *phase, const unsigned char *data, size_t offered) {
    uint32_t before = counters(fd).tcpi_snd_sbbytes;
    size_t permitted = offered;
    if (budgeted) {
        size_t room = before < BUDGET ? BUDGET - before : 0;
        if (permitted > room) permitted = room;
    }
    ssize_t wrote = 0;
    int error = 0;
    if (permitted) {
        wrote = send(fd, data, permitted, 0);
        if (wrote < 0) {
            error = errno;
            require(error == EAGAIN || error == EWOULDBLOCK, "nonblocking write");
            wrote = 0;
        }
    }
    uint32_t after = counters(fd).tcpi_snd_sbbytes;
    printf("{\"event\":\"offer\",\"run\":%d,\"phase\":\"%s\",\"offered\":%zu,\"before\":%u,"
           "\"permitted\":%zu,\"accepted\":%zd,\"after\":%u,\"errno\":%d}\n",
           run_id, phase, offered, before, permitted, wrote, after, error);
    return (size_t)wrote;
}

static void take(int fd, const unsigned char *expected, size_t n) {
    unsigned char buf[8192];
    while (n) {
        ssize_t received = recv(fd, buf, n < sizeof(buf) ? n : sizeof(buf), 0);
        require(received > 0 && memcmp(expected, buf, (size_t)received) == 0, "peer byte order");
        expected += received;
        n -= (size_t)received;
    }
}

/* Client waits only for an explicit drain acknowledgement. No elapsed time is scored. */
static void drain_ack(int client, int peer) {
    unsigned char b = 19;
    require(send(peer, &b, 1, 0) == 1, "receiver acknowledgement");
    struct pollfd p = {.fd=client, .events=POLLIN};
    require(poll(&p, 1, 2000) == 1, "drain acknowledgement watchdog");
    take(client, &b, 1);
}

static void run(int listener, const struct sockaddr_in *address, int pair, int position) {
    printf("{\"event\":\"attempt\",\"run\":%d,\"pair\":%d,\"position\":%d,\"arm\":\"%s\"}\n",
           run_id, pair, position, budgeted ? "budget" : "eager");
    int client = socket(AF_INET, SOCK_STREAM, 0);
    require(client >= 0 && prepare(client) == 0, "stock Micropod socket setup");
    request_size(client, SO_SNDBUF, TOTAL);
    int connected = connect(client, (const struct sockaddr *)address, sizeof(*address));
    require(connected == 0 || errno == EINPROGRESS, "private connect");
    int peer = accept(listener, NULL, NULL);
    require(peer >= 0 && option(client, SOL_SOCKET, SO_ERROR) == 0, "private accept");
    struct tcp_connection_info start = counters(client);
    struct tcp_connection_info peer_start = counters(peer);
    printf("{\"event\":\"options\",\"run\":%d,\"sndbuf\":%d,\"listener_rcvbuf\":%d,\"peer_rcvbuf\":%d,"
           "\"tcp_nodelay\":%d,\"notsent_lowat\":%d,\"nonblocking\":%d,\"initial_snd_sbbytes\":%u}\n",
           run_id, option(client, SOL_SOCKET, SO_SNDBUF), option(listener, SOL_SOCKET, SO_RCVBUF),
           option(peer, SOL_SOCKET, SO_RCVBUF), option(client, IPPROTO_TCP, TCP_NODELAY),
           option(client, IPPROTO_TCP, TCP_NOTSENT_LOWAT), !!(fcntl(client, F_GETFL) & O_NONBLOCK),
           start.tcpi_snd_sbbytes);
    size_t bulk_before = offer(client, "held-1", bulk, CHUNK);
    bulk_before += offer(client, "held-2", bulk + bulk_before, CHUNK);

    /* This fixture's source can prioritize an independent marker before the
       still-unsubmitted suffix. A transparent relay cannot reorder TCP bytes. */
    size_t marked = offer(client, "marker-held", marker, sizeof(marker));
    take(peer, bulk, bulk_before);
    take(peer, marker, marked);
    drain_ack(client, peer);
    while (marked < sizeof(marker)) {
        size_t wrote = offer(client, "marker-after-drain", marker + marked, sizeof(marker) - marked);
        require(wrote > 0, "marker progressed after drain");
        take(peer, marker + marked, wrote);
        marked += wrote;
        drain_ack(client, peer);
    }
    size_t sent = bulk_before;
    while (sent < TOTAL) {
        size_t left = TOTAL - sent;
        size_t wrote = offer(client, "bulk-after-marker", bulk + sent, left < CHUNK ? left : CHUNK);
        require(wrote > 0, "bulk progressed after drain");
        take(peer, bulk + sent, wrote);
        sent += wrote;
        drain_ack(client, peer);
    }
    unsigned char b;
    require(shutdown(client, SHUT_WR) == 0 && recv(peer, &b, 1, 0) == 0, "peer EOF");
    require(shutdown(peer, SHUT_WR) == 0, "sender half-close");
    struct pollfd eof = {.fd=client, .events=POLLIN};
    require(poll(&eof, 1, 2000) == 1 && recv(client, &b, 1, 0) == 0, "client EOF");
    struct tcp_connection_info end = counters(client), peer_end = counters(peer);
    printf("{\"event\":\"result\",\"run\":%d,\"bulk_before_marker_at_receiver\":%zu,"
           "\"verified_bulk\":%zu,\"verified_marker\":%zu,\"both_eof\":true,"
           "\"sender_retransmitted_packets\":%llu,\"peer_retransmitted_packets\":%llu,"
           "\"final_snd_sbbytes\":%u,\"final_peer_rcvbuf\":%d}\n", run_id, bulk_before, sent, marked,
           end.tcpi_txretransmitpackets - start.tcpi_txretransmitpackets,
           peer_end.tcpi_txretransmitpackets - peer_start.tcpi_txretransmitpackets,
           end.tcpi_snd_sbbytes, option(peer, SOL_SOCKET, SO_RCVBUF));
    close(client);
    close(peer);
}

int main(int argc, char **argv) {
    if (argc != 2 || strlen(argv[1]) != 8 || strspn(argv[1], "AB") != 8) return 2;
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (size_t i = 0; i < TOTAL; i++) bulk[i] = (unsigned char)((i * 17 + i / 4096) % 127);
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    require(listener >= 0, "create listener");
    request_size(listener, SO_RCVBUF, 8192);
    struct sockaddr_in address = {.sin_family=AF_INET, .sin_len=sizeof(address),
                                  .sin_addr={htonl(INADDR_LOOPBACK)}};
    require(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0, "bind private loopback");
    require(listen(listener, 4) == 0, "listen private loopback");
    socklen_t len = sizeof(address);
    require(getsockname(listener, (struct sockaddr *)&address, &len) == 0, "ephemeral port");
    alarm(30);
    for (int pair = 0; pair < 8; pair++) {
        for (int position = 0; position < 2; position++) {
            budgeted = (argv[1][pair] == 'B') ^ position;
            run_id++;
            run(listener, &address, pair + 1, position + 1);
        }
    }
    close(listener);
    return 0;
}
