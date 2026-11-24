/* Fixed-work private Darwin TCP fixtures. No host or interface settings change. */
#include <arpa/inet.h>
#include <err.h>
#include <errno.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

static void require(int ok, const char *operation) {
    if (!ok) err(1, "%s", operation);
}

static void option(int fd, int name, int value) {
    require(setsockopt(fd, IPPROTO_TCP, name, &value, sizeof(value)) == 0, "setsockopt");
}

/* Option request readbacks are distinct from both endpoints' negotiated state. */
static int get_option(int fd, int name) {
    int v = -1;
    socklen_t len = sizeof(v);
    return getsockopt(fd, IPPROTO_TCP, name, &v, &len) == 0 ? v : -errno;
}

static struct tcp_connection_info info(int fd) {
    struct tcp_connection_info ci = {0};
    socklen_t len = sizeof(ci);
    require(getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &ci, &len) == 0 &&
            len == sizeof(ci), "TCP_CONNECTION_INFO");
    return ci;
}

static int queued(int fd) {
    int n = -1;
    require(ioctl(fd, FIONREAD, &n) == 0, "FIONREAD");
    return n;
}

static void send_all(int fd, const unsigned char *bytes, size_t count) {
    while (count) {
        ssize_t n = send(fd, bytes, count, 0);
        require(n > 0, "send");
        bytes += n;
        count -= (size_t)n;
    }
}

static void verify(int fd, const unsigned char *expected, size_t count) {
    unsigned char buf[8192];
    while (count) {
        size_t want = count < sizeof(buf) ? count : sizeof(buf);
        ssize_t n = recv(fd, buf, want, 0);
        require(n > 0, "recv before expected body");
        if (memcmp(buf, expected, (size_t)n)) errx(1, "payload mismatch");
        count -= (size_t)n;
        expected += n;
    }
}

static void finish(int sender, int receiver) {
    unsigned char byte;
    require(shutdown(sender, SHUT_WR) == 0 && recv(receiver, &byte, 1, 0) == 0,
            "half-close and verify EOF");
}

/* An ordinary 20-byte GET and a verified 16 KiB reply, on a new connection. */
static void ecn(int client, int server, int listener, int before) {
    static const unsigned char request[] = "GET /id HTTP/1.0\r\n\r\n";
    unsigned char reply[16384];
    for (size_t i=0;i<sizeof(reply);i++) reply[i]=(unsigned char)(i*29+13);
    struct tcp_connection_info c = info(client), s = info(server);
    send_all(client, request, sizeof(request)-1);
    verify(server, request, sizeof(request)-1);
    send_all(server, reply, sizeof(reply));
    verify(client, reply, sizeof(reply));
    finish(client,server); finish(server,client);
    struct tcp_connection_info ce=info(client),se=info(server);
    printf(",\"listener_policy\":%d,\"client_policy_before_connect\":%d,\"client_options\":%u,"
           "\"server_options\":%u,\"client_ecn\":%d,\"server_ecn\":%d,"
           "\"request_bytes\":%zu,\"reply_bytes\":%zu,\"both_eof\":true,"
           "\"client_retrans\":%llu,\"server_retrans\":%llu}\n",
           get_option(listener,TCP_ENABLE_ECN),before,c.tcpi_options,s.tcpi_options,
           !!(c.tcpi_options&TCPCI_OPT_ECN),!!(s.tcpi_options&TCPCI_OPT_ECN),
           sizeof(request)-1,sizeof(reply),ce.tcpi_txretransmitpackets,se.tcpi_txretransmitpackets);
}

/* 148 header bytes, 64 distinct 1 KiB writes, final 148 bytes. Read only
 * after both arms have issued the same explicit NOPUSH=0 end-of-batch call. */
