#include <err.h>
#include <poll.h>
#include <stdio.h>
#include <unistd.h>
#include "PublishedTCP.c"

static struct sockaddr_in destination = {.sin_family=AF_INET, .sin_len=sizeof(struct sockaddr_in)};
static unsigned char data[2 * CHUNK];

static void check(int ok, const char *message) {
    if (!ok) err(1, "%s", message);
}

static int read_option(int fd, int level, int key) {
    int value = -1;
    socklen_t n = sizeof(value);
    check(getsockopt(fd, level, key, &value, &n) == 0 && n == sizeof(value), "read option");
    return value;
}

static void set_option(int fd, int level, int key, int value) {
    check(setsockopt(fd, level, key, &value, sizeof(value)) == 0, "set option");
}

static struct tcp_connection_info stats(int fd) {
    struct tcp_connection_info s = {0};
    socklen_t n = sizeof(s);
    check(getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &s, &n) == 0 && n == sizeof(s), "get TCP counters");
    return s;
}

static void take(int fd, const unsigned char *expected, size_t n) {
    unsigned char buf[4096];
    while (n) {
        ssize_t nb = recv(fd, buf, n < sizeof(buf) ? n : sizeof(buf), 0);
        check(nb > 0 && memcmp(buf, expected, nb) == 0, "receive exact bytes");
        expected += nb;
        n -= nb;
    }
}

static void finish(int first, int second) {
    unsigned char byte;
    check(shutdown(first, SHUT_WR) == 0 && recv(second, &byte, 1, 0) == 0, "orderly half-close");
    check(shutdown(second, SHUT_WR) == 0 && recv(first, &byte, 1, 0) == 0, "return EOF");
}

static int write_ready(int queue, int fd) {
    struct timespec now = {0};
    struct kevent ev;
    int n = kevent(queue, NULL, 0, &ev, 1, &now);
    check(n == 0 || (n == 1 && ev.ident == (uintptr_t)fd && ev.filter == EVFILT_WRITE &&
                    !(ev.flags & (EV_EOF|EV_ERROR))), "sample write readiness");
    return n;
}

static void pending(int dial, int peer, int candidate) {
    int queue = kqueue();
    check(queue >= 0, "private queue");
    set_option(dial, SOL_SOCKET, SO_SNDBUF, 2 * CHUNK);
    int initial = read_option(dial, IPPROTO_TCP, TCP_NOTSENT_LOWAT);
    if (candidate) set_option(dial, IPPROTO_TCP, TCP_NOTSENT_LOWAT, 16384);
    int applied = read_option(dial, IPPROTO_TCP, TCP_NOTSENT_LOWAT);
    struct kevent ev;
    EV_SET(&ev, dial, EVFILT_WRITE, EV_ADD|EV_ENABLE, 0, 0, NULL);
    check(kevent(queue, &ev, 1, NULL, 0, NULL) == 0, "enable write readiness");
    int before = write_ready(queue, dial);
    struct tcp_connection_info start = stats(dial);
    ssize_t one = send(dial, data, CHUNK, 0);
    check(one > 0, "first nonblocking send");
    int ready = write_ready(queue, dial);
    struct tcp_connection_info first = stats(dial);
    ssize_t two = send(dial, data + one, CHUNK, 0);
    int blocked = two < 0;
    check(two > 0 || (blocked && (errno == EAGAIN || errno == EWOULDBLOCK)), "second nonblocking send");
    if (blocked) two = 0;
    size_t received = (size_t)(one + two);
    take(peer, data, received);
    int ready_after = write_ready(queue, dial);
    check(fcntl(dial, F_SETFL, 0) == 0, "blocking final verification");
    while (received < sizeof(data)) {
        size_t chunk = sizeof(data) - received;
        if (chunk > 4096) chunk = 4096;
        ssize_t n = send(dial, data + received, chunk, 0);
        check(n > 0, "send remaining bytes");
        take(peer, data + received, n);
        received += n;
    }
    finish(dial,peer);
    struct tcp_connection_info end = stats(dial);
    printf(",\"default_lowat\":%d,\"effective_lowat\":%d,\"sndbuf\":%d,\"peer_rcvbuf\":%d,"
           "\"ready_initial\":%d,\"first_write\":%zd,\"ready_after_one\":%d,\"tx_payload_after_one\":%llu,"
           "\"sndbuf_used_after_one\":%u,\"second_write\":%zd,\"second_eagain\":%d,\"ready_after_drain\":%d,"
           "\"verified_bytes\":%zu,\"both_eof\":true,\"sender_retransmitted_packets\":%llu}\n",
           initial,applied,read_option(dial,SOL_SOCKET,SO_SNDBUF),read_option(peer,SOL_SOCKET,SO_RCVBUF),
           before,one,ready,first.tcpi_txbytes - start.tcpi_txbytes,first.tcpi_snd_sbbytes,two,blocked,ready_after,
           received,end.tcpi_txretransmitpackets-start.tcpi_txretransmitpackets);
    close(queue);
    close(peer);
    close(dial);
}

