/* Untimed, fixed-work comparisons on private Darwin IPv4 loopback. */
#include <err.h>
#include <sys/uio.h>
#include <unistd.h>
#include "PublishedTCP.c"

static const char request[] = "GET /id HTTP/1.0\r\n\r\n";
static unsigned char chunk[16384];
static struct sockaddr_in address = {
    .sin_family = AF_INET, .sin_len = sizeof(struct sockaddr_in),
    .sin_addr = { .s_addr = 0 }
};

static void check(int ok, const char *message) {
    if (!ok) err(1, "%s", message);
}

static int read_int(int fd, int level, int option) {
    int value;
    socklen_t length = sizeof(value);
    check(getsockopt(fd, level, option, &value, &length) == 0 && length == sizeof(value), "getsockopt");
    return value;
}

static void set_int(int fd, int level, int option, int value) {
    check(setsockopt(fd, level, option, &value, sizeof(value)) == 0, "setsockopt");
}

static struct tcp_connection_info info(int fd) {
    struct tcp_connection_info value = {0};
    socklen_t length = sizeof(value);
    check(getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &value, &length) == 0 && length == sizeof(value), "TCP_CONNECTION_INFO");
    return value;
}

static void send_bytes(int fd, const unsigned char *data, size_t remaining) {
    while (remaining) {
        ssize_t n = send(fd, data, remaining, 0);
        check(n > 0, "send");
        data += n;
        remaining -= n;
    }
}

static void verify_bytes(int fd, const unsigned char *data, size_t remaining) {
    unsigned char buffer[16384];
    while (remaining) {
        size_t want = remaining < sizeof(buffer) ? remaining : sizeof(buffer);
        ssize_t n = recv(fd, buffer, want, 0);
        check(n > 0 && memcmp(buffer, data, n) == 0, "receive/payload");
        data += n;
        remaining -= n;
    }
}

static void verify_eof(int fd) {
    unsigned char byte;
    check(recv(fd, &byte, 1, 0) == 0, "EOF");
}

static void window(int listener, bool late) {
    mp_tcp_relay *relay = mp_tcp_relay_create_data("127.0.0.1");
    check(relay != NULL, "new relay");
    mp_tcp_listener lease = {.relay = relay, .target = address};
    int dummy[2];
    check(socketpair(AF_UNIX, SOCK_STREAM, 0, dummy) == 0, "private client fixture");
    struct pair pair = {.listener = &lease, .client = {.watch = {STREAM, dummy[0]}},
                        .guest = {.watch = {STREAM, -1}}};
    pair.client.pair = pair.guest.pair = &pair;
    if (!late) mp_tcp_relay_bound_guest_window(relay);
    check(dial_guest(&pair, 3) == 0, "actual relay dial");
    int remote = accept(listener, NULL, NULL);
    check(remote >= 0, "accept relay");
    int local = pair.guest.watch.fd;
    check(read_int(local, SOL_SOCKET, SO_ERROR) == 0, "handshake");
    int before = read_int(local, SOL_SOCKET, SO_RCVBUF);
    if (late) {
        mp_tcp_relay_bound_guest_window(relay);
        set_int(local, SOL_SOCKET, SO_RCVBUF, relay->guest_receive_buffer);
    }
    int effective = read_int(local, SOL_SOCKET, SO_RCVBUF);
    check(fcntl(local, F_SETFL, 0) == 0, "blocking fixture reads after dial");
    struct tcp_connection_info li = info(local), ri = info(remote);
    for (unsigned i = 0; i < 32; i++) {
        send_bytes(remote, chunk, sizeof(chunk));
        verify_bytes(local, chunk, sizeof(chunk));
    }
    check(shutdown(remote, SHUT_WR) == 0, "finish");
    verify_eof(local);
    check(shutdown(local, SHUT_WR) == 0, "finish local");
    verify_eof(remote);
    struct tcp_connection_info end = info(remote);
    printf(",\"requested_rcvbuf\":%d,\"at_accept_rcvbuf\":%d,\"final_rcvbuf\":%d,"
           "\"local_rcv_wscale\":%u,\"remote_snd_wscale\":%u,\"local_options\":%u,\"remote_options\":%u,"
           "\"local_rcv_wnd\":%u,\"remote_snd_wnd\":%u,\"verified_payload_bytes\":%zu,\"eof\":true,\"tx_retrans_packets\":%llu",
           relay->guest_receive_buffer, before, effective, li.tcpi_rcv_wscale, ri.tcpi_snd_wscale,
           li.tcpi_options, ri.tcpi_options, li.tcpi_rcv_wnd, ri.tcpi_snd_wnd, 32*sizeof(chunk), end.tcpi_txretransmitpackets);
    close(local); close(remote); close(dummy[0]); close(dummy[1]);
    mp_tcp_relay_destroy(relay);
}