static void coalesce(int writer,int receiver,int enabled) {
    enum { HEADER=148, BLOCK=1024, N=64, TOTAL=2*HEADER+N*BLOCK };
    unsigned char data[TOTAL];
    for(size_t i=0;i<sizeof(data);i++) data[i]=(unsigned char)(i*37+(i>>8));
    option(writer,TCP_NODELAY,1);
    option(writer,TCP_NOPUSH,enabled);
    int nodelay=get_option(writer,TCP_NODELAY),nopush=get_option(writer,TCP_NOPUSH);
    struct tcp_connection_info base=info(writer);
    send_all(writer,data,HEADER);
    int header_ready=queued(receiver);
    size_t at=HEADER;
    for(int i=0;i<N;i++,at+=BLOCK) send_all(writer,data+at,BLOCK);
    send_all(writer,data+at,HEADER);
    int pre_ready=queued(receiver);
    struct tcp_connection_info before=info(writer);
    option(writer,TCP_NOPUSH,0);
    int post_ready=queued(receiver);
    verify(receiver,data,sizeof(data));
    struct tcp_connection_info drained=info(writer);
    finish(writer,receiver);finish(receiver,writer);
    struct tcp_connection_info end=info(writer);
    printf(",\"nodelay\":%d,\"nopush_during_writes\":%d,\"maxseg\":%u,"
           "\"header_readable\":%d,\"before_flush_readable\":%d,\"after_flush_readable\":%d,"
           "\"tx_packets_preflush\":%llu,\"tx_bytes_preflush\":%llu,\"tx_packets_at_drain\":%llu,"
           "\"tx_bytes_at_drain\":%llu,\"writer_retrans\":%llu,\"verified_bytes\":%zu,\"both_eof\":true}\n",
           nodelay,nopush,base.tcpi_maxseg,header_ready,pre_ready,post_ready,
           before.tcpi_txpackets-base.tcpi_txpackets,before.tcpi_txbytes-base.tcpi_txbytes,
           drained.tcpi_txpackets-base.tcpi_txpackets,drained.tcpi_txbytes-base.tcpi_txbytes,
           end.tcpi_txretransmitpackets,sizeof(data));
}

int main(int argc,char **argv) {
    if(argc!=3 || (strcmp(argv[1],"ecn")&&strcmp(argv[1],"coalesce")) ||
       strlen(argv[2])!=16 || strspn(argv[2],"AB")!=16) errx(1,"usage: socket_controls {ecn|coalesce} 16-char-order");
    int is_ecn=strcmp(argv[1],"ecn")==0;
    int listener=socket(AF_INET,SOCK_STREAM,0);
    require(listener>=0,"socket");
    struct sockaddr_in addr={.sin_len=sizeof(addr),.sin_family=AF_INET,.sin_addr={.s_addr=htonl(INADDR_LOOPBACK)}};
    require(bind(listener,(struct sockaddr*)&addr,sizeof(addr))==0 && listen(listener,8)==0,"private loopback bind/listen");
    if(is_ecn) option(listener,TCP_ENABLE_ECN,1);
    socklen_t len=sizeof(addr);
    require(getsockname(listener,(struct sockaddr*)&addr,&len)==0,"getsockname");
    for(int pair=0;pair<16;pair++) for(int pos=0;pos<2;pos++) {
        int changed=(argv[2][pair]=='B')^pos;
        int c=socket(AF_INET,SOCK_STREAM,0);
        require(c>=0,"socket"); option(c,TCP_NODELAY,1);
        if(is_ecn && changed) option(c,TCP_ENABLE_ECN,1);
        int before=is_ecn?get_option(c,TCP_ENABLE_ECN):0;
        require(connect(c,(struct sockaddr*)&addr,sizeof(addr))==0,"connect");
        int s=accept(listener,NULL,NULL);require(s>=0,"accept");option(s,TCP_NODELAY,1);
        printf("{\"fixture\":\"%s\",\"pair\":%d,\"position\":%d,\"arm\":\"%s\"",argv[1],pair+1,pos+1,changed?"candidate":"control");
        if(is_ecn) ecn(c,s,listener,before);else coalesce(s,c,changed);
        fflush(stdout);close(c);close(s);
    }
    close(listener);return 0;
}

