#include "PublishedTCP.h"
#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

enum { BODY = 16384 };

static void require(bool ok, const char *stage) {
    if (!ok) {
        fprintf(stderr, "fixture failure at %s (errno %d: %s)\n", stage, errno, strerror(errno));
        exit(1);
    }
}

static struct sockaddr_in loopback(uint16_t port) {
    return (struct sockaddr_in){.sin_len = sizeof(struct sockaddr_in), .sin_family = AF_INET,
                               .sin_addr.s_addr = htonl(INADDR_LOOPBACK), .sin_port = htons(port)};
}

static int queued(int fd) {
    int bytes = -1;
    require(ioctl(fd, FIONREAD, &bytes) == 0, "FIONREAD");
    return bytes;
}

/* The event owner and applications run serially, so application progress at
 * the barrier is explicit. Use the alarm solely as a failure deadline. */
static void tick(mp_tcp_relay *relay) {
    mp_tcp_relay_drain(relay, 0);
    usleep(1000);
}

int main(int argc, char **argv) {
    require(argc == 3, "expected policy and pair index");
    bool consume = !strcmp(argv[1], "consume");
    require(consume || !strcmp(argv[1], "pause"), "policy");
    int pair = atoi(argv[2]);
    signal(SIGPIPE, SIG_IGN);
    alarm(4);

    int service = socket(AF_INET, SOCK_STREAM, 0);
    require(service >= 0, "service socket");
    struct sockaddr_in service_addr = loopback(0);
    require(bind(service, (struct sockaddr *)&service_addr, sizeof(service_addr)) == 0,
            "ephemeral loopback service bind");
    require(listen(service, 1) == 0, "service listen");
    socklen_t length = sizeof(service_addr);
    require(getsockname(service, (struct sockaddr *)&service_addr, &length) == 0, "service address");
    uint16_t guest_port = ntohs(service_addr.sin_port), published_port = 0;
    mp_tcp_relay *relay = mp_tcp_relay_create("127.0.0.1");
    require(relay != NULL, "relay create");
    mp_tcp_listener *listener = mp_tcp_listen(relay, 0, guest_port, &published_port, 1);
    require(listener != NULL, "production loopback publish");
    int client = socket(AF_INET, SOCK_STREAM, 0);
    require(client >= 0, "client socket");
    struct sockaddr_in published = loopback(published_port);
    require(connect(client, (struct sockaddr *)&published, sizeof(published)) == 0, "client connect");
    unsigned char request = (unsigned char)(0xa0 + pair);
    require(send(client, &request, 1, 0) == 1, "request");
    struct pollfd service_accept = {.fd = service, .events = POLLIN};
    int ready;
    while ((ready = poll(&service_accept, 1, 0)) == 0) tick(relay);
    require(ready == 1, "service accept readiness");
    int guest = accept(service, NULL, NULL);
    require(guest >= 0, "private second TCP leg");
    while (queued(guest) != 1) tick(relay);
    unsigned char received_request = 0;
    require(recv(guest, &received_request, 1, 0) == 1 && received_request == request,
            "verify request at service");
    unsigned char body[BODY], received[BODY];
    for (size_t i = 0; i < BODY; ++i) body[i] = (unsigned char)((i * 97 + i / 211 + pair) % 251);
    size_t offered = 0;
    while (offered < BODY) {
        ssize_t n = send(guest, body + offered, BODY - offered, 0);
        require(n > 0, "service response");
        offered += (size_t)n;
    }
    /* Both arms arrive here with a full kernel queue and zero client reads. */
    int barrier;
    while ((barrier = queued(client)) != BODY) tick(relay);
    size_t consumed = 0;
    int receive_calls = 0;
    if (consume) {
        while (consumed < BODY) {
            ++receive_calls;
            ssize_t n = recv(client, received + consumed, BODY - consumed, 0);
            require(n > 0, "client consume");
            consumed += (size_t)n;
        }
        require(memcmp(body, received, BODY) == 0, "client integrity");
    }
    int before_close = queued(client);
    require(before_close == BODY - (int)consumed, "pre-close receive queue accounting");
    struct linger reset = {.l_onoff = 1, .l_linger = 0};
    require(setsockopt(client, SOL_SOCKET, SO_LINGER, &reset, sizeof(reset)) == 0, "set abortive close");
    struct linger effective = {0};
    socklen_t option_size = sizeof(effective);
    require(getsockopt(client, SOL_SOCKET, SO_LINGER, &effective, &option_size) == 0 &&
            effective.l_onoff && !effective.l_linger, "verify abortive close");
    require(close(client) == 0, "close client");
    unsigned char byte;
    int guest_terminal = -1;
    while (guest_terminal < 0) {
        tick(relay);
        ssize_t n = recv(guest, &byte, 1, MSG_DONTWAIT);
        if (n == 0) guest_terminal = 0;
        else if (n < 0 && errno == ECONNRESET) guest_terminal = ECONNRESET;
        else require(n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR),
                     "unexpected post-close guest data");
    }
    mp_tcp_stats s = {0};
    mp_tcp_release(listener, &s);
    mp_tcp_relay_destroy(relay);
    close(guest);
    close(service);
    printf("{\"service_port\":%u,\"published_port\":%u,\"verified_request_byte\":%u,"
           "\"guest_sent_bytes\":%zu,\"client_queue_at_barrier\":%d,\"client_recv_calls\":%d,"
           "\"client_application_bytes\":%zu,\"payload_verified\":%s,\"client_queue_before_close\":%d,"
           "\"client_linger_on\":%d,\"client_linger_seconds\":%d,\"guest_terminal_errno\":%d,"
           "\"relay\":{\"accepted\":%llu,\"connected\":%llu,\"connect_errors\":%llu,"
           "\"upload_bytes\":%llu,\"guest_read_bytes\":%llu,\"download_bytes\":%llu,"
           "\"blocked_writes\":%llu,\"pending_allocations\":%llu,\"pending_copy_bytes\":%llu,"
           "\"stream_errors\":%llu,\"resets_forwarded\":%llu,\"setup_closes\":%llu,"
           "\"closes_before_response\":%llu,\"reads\":%llu,\"writes\":%llu}}\n",
           guest_port, published_port, received_request, offered, barrier, receive_calls, consumed,
           consume ? "true" : "null", before_close, effective.l_onoff, effective.l_linger, guest_terminal,
           s.accepted, s.connected, s.connect_errors, s.upload_bytes, s.guest_read_bytes, s.download_bytes,
           s.blocked_writes, s.pending_allocations, s.pending_copy_bytes, s.stream_errors, s.resets_forwarded,
           s.setup_closes, s.closes_before_response, s.reads, s.writes);
    return 0;
}
