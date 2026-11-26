/* A receiver never sends data or FIN during the observed bulk interval. */
#include <arpa/inet.h>
#include <errno.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

enum { chunk = 65536 };
static unsigned char payload[chunk];
static void need(int ok, const char *what) {
    if (!ok) { perror(what); exit(1); }
}
static void option(int fd, int level, int name, int val) {
    need(setsockopt(fd, level, name, &val, sizeof(val))==0, "setsockopt");
}
static int read_option(int fd, int level, int name) {
    int v=0; socklen_t n=sizeof(v);
    return getsockopt(fd,level,name,&v,&n)==0 && n==sizeof(v) ? v : -errno;
}
static struct tcp_connection_info snapshot(int fd) {
    struct tcp_connection_info v={0};
    socklen_t len=sizeof(v);
    need(getsockopt(fd,IPPROTO_TCP,TCP_CONNECTION_INFO,&v,&len)==0 && len==sizeof(v),"TCP_CONNECTION_INFO");
    return v;
}
static struct rusage_info_v6 usage(void) {
    struct rusage_info_v6 u={0};
    need(proc_pid_rusage(getpid(),RUSAGE_INFO_V6,(rusage_info_t *)&u)==0,"proc_pid_rusage");
    return u;
}
struct send_work { int fd; size_t bytes; };
static void* transmit(void *arg) {
    struct send_work *w=arg;
    for (size_t pos=0; pos<w->bytes;) {
        size_t offset=pos%chunk;
        ssize_t k=send(w->fd,payload+offset,chunk-offset,0);
        need(k>0,"send");
        pos+=(size_t)k;
    }
    return NULL;
}
static void show_delta(const struct tcp_connection_info *a,const struct tcp_connection_info *b) {
    printf("{\"tx_packets\":%llu,\"rx_packets\":%llu,\"tx_bytes\":%llu,\"rx_bytes\":%llu,"
           "\"tx_retransmit_packets\":%llu,\"rx_out_of_order_bytes\":%llu}",
        b->tcpi_txpackets-a->tcpi_txpackets,b->tcpi_rxpackets-a->tcpi_rxpackets,
        b->tcpi_txbytes-a->tcpi_txbytes,b->tcpi_rxbytes-a->tcpi_rxbytes,
        b->tcpi_txretransmitpackets-a->tcpi_txretransmitpackets,
        b->tcpi_rxoutoforderbytes-a->tcpi_rxoutoforderbytes);
}
int main(int argc, char **argv) {
    if(argc!=3 || (strcmp(argv[1],"0") && strcmp(argv[1],"1"))) return 2;
    int policy=atoi(argv[1]), mibs=atoi(argv[2]);
    if(mibs<1 || mibs>512) return 2;
    size_t bytes=(size_t)mibs*1024*1024;
    for(size_t i=0;i<chunk;i++) payload[i]=(unsigned char)(i*37+(i>>7));
    struct sockaddr_in addr={.sin_len=sizeof(addr), .sin_family=AF_INET, .sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    int listener=socket(AF_INET,SOCK_STREAM,0), receiver=socket(AF_INET,SOCK_STREAM,0);
    need(listener>=0 && receiver>=0,"socket");
    need(bind(listener,(struct sockaddr *)&addr,sizeof(addr))==0 && listen(listener,1)==0,"listen");
    socklen_t len=sizeof(addr);
    need(getsockname(listener,(struct sockaddr *)&addr,&len)==0,"getsockname");
    option(receiver,SOL_SOCKET,SO_RCVBUF,512*1024);
    option(receiver,IPPROTO_TCP,TCP_SENDMOREACKS,policy);
    need(connect(receiver,(struct sockaddr *)&addr,len)==0,"connect");
    int sender=accept(listener,NULL,NULL);
    need(sender>=0,"accept"); close(listener);
    option(sender,IPPROTO_TCP,TCP_NODELAY,1);
    struct timeval deadline={.tv_sec=4};
    need(setsockopt(sender,SOL_SOCKET,SO_SNDTIMEO,&deadline,sizeof(deadline))==0,"send timeout");
    need(setsockopt(receiver,SOL_SOCKET,SO_RCVTIMEO,&deadline,sizeof(deadline))==0,"receive timeout");
    int readback=read_option(receiver,IPPROTO_TCP,TCP_SENDMOREACKS);
    int rcvbuf=read_option(receiver,SOL_SOCKET,SO_RCVBUF);
    int mss=read_option(sender,IPPROTO_TCP,TCP_MAXSEG);
    struct tcp_connection_info s0=snapshot(sender),r0=snapshot(receiver);
    struct send_work work={.fd=sender,.bytes=bytes};
    struct rusage_info_v6 u0=usage();
    mach_timebase_info_data_t timebase;
    need(mach_timebase_info(&timebase)==KERN_SUCCESS,"timebase");
    uint64_t start=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    pthread_t thread;
    need(pthread_create(&thread,NULL,transmit,&work)==0,"create sender");
    unsigned char buf[chunk];
    size_t count=0;
    while(count<bytes) {
        size_t offset=count%chunk;
        ssize_t n=recv(receiver,buf,chunk-offset,0);
        need(n>0,"recv");
        need(memcmp(buf,payload+offset,(size_t)n)==0,"byte mismatch");
        count+=(size_t)n;
    }
    uint64_t end=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    need(pthread_join(thread,NULL)==0,"join sender");
    struct rusage_info_v6 u1=usage();
    /* Let the last ACK reach the sender before counting connection-info deltas. */
    uint64_t deadline_ns=end+1000000000ull;
    struct tcp_connection_info s1=snapshot(sender);
    while(s1.tcpi_snd_sbbytes && clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)<deadline_ns) {
        usleep(100); s1=snapshot(sender);
    }
    struct tcp_connection_info r1=snapshot(receiver);
    double unit=(double)timebase.numer/timebase.denom*1e-9;
    printf("{\"policy\":%d,\"readback\":%d,\"receiver_socket_buffer_bytes\":%d,\"mss_bytes\":%d,"
           "\"verified_bytes\":%zu,\"receiver_seconds\":%.9f,\"sender_bytes_outstanding\":%u,"
           "\"process_cpu_s\":%.9f,\"process_runnable_s\":%.9f,\"sender\":",
           policy,readback,rcvbuf,mss,count,(end-start)*1e-9,s1.tcpi_snd_sbbytes,
           ((u1.ri_user_time-u0.ri_user_time)+(u1.ri_system_time-u0.ri_system_time))*unit,
           (u1.ri_runnable_time-u0.ri_runnable_time)*unit);
    show_delta(&s0,&s1); printf(",\"receiver\":");show_delta(&r0,&r1); puts("}");
    close(sender);close(receiver); return 0;
}