static void fastopen(int listener, bool early) {
    int client = socket(AF_INET, SOCK_STREAM, 0);
    check(client >= 0, "active socket");
    set_int(client, IPPROTO_TCP, TCP_NODELAY, 1);
    size_t early_written = 0, count = sizeof(request) - 1;
    if (early) {
        sa_endpoints_t endpoints = {.sae_dstaddr = (struct sockaddr *)&address, .sae_dstaddrlen = sizeof(address)};
        struct iovec initial = {.iov_base = (void *)request, .iov_len = count};
        check(connectx(client, &endpoints, SAE_ASSOCID_ANY, CONNECT_DATA_IDEMPOTENT,
                       &initial, 1, &early_written, NULL) == 0 && early_written <= count, "connectx");
    } else {
        check(connect(client, (struct sockaddr *)&address, sizeof(address)) == 0, "connect");
    }
    send_bytes(client, (const unsigned char *)request + early_written, count - early_written);
    int server = accept(listener, NULL, NULL);
    check(server >= 0, "accept request");
    verify_bytes(server, (const unsigned char *)request, count);
    send_bytes(server, chunk, 256);
    verify_bytes(client, chunk, 256);
    check(shutdown(client, SHUT_WR) == 0, "finish request");
    verify_eof(server);
    check(shutdown(server, SHUT_WR) == 0, "finish response");
    verify_eof(client);
    struct tcp_connection_info c = info(client), s = info(server);
    printf(",\"listener_tfo\":%d,\"connectx_accepted_bytes\":%zu,\"request_bytes\":%zu,\"response_bytes\":256,"
           "\"eof\":true,\"cookie_requested\":%u,\"cookie_received\":%u,\"syn_loss\":%u,"
           "\"syn_data_sent\":%u,\"syn_data_acked\":%u,\"server_syn_data_received\":%u,"
           "\"server_cookie_requested\":%u,\"server_cookie_sent\":%u,\"cookie_invalid\":%u,\"cookie_wrong\":%u,"
           "\"cookie_missing\":%u,\"heuristics_disabled\":%u,\"client_retrans_packets\":%llu,\"server_retrans_packets\":%llu",
           read_int(listener, IPPROTO_TCP, TCP_FASTOPEN), early_written, count, c.tcpi_tfo_cookie_req, c.tcpi_tfo_cookie_rcv,
           c.tcpi_tfo_syn_loss, c.tcpi_tfo_syn_data_sent, c.tcpi_tfo_syn_data_acked, s.tcpi_tfo_syn_data_rcv,
           s.tcpi_tfo_cookie_req_rcv, s.tcpi_tfo_cookie_sent, s.tcpi_tfo_cookie_invalid, s.tcpi_tfo_cookie_wrong,
           c.tcpi_tfo_no_cookie_rcv, c.tcpi_tfo_heuristics_disable, c.tcpi_txretransmitpackets, s.tcpi_txretransmitpackets);
    close(server); close(client);
}

int main(int argc, char **argv) {
    check(argc == 3 && (!strcmp(argv[1],"window") || !strcmp(argv[1],"fastopen")) && strlen(argv[2]) == 16, "arguments");
    bool tfo = !strcmp(argv[1], "fastopen");
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    check(listener >= 0, "private listener");
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    check(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0 && listen(listener, 4) == 0, "bind/listen");
    if (tfo) set_int(listener, IPPROTO_TCP, TCP_FASTOPEN, 1);
    socklen_t len = sizeof(address);
    check(getsockname(listener, (struct sockaddr *)&address, &len) == 0, "private address");
    for (unsigned i = 0; i < sizeof(chunk); i++) chunk[i] = (i * 73 + (i >> 8)) & 255;
    setvbuf(stdout, NULL, _IONBF, 0);
    for (unsigned i = 0; i < 16; i++) {
        for (unsigned j = 0; j < 2; j++) {
            bool candidate = (argv[2][i] == 'B') != (j != 0);
            printf("{\"case\":\"%s\",\"block\":%u,\"position\":%u,\"arm\":\"%s\"", argv[1], i+1, j+1, candidate ? "candidate" : "control");
            if (tfo) fastopen(listener, candidate); else window(listener, candidate);
            puts("}");
        }
    }
    close(listener);
    return 0;
}