static void messages(int client, int server) {
    check(send(client, data, 20, 0) == 20, "fresh request");
    take(server, data, 20);
    check(send(server, data+20, 1024, 0) == 1024, "fresh reply");
    take(client, data+20, 1024);
}

static void source_reuse(int client, int server, int listener, int peer_first) {
    check(fcntl(client, F_SETFL, 0) == 0, "blocking receive");
    struct sockaddr_in source;
    socklen_t n = sizeof(source);
    check(getsockname(client, (struct sockaddr *)&source, &n) == 0 &&
          source.sin_addr.s_addr == htonl(INADDR_LOOPBACK) && source.sin_port, "owned local tuple");
    messages(client, server);
    finish(peer_first ? server : client, peer_first ? client : server);
    int first_retrans = stats(client).tcpi_txretransmitpackets + stats(server).tcpi_txretransmitpackets;
    close(client);
    close(server);
    int second = socket(AF_INET, SOCK_STREAM, 0);
    check(second >= 0 && prepare(second) == 0, "prepare redial");
    int reuse = read_option(second, SOL_SOCKET, SO_REUSEADDR);
    int bind_error = 0, connect_error = 0, deadline = 0, verified = 0;
    if (bind(second, (struct sockaddr *)&source, sizeof(source)) < 0) {
        bind_error = errno;
    } else {
        int rc = connect(second, (struct sockaddr *)&destination, sizeof(destination));
        if (rc < 0 && errno != EINPROGRESS) connect_error = errno;
        else {
            struct pollfd p = {.fd=second,.events=POLLOUT};
            int count = poll(&p, 1, 200);
            check(count >= 0, "redial guard");
            deadline = count == 0;
            if (!deadline) connect_error = read_option(second,SOL_SOCKET,SO_ERROR);
        }
        if (!connect_error && !deadline) {
            int accepted = accept(listener, NULL, NULL);
            check(accepted >= 0 && fcntl(second, F_SETFL, 0) == 0, "accept redial");
            messages(second, accepted);
            finish(second, accepted);
            close(accepted);
            verified = 1;
        }
    }
    close(second);
    printf(",\"first_request_bytes\":20,\"first_response_bytes\":1024,\"first_both_eof\":true,"
           "\"first_retransmitted_packets\":%d,\"redial_reuseaddr\":%d,\"redial_bind_errno\":%d,"
           "\"redial_connect_errno\":%d,\"redial_guard_expired\":%d,\"redial_request_reply_eof_verified\":%d}\n",
           first_retrans,reuse,bind_error,connect_error,deadline,verified);
}

int main(int argc, char **argv) {
    if (argc != 3 || strlen(argv[2]) != 16 || strspn(argv[2],"AB")!=16) return 2;
    int lowat = strcmp(argv[1], "pending") == 0;
    if (!lowat && strcmp(argv[1], "reuse")) return 2;
    for (size_t i=0;i<sizeof(data);i++) data[i]=(unsigned char)(i*19+i/4096);
    destination.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    int listener=socket(AF_INET,SOCK_STREAM,0);
    check(listener>=0, "listener");
    if (lowat) set_option(listener,SOL_SOCKET,SO_RCVBUF,8192);
    check(bind(listener,(struct sockaddr*)&destination,sizeof(destination))==0 &&
          listen(listener,8)==0,"private loopback listener");
    socklen_t len=sizeof(destination);
    check(getsockname(listener,(struct sockaddr*)&destination,&len)==0,"ephemeral port");
    alarm(45);
    for(int block=0;block<16;block++) for(int pos=0;pos<2;pos++) {
        int candidate=(argv[2][block]=='B')^pos;
        int client=socket(AF_INET,SOCK_STREAM,0);
        check(client>=0 && prepare(client)==0,"original relay socket setup");
        int rc=connect(client,(struct sockaddr*)&destination,sizeof(destination));
        check(rc==0 || errno==EINPROGRESS,"private connect");
        int server=accept(listener,NULL,NULL);
        check(server>=0 && read_option(client,SOL_SOCKET,SO_ERROR)==0,"owned peer accepted");
        printf("{\"test\":\"%s\",\"pair\":%d,\"position\":%d,\"arm\":\"%s\"",argv[1],block+1,pos+1,candidate?"candidate":"control");
        if(lowat) pending(client,server,candidate); else source_reuse(client,server,listener,candidate);
        fflush(stdout);
    }
    close(listener);
    return 0;
}
